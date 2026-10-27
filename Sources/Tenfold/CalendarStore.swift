import AppKit
import EventKit
import SwiftUI

struct CalendarEntry: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    var joinURL: URL? = nil          // Teams / Zoom / Meet / Webex link found in the event
}

/// Upcoming events (rest of today + tomorrow) via EventKit. Access is requested only on demand.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var entries: [CalendarEntry] = []          // upcoming (dashboard)

    // Date wheel (Calendar view)
    @Published private(set) var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var dayEntries: [CalendarEntry] = []       // events on selectedDate
    @Published private(set) var eventDays: Set<Date> = []              // days with events in the shown month
    /// Bound to the wheel's scroll position; snapping to a day selects it.
    @Published var wheelSelection: Date? = Calendar.current.startOfDay(for: Date()) {
        didSet {
            if let day = wheelSelection, day != selectedDate { select(day) }
        }
    }

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Next timed event that starts within 10 minutes (or started less than 10 minutes ago).
    var upcomingMeeting: CalendarEntry? {
        let now = Date()
        return entries.first { !$0.isAllDay && $0.end > now
            && $0.start.timeIntervalSince(now) <= 10 * 60 && now.timeIntervalSince($0.start) <= 10 * 60 }
    }

    func join(_ entry: CalendarEntry) {
        if let url = entry.joinURL { NSWorkspace.shared.open(url) }
    }

    func requestAccess() {
        Task { @MainActor in
            do {
                let granted = try await store.requestFullAccessToEvents()
                access = granted ? .granted : .denied
                if granted { reload() }
            } catch {
                access = .denied
            }
        }
    }

    func reload() {
        guard access == .granted else { return }
        refreshUpcoming(force: true)
        loadDay()
        loadMonth()
    }

    /// Upcoming events (rest of today + tomorrow) – also polled every 30 s for the meeting countdown.
    private var lastUpcomingRefresh = Date.distantPast

    func refreshUpcoming(force: Bool = false) {
        guard access == .granted else { return }
        guard force || Date().timeIntervalSince(lastUpcomingRefresh) > 20 else { return }
        lastUpcomingRefresh = Date()
        let now = Date()
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(172_800)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        entries = Array(store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map(Self.entry))
    }

    // MARK: Date wheel

    /// All days of the month that contains `selectedDate`.
    var monthDays: [Date] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: selectedDate),
              let count = cal.range(of: .day, in: .month, for: selectedDate)?.count else { return [] }
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }

    func select(_ date: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        guard day != selectedDate else { return }
        let monthChanged = !cal.isDate(day, equalTo: selectedDate, toGranularity: .month)
        selectedDate = day
        if wheelSelection != day { wheelSelection = day }
        loadDay()
        if monthChanged { loadMonth() }
    }

    func shiftMonth(_ months: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: months, to: selectedDate) { select(d) }
    }

    func shiftYear(_ years: Int) {
        if let d = Calendar.current.date(byAdding: .year, value: years, to: selectedDate) { select(d) }
    }

    func goToToday() { select(Date()) }

    /// Month grid cells: leading blanks (nil) so the 1st falls on the right weekday column.
    var gridCells: [Date?] {
        let cal = Calendar.current
        guard let first = monthDays.first else { return [] }
        let blanks = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: blanks) + monthDays.map { Optional($0) }
    }

    /// Very short weekday symbols ordered by the user's first weekday (e.g. M T W T F S S).
    var weekdaySymbols: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func loadDay() {
        guard access == .granted else { dayEntries = []; return }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: selectedDate, end: end, calendars: nil)
        dayEntries = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.entry)
    }

    private func loadMonth() {
        let cal = Calendar.current
        guard access == .granted, let interval = cal.dateInterval(of: .month, for: selectedDate) else {
            eventDays = []
            return
        }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        var days = Set<Date>()
        for ev in store.events(matching: predicate) {
            let start: Date = ev.startDate
            let end: Date = ev.endDate
            var day = cal.startOfDay(for: max(start, interval.start))
            let last = min(max(end, start.addingTimeInterval(1)), interval.end)
            while day < last {
                days.insert(day)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        eventDays = days
    }

    private static func entry(_ ev: EKEvent) -> CalendarEntry {
        CalendarEntry(title: ev.title ?? L("Untitled"),
                      start: ev.startDate,
                      end: ev.endDate,
                      isAllDay: ev.isAllDay,
                      color: Color(nsColor: ev.calendar?.color ?? .systemBlue),
                      joinURL: meetingLink(in: [ev.url?.absoluteString, ev.location, ev.notes]))
    }

    private static let meetingPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"']*(teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|webex\.com|whereby\.com|gotomeeting\.com|meet\.jit\.si)[^\s<>"']*"#,
        options: [.caseInsensitive])

    private static func meetingLink(in fields: [String?]) -> URL? {
        guard let regex = meetingPattern else { return nil }
        for case let text? in fields {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}
