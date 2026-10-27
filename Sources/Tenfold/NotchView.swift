import AppKit
import ApplicationServices
import Charts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme

private enum Theme {
    // Colour
    static let accent = Color(red: 0.95, green: 0.74, blue: 0.52)          // warm peach
    static let accentDeep = Color(red: 0.90, green: 0.55, blue: 0.38)
    static let accentGradient = LinearGradient(colors: [accent, accentDeep],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.36)
    static let divider = Color.white.opacity(0.07)
    static let fill = Color.white.opacity(0.07)
    static let fillHover = Color.white.opacity(0.13)

    // Widget tints
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let mint = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let sky = Color(red: 0.40, green: 0.68, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let lilac = Color(red: 0.70, green: 0.58, blue: 1.0)

    // Surfaces
    static let panel = LinearGradient(colors: [.black, .black, Color(white: 0.11)],
                                      startPoint: .top, endPoint: .bottom)
    static let rim = LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.14)],
                                    startPoint: .top, endPoint: .bottom)

    // Motion
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

/// Frosted card used for every widget / content block.
private struct GlassCard: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.075), Color.white.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

/// Small uppercase section label with a tinted icon badge.
private struct SectionLabel: View {
    let symbol: String
    let title: String
    let tint: Color
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint.opacity(0.18)))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

// MARK: - Shape

/// Notch-style shape: concave "shoulders" at the top that flow into the menu bar,
/// rounded corners at the bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, max(rect.height - t, 0))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchView: View {
    @ObservedObject var state: NotchState
    let clipboard: ClipboardStore
    let files: FileTrayStore
    let calendar: CalendarStore
    let media: MediaController
    let controls: SystemHUDMonitor
    let weather: WeatherStore
    let screenTime: ScreenTimeStore
    let extras: Extras

    var body: some View {
        VStack(spacing: NotchMetrics.dockGap) {
            ZStack(alignment: .top) {
                // Performance: a gradient-filled custom path is rasterized by CoreGraphics on the CPU
                // (seen in `sample`: ripc_DrawShading / rgba64_shade). Solid fill + shadow render on the GPU;
                // the gradient is a separate view clipped by the shape (GPU mask), the rim a solid stroke.
                NotchShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.isExpanded ? 0.5 : 0), radius: 14, x: 0, y: 8)
                    .overlay(
                        Theme.panel
                            .opacity(state.isExpanded ? 1 : 0)
                            .clipShape(NotchShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius))
                    )
                    .overlay(
                        NotchShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
                            .stroke(Color.white.opacity(state.isExpanded ? 0.09 : 0), lineWidth: 1)
                    )

                Group {
                    if state.isExpanded {
                        let full = NotchMetrics.expandedShapeSize(notchWidth: state.notchSize.width,
                                                                  tall: state.isTall)
                        ExpandedContent(state: state, clipboard: clipboard, files: files,
                                        calendar: calendar, media: media, controls: controls,
                                        weather: weather, screenTime: screenTime, extras: extras)
                            .padding(.horizontal, NotchMetrics.contentInset)
                            .padding(.bottom, 18)
                            // Fixed final size: the growing shape only reveals it (clip), no re-layout.
                            .frame(width: full.width, height: full.height, alignment: .top)
                            .transition(.asymmetric(
                                insertion: AnyTransition.opacity
                                    .combined(with: .offset(y: -8))
                                    .animation(.easeOut(duration: 0.28).delay(0.12)),
                                removal: AnyTransition.opacity.animation(.easeIn(duration: 0.1))))
                    } else if let hud = state.hud {
                        HUDView(event: hud, notchWidth: state.notchSize.width)
                            .frame(height: state.notchSize.height)
                            .transition(.opacity)
                    } else if let item = state.liveItem {
                        LiveActivityView(item: item, notchWidth: state.notchSize.width,
                                         height: state.notchSize.height)
                            .frame(height: state.notchSize.height)
                            .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.1)))
                    }
                }
                .frame(width: state.shapeSize.width, height: state.shapeSize.height, alignment: .top)
                .clipShape(NotchShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius))
            }
            .frame(width: state.shapeSize.width, height: state.shapeSize.height)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            if state.isExpanded {
                Dock(selected: $state.selectedTab)
                    .transition(.asymmetric(
                        insertion: AnyTransition.opacity
                            .combined(with: .offset(y: -14))
                            .animation(Theme.spring.delay(0.12)),
                        removal: AnyTransition.opacity.animation(.easeIn(duration: 0.08))))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let tray = files
        let notchState = state
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    tray.add([url])
                    notchState.selectedTab = .files
                }
            }
        }
    }
}

// MARK: - Expanded layout

struct ExpandedContent: View {
    @ObservedObject var state: NotchState
    let clipboard: ClipboardStore
    let files: FileTrayStore
    let calendar: CalendarStore
    let media: MediaController
    let controls: SystemHUDMonitor
    let weather: WeatherStore
    let screenTime: ScreenTimeStore
    let extras: Extras

    var body: some View {
        VStack(spacing: 0) {
            // Header row sits beside the hardware notch.
            HStack(spacing: 0) {
                HeaderTitle(tab: state.selectedTab)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(width: state.notchSize.width + 16)

                HeaderActions(tab: state.selectedTab, clipboard: clipboard, files: files)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: state.notchSize.height)

            ZStack {
                switch state.selectedTab {
                case .dashboard:
                    DashboardView(clipboard: clipboard, files: files, calendar: calendar,
                                  media: media, controls: controls, weather: weather,
                                  screenTime: screenTime, focus: extras.focus,
                                  isTargeted: state.isDropTargeted,
                                  onOpen: { tab in withAnimation(Theme.spring) { state.selectedTab = tab } })
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .weather:
                    WeatherTab(weather: weather).transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .screenTime:
                    ScreenTimeTab(store: screenTime).transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .clipboard:
                    ClipboardTab(store: clipboard, keyboardMode: state.keyboardMode)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .tools:
                    ToolsTab(focus: extras.focus, notes: extras.notes, camera: extras.camera)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .usage:
                    UsageTab(store: extras.usage)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .files:
                    FilesTab(store: files, screenshots: extras.screenshots, isTargeted: state.isDropTargeted)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .media:
                    MediaTab(media: media, controls: controls).transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .calendar:
                    CalendarTab(store: calendar).transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        }
        .overlay {
            if state.showLanguagePrompt {
                LanguagePrompt(state: state)
                    .padding(.top, state.notchSize.height + 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Theme.spring, value: state.showLanguagePrompt)
    }
}

/// First-expand prompt: pick a language, relaunch if needed.
private struct LanguagePrompt: View {
    @ObservedObject var state: NotchState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(L("Choose your language"))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button {
                    state.showLanguagePrompt = false
                } label: {
                    Text(L("Keep current"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.fill))
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AppLanguage.allCases) { language in
                    let selected = language == Localization.selected
                    Button {
                        choose(language)
                    } label: {
                        Text(language.nativeName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? Color.black : Theme.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.fill))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(L("The new language is used after relaunching."))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.94)))
        .modifier(GlassCard(radius: 22))
    }

    private func choose(_ language: AppLanguage) {
        Localization.selected = language
        LanguageSettings.shared.selection = language
        state.showLanguagePrompt = false
        if Localization.resolvedCode(for: language) != Localization.current {
            Localization.relaunch()
        }
    }
}

private struct HeaderTitle: View {
    let tab: NotchTab

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tab.title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primary)
            if false, let name = Self.firstName {
                Text(name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentGradient)
            }
        }
        .lineLimit(1)
        .id(tab)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return L("Good morning,")
        case 12..<18: return L("Good afternoon,")
        default: return L("Good evening,")
        }
    }

    private static var firstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }
}

/// "Sat 3 Oct  14:32" – refreshes every minute.
private struct ClockLabel: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .foregroundStyle(Theme.secondary)
                Text(context.date.formatted(.dateTime.hour().minute()))
                    .foregroundStyle(Theme.primary)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }
}

struct HeaderActions: View {
    let tab: NotchTab
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var files: FileTrayStore

    var body: some View {
        HStack(spacing: 8) {
            switch tab {
            case .dashboard, .calendar, .media, .weather, .screenTime, .tools, .usage:
                ClockLabel()
                IconButton(symbol: "gearshape", help: L("Settings")) {
                    NotificationCenter.default.post(name: .tenfoldOpenSettings, object: nil)
                }
            case .clipboard:
                Text(LF("%d of %d", clipboard.items.count, ClipboardStore.maxItems))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                if !clipboard.items.isEmpty {
                    IconButton(symbol: "trash", help: L("Clear history")) { clipboard.clear() }
                }
            case .files:
                if !files.files.isEmpty {
                    IconButton(symbol: "dot.radiowaves.left.and.right", help: L("AirDrop all")) {
                        files.airDrop(files.files.map(\.url))
                    }
                    IconButton(symbol: "trash", help: L("Clear tray")) { files.clear() }
                }
            }
        }
    }
}

// MARK: - Dock (floating section switcher)

struct Dock: View {
    @Binding var selected: NotchTab
    @Namespace private var pill
    @ObservedObject private var hover = HoverTracker.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(NotchTab.allCases) { tab in
                let isSelected = selected == tab
                let id = "dock-\(tab.rawValue)"
                Button {
                    withAnimation(Theme.spring) { selected = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isSelected ? 1 : (hover.isHovered(id) ? 0.85 : 0.5)))
                        .frame(width: 38, height: 32)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .overlay(alignment: .bottom) {
                                        Capsule()
                                            .fill(Theme.accentGradient)
                                            .frame(width: 14, height: 3)
                                            .offset(y: 5)
                                            .shadow(color: Theme.accent.opacity(0.8), radius: 4)
                                    }
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .scaleEffect(hover.isHovered(id) ? 1.12 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover.isHovered(id))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .onHover { hover.update(id, inside: $0) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NotchMetrics.dockHeight)
        .background(
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

// MARK: - Dashboard (four widgets side by side)

/// Dashboard – "ambient minimal": big clock, one natural-language summary of your day, a row of action chips.
struct DashboardView: View {
    let clipboard: ClipboardStore
    let files: FileTrayStore
    let calendar: CalendarStore
    let media: MediaController
    let controls: SystemHUDMonitor
    let weather: WeatherStore
    @ObservedObject var screenTime: ScreenTimeStore
    let focus: FocusTimer
    let isTargeted: Bool
    var onOpen: (NotchTab) -> Void = { _ in }

    var body: some View {
        GridDashboard(clipboard: clipboard, calendar: calendar, media: media, controls: controls,
                      weather: weather, screenTime: screenTime, focus: focus,
                      screenshots: nil, onOpen: onOpen)
    }
}

// MARK: - Grid dashboard (4 × 2 sections, hairline dividers, no boxes)

private struct GridDashboard: View {
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let media: MediaController
    let controls: SystemHUDMonitor
    let weather: WeatherStore
    let screenTime: ScreenTimeStore
    let focus: FocusTimer
    let screenshots: ScreenshotStore?
    let onOpen: (NotchTab) -> Void

    @ObservedObject private var layout = DashboardLayout.shared

    var body: some View {
        let items = layout.visible
        // Up to 4 sections → one row, otherwise two rows (first row gets the extra one).
        let rows: [[DashboardSection]] = items.count <= 4
            ? [items]
            : [Array(items.prefix((items.count + 1) / 2)), Array(items.dropFirst((items.count + 1) / 2))]
        GeometryReader { geo in
            if items.isEmpty {
                Text(L("All sections are hidden. Turn them on in Settings → Dashboard."))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rowHeight = (geo.size.height - CGFloat(rows.count - 1)) / CGFloat(rows.count)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            LinearGradient(colors: [.clear, Color.white.opacity(0.10), Color.white.opacity(0.10), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(height: 1)
                        }
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.element) { column, section in
                                if column > 0 { GridDivider() }
                                sectionView(section)
                            }
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DashboardSection) -> some View {
        switch section {
        case .upNext: UpNextSection(calendar: calendar, onOpen: onOpen)
        case .nowPlaying: NowPlayingSection(media: media, onOpen: onOpen)
        case .focus: FocusSection(focus: focus, onOpen: onOpen)
        case .weather: WeatherSection(weather: weather, onOpen: onOpen)
        case .clipboard: ClipboardSection(clipboard: clipboard, onOpen: onOpen)
        case .screenTime: ScreenTimeSection(screenTime: screenTime, onOpen: onOpen)
        case .dayProgress: TodaySection(calendar: calendar, focus: focus, screenTime: screenTime)
        case .quickControls: QuickControlsSection(controls: controls, onOpen: onOpen)
        }
    }
}

private struct GridDivider: View {
    var body: some View {
        LinearGradient(colors: [.clear, Color.white.opacity(0.10), Color.white.opacity(0.10), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

/// Section frame: icon + title, optional trailing accessory, content.
/// Hovering highlights the section softly; a chevron shows that the title opens the full tab.
private struct GridSection<Trailing: View, Content: View>: View {
    let symbol: String
    let title: String
    var onTitleTap: (() -> Void)? = nil
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "section-\(symbol)" }
    private var hovering: Bool { hover.isHovered(hoverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary.opacity(0.9))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if onTitleTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .opacity(hovering ? 1 : 0)
                        .offset(x: hovering ? 0 : -4)
                }
                Spacer(minLength: 4)
                trailing
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture { onTitleTap?() }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // minHeight 0: a section never grows taller than its row, so all titles stay on one line.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.035 : 0))
                .padding(4)
        )
        .onHover { hover.update(hoverID, inside: $0) }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// List row: icon tile, bold title, grey subtitle, trailing accessory. Soft hover highlight.
private struct GridRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "row-\(title)-\(subtitle)" }

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hover.isHovered(hoverID) ? 0.06 : 0))
        )
        .padding(.horizontal, -6)
        .onHover { hover.update(hoverID, inside: $0) }
        .animation(.easeOut(duration: 0.12), value: hover.isHovered(hoverID))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Centered empty state with the icon in a soft circle.
private struct GridEmpty: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.06)))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Round outlined action button; `filled` = primary (accent gradient).
private struct CircleAction: View {
    let symbol: String
    var filled = false
    var size: CGFloat = 26
    let action: () -> Void

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "circle-\(symbol)-\(filled)-\(size)" }
    private var hovering: Bool { hover.isHovered(hoverID) }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(filled ? Color.black : Theme.primary.opacity(hovering ? 1 : 0.75))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(filled ? AnyShapeStyle(Theme.accentGradient)
                                         : AnyShapeStyle(Color.white.opacity(hovering ? 0.12 : 0.04)))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(filled ? 0 : (hovering ? 0.35 : 0.18)), lineWidth: 1))
                .shadow(color: filled ? Theme.accent.opacity(0.45) : .clear, radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.08 : 1)
        .onHover { hover.update(hoverID, inside: $0) }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

// MARK: Sections

private struct UpNextSection: View {
    @ObservedObject var calendar: CalendarStore
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "calendar", title: L("Up Next"), onTitleTap: { onOpen(.calendar) }) {
            EmptyView()
        } content: {
            switch calendar.access {
            case .unknown:
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("See your next events here."))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    PillButton(title: L("Allow Access")) { calendar.requestAccess() }
                }
            case .denied:
                GridEmpty(symbol: "lock", title: L("Calendar access is off"), subtitle: L("Settings"))
            case .granted:
                if calendar.entries.isEmpty {
                    GridEmpty(symbol: "checkmark.circle", title: L("Nothing planned"), subtitle: L("Nothing else today"))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.entries.prefix(2)) { entry in
                            GridRow(title: entry.title,
                                    subtitle: entry.isAllDay ? L("All day")
                                        : "\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened))") {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(entry.color)
                            } trailing: {
                                if entry.joinURL != nil {
                                    CircleAction(symbol: "video.fill", size: 24) { calendar.join(entry) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NowPlayingSection: View {
    @ObservedObject var media: MediaController
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "music.note", title: L("Now Playing"), onTitleTap: { onOpen(.media) }) {
            if let np = media.nowPlaying {
                EqualizerView(isPlaying: np.isPlaying, bars: 4, color: Theme.accent, spacing: 2)
                    .frame(width: 16, height: 12)
            }
        } content: {
            if let np = media.nowPlaying {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ArtworkView(nowPlaying: np, size: 40, radius: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(np.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                            Text(np.artist)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        CircleAction(symbol: "backward.fill", size: 22) { media.previous() }
                        CircleAction(symbol: np.isPlaying ? "pause.fill" : "play.fill", filled: true, size: 26) { media.playPause() }
                        CircleAction(symbol: "forward.fill", size: 22) { media.next() }
                        ProgressBar(nowPlaying: np, showTimes: false) { media.seek(to: $0) }
                    }
                }
            } else {
                GridEmpty(symbol: "music.note", title: L("Nothing playing"), subtitle: L("Start Spotify or Music"))
            }
        }
    }
}

private struct FocusSection: View {
    @ObservedObject var focus: FocusTimer
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "timer", title: L("Focus"), onTitleTap: { onOpen(.tools) }) {
            Menu {
                ForEach(FocusTimer.presets) { preset in
                    Button(LF("%d / %d min", preset.focus, preset.rest)) { focus.choose(preset) }
                }
            } label: {
                Text("\(focus.preset.focus)/\(focus.preset.rest)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } content: {
            TimelineView(.animation(minimumInterval: 1, paused: !focus.isRunning)) { context in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(FocusFormat.clock(focus.remaining(at: context.date)))
                                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.primary)
                                .contentTransition(.numericText(countsDown: true))
                            Text((focus.phase == .focus ? L("Focus") : L("Break")).uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(0.8)
                                .foregroundStyle(focus.phase == .focus ? Theme.accent : Theme.mint)
                        }
                        Text(focus.isRunning ? L("Running") : L("Paused"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: max(focus.progress(at: context.date), 0.001))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 26, height: 26)
                }
            }
            HStack(spacing: 8) {
                CircleAction(symbol: "arrow.counterclockwise") { focus.reset() }
                CircleAction(symbol: focus.isRunning ? "pause.fill" : "play.fill", filled: true, size: 30) { focus.toggle() }
                CircleAction(symbol: "forward.end.fill") { focus.skip() }
            }
        }
    }
}

private struct WeatherSection: View {
    @ObservedObject var weather: WeatherStore
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "cloud.sun.fill", title: L("Weather"), onTitleTap: { onOpen(.weather) }) {
            if !weather.placeName.isEmpty {
                Text(weather.placeName.components(separatedBy: ",").first ?? "")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        } content: {
            if let s = weather.snapshot {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(temp(s.temperature))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                            .contentTransition(.numericText())
                        WeatherIcon(code: s.code, isDay: s.isDay, size: 20)
                        Spacer(minLength: 0)
                    }
                    Text(WeatherCode.description(s.code))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(LF("H %@  L %@  ·  Feels %@", temp(s.high), temp(s.low), temp(s.feelsLike)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            } else {
                GridEmpty(symbol: "cloud.sun", title: L("Loading weather…"), subtitle: L("Weather"))
            }
        }
    }
}

private struct ClipboardSection: View {
    @ObservedObject var clipboard: ClipboardStore
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "doc.on.clipboard", title: L("Clipboard"), onTitleTap: { onOpen(.clipboard) }) {
            Text("\(clipboard.items.count)/\(ClipboardStore.maxItems)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.tertiary)
        } content: {
            if clipboard.items.isEmpty {
                GridEmpty(symbol: "doc.on.doc", title: L("Copy something"), subtitle: L("Clipboard"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(clipboard.items.prefix(2))) { item in
                        GridRow(title: Self.label(item),
                                subtitle: "\(Self.kind(item)) · \(item.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))") {
                            Image(systemName: Self.symbol(item))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.sky)
                        } trailing: {
                            CircleAction(symbol: clipboard.lastCopiedID == item.id ? "checkmark" : "doc.on.doc",
                                         filled: clipboard.lastCopiedID == item.id, size: 24) {
                                clipboard.copy(item)
                            }
                        }
                    }
                }
                .animation(Theme.spring, value: clipboard.items.prefix(2).map(\.id))
            }
        }
    }

    static func label(_ item: ClipItem) -> String {
        switch item.content {
        case .text(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Image")
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    static func kind(_ item: ClipItem) -> String {
        switch item.content {
        case .text(let t): return (t.hasPrefix("http://") || t.hasPrefix("https://")) ? L("LINK").capitalized : L("Text")
        case .image: return L("Image")
        case .files: return L("Files")
        }
    }

    static func symbol(_ item: ClipItem) -> String {
        if case .image = item.content { return "photo" }
        if case .files = item.content { return "doc" }
        return "text.alignleft"
    }
}

private struct ScreenTimeSection: View {
    @ObservedObject var screenTime: ScreenTimeStore
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "hourglass", title: L("Screen Time"), onTitleTap: { onOpen(.screenTime) }) {
            EmptyView()
        } content: {
            if screenTime.todayTotal < 60 {
                GridEmpty(symbol: "hourglass", title: formatDuration(screenTime.todayTotal), subtitle: L("today"))
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatDuration(screenTime.todayTotal))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                            .contentTransition(.numericText())
                        if let top = screenTime.todayApps.first {
                            HStack(spacing: 6) {
                                AppIconView(bundleID: top.id, size: 14)
                                Text("\(top.name) · \(formatDuration(top.seconds))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    UsageDonut(categories: screenTime.todayCategories, store: screenTime, lineRatio: 0.62)
                        .frame(width: 46, height: 46)
                }
            }
        }
    }
}

/// "Day progress": how much of the work day (9–18) is done, plus a small wellbeing hint.
private struct TodaySection: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var focus: FocusTimer
    @ObservedObject var screenTime: ScreenTimeStore

    var body: some View {
        GridSection(symbol: "sunrise.fill", title: L("Day Progress")) {
            Text("9:00 – 18:00")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.tertiary)
        } content: {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let cal = Calendar.current
                let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: context.date) ?? context.date
                let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: context.date) ?? context.date
                let progress = min(max(context.date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress >= 1 ? L("Day done") : progress <= 0 ? L("Not started")
                         : LF("%@ left", formatDuration(end.timeIntervalSince(context.date))))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.primary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Theme.accentGradient).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 5)
                    Text(LF("Sessions today: %d", focus.sessionsToday) + " · " + L("Eyes need rest too."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct QuickControlsSection: View {
    @ObservedObject var controls: SystemHUDMonitor
    let onOpen: (NotchTab) -> Void

    var body: some View {
        GridSection(symbol: "switch.2", title: L("Quick controls")) {
            EmptyView()
        } content: {
            HStack(spacing: 8) {
                // Both level bars share one column, so they are always the same width.
                VStack(spacing: 8) {
                    SegmentLevel(symbol: "sun.max.fill", value: controls.brightness,
                                 enabled: controls.brightnessAvailable, tint: Theme.accent) {
                        controls.setBrightness($0)
                    }
                    .help(L("Brightness"))
                    SegmentLevel(symbol: controls.muted || controls.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                 value: controls.muted ? 0 : controls.volume,
                                 enabled: controls.volumeAvailable, tint: Theme.lilac) {
                        controls.setVolume($0)
                    }
                    .help(L("Volume"))
                }
                VStack(spacing: 8) {
                    IconButton(symbol: "note.text", help: L("Notes")) { onOpen(.tools) }
                    IconButton(symbol: "camera.viewfinder", help: L("Screenshots")) { onOpen(.files) }
                }
            }
        }
    }
}

/// Segmented level meter (brightness / volume): a row of small cells that light up with a soft glow.
/// Click or drag across the cells to set the value.
private struct SegmentLevel: View {
    let symbol: String
    let value: Double
    let enabled: Bool
    var tint: Color = Theme.accent
    let onChange: (Double) -> Void

    private let cellSpacing: CGFloat = 3

    var body: some View {
        let v = min(max(value, 0), 1)
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? tint : Theme.tertiary)
                .frame(width: 16)
            GeometryReader { geo in
                let width = geo.size.width
                let count = max(Int((width + cellSpacing) / (6 + cellSpacing)), 4)
                let lit = Int((v * Double(count)).rounded())
                HStack(spacing: cellSpacing) {
                    ForEach(0..<count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(i < lit
                                  ? AnyShapeStyle(tint.opacity(enabled ? 0.55 + 0.45 * Double(i + 1) / Double(count) : 0.3))
                                  : AnyShapeStyle(Color.white.opacity(0.07)))
                    }
                }
                .frame(height: 12)
                .frame(maxHeight: .infinity)
                .shadow(color: enabled && lit > 0 ? tint.opacity(0.45) : .clear, radius: 4)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard enabled, width > 0 else { return }
                    onChange(Double(min(max(g.location.x / width, 0), 1)))
                })
            }
            Text("\(Int((v * 100).rounded()))")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .opacity(enabled ? 1 : 0.6)
    }
}

private struct AmbientDashboard: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var media: MediaController
    @ObservedObject var controls: SystemHUDMonitor
    @ObservedObject var weather: WeatherStore
    @ObservedObject var screenTime: ScreenTimeStore
    @ObservedObject var focus: FocusTimer
    let onOpen: (NotchTab) -> Void

    private var nextEvent: CalendarEntry? {
        calendar.entries.first { $0.end > Date() && Calendar.current.isDateInToday($0.start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Big clock + date
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline) {
                    Text(context.date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(context.date.formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                        Text(context.date.formatted(.dateTime.day().month(.wide)))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            // One sentence about your day
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(summary(at: context.date))
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.3), value: summary(at: context.date))
            }

            Spacer(minLength: 0)

            // Action chips
            HStack(spacing: 8) {
                if let event = nextEvent, event.joinURL != nil {
                    Chip(symbol: "video.fill", title: L("Join"), prominent: true) { calendar.join(event) }
                }
                if let np = media.nowPlaying {
                    Chip(symbol: np.isPlaying ? "pause.fill" : "play.fill", title: np.title) { media.playPause() }
                        .frame(maxWidth: 190)
                }
                Chip(symbol: focus.isRunning ? "pause.fill" : "timer",
                     title: focus.isActive ? FocusFormat.clock(focus.remaining()) : L("Focus"),
                     prominent: focus.isRunning) { focus.toggle() }
                Chip(symbol: "doc.on.clipboard", title: "\(clipboard.items.count)") { onOpen(.clipboard) }
                if let s = weather.snapshot {
                    Chip(symbol: WeatherCode.symbol(s.code, isDay: s.isDay), title: temp(s.temperature)) { onOpen(.weather) }
                }
                Spacer(minLength: 8)
                StripSlider(symbol: "sun.max.fill", value: controls.brightness, enabled: controls.brightnessAvailable) {
                    controls.setBrightness($0)
                }
                .frame(width: 120)
                StripSlider(symbol: controls.muted || controls.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            value: controls.muted ? 0 : controls.volume, enabled: controls.volumeAvailable) {
                    controls.setVolume($0)
                }
                .frame(width: 120)
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // Soft ambient glow: album colours while music plays, otherwise a warm accent haze.
            ZStack {
                if media.nowPlaying != nil {
                    AmbientArtwork(nowPlaying: media.nowPlaying).opacity(0.7)
                }
                RadialGradient(colors: [Theme.accent.opacity(0.12), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 380)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(-6)
            .allowsHitTesting(false)
        }
    }

    /// Natural-language summary; key values are highlighted (bold + accent colour).
    private func summary(at date: Date) -> AttributedString {
        var result = AttributedString()
        func add(_ format: String, _ values: String...) {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(highlighted(format, values))
        }

        if let s = weather.snapshot {
            let condition = WeatherCode.description(s.code)
            if weather.placeName.isEmpty {
                add("%@ and %@.", condition, temp(s.temperature))
            } else {
                let city = weather.placeName.components(separatedBy: ",").first ?? weather.placeName
                add("%@ and %@ in %@.", condition, temp(s.temperature), city)
            }
        }
        if calendar.access == .granted {
            if let event = nextEvent {
                let minutes = Int((event.start.timeIntervalSince(date) / 60).rounded(.up))
                let when = minutes <= 0 ? L("now")
                    : minutes <= 90 ? LF("in %d min", minutes)
                    : event.start.formatted(date: .omitted, time: .shortened)
                add("Next up: %@ %@.", event.title, when)
            } else {
                add("Nothing else on your calendar today.")
            }
        }
        if let np = media.nowPlaying, np.isPlaying {
            add("Playing %@ by %@.", np.title, np.artist)
        }
        if screenTime.todayTotal >= 60 {
            add("%@ on screen today.", formatDuration(screenTime.todayTotal))
        }
        if result.characters.isEmpty { result = AttributedString(L("Have a good day.")) }
        return result
    }

    private func highlighted(_ format: String, _ values: [String]) -> AttributedString {
        let marker = "\u{1F}"
        let marked = String(format: L(format), arguments: values.map { marker + $0 + marker })
        var output = AttributedString()
        for (index, part) in marked.components(separatedBy: marker).enumerated() where !part.isEmpty {
            var piece = AttributedString(part)
            if index % 2 == 1 {                       // inside markers = a value
                piece.foregroundColor = Theme.primary
                piece.font = .system(size: 18, weight: .semibold, design: .rounded)
            }
            output.append(piece)
        }
        return output
    }
}

/// Rounded action chip used on the dashboard.
private struct Chip: View {
    let symbol: String
    let title: String
    var prominent = false
    let action: () -> Void

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "chip-\(symbol)-\(title)" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .symbolRenderingMode(prominent ? .monochrome : .multicolor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.black : Theme.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Theme.accentGradient)
                                         : AnyShapeStyle(Color.white.opacity(hover.isHovered(hoverID) ? 0.16 : 0.08)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(hoverID, inside: $0) }
        .scaleEffect(hover.isHovered(hoverID) ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered(hoverID))
    }
}

// MARK: Hero

private enum HeroKind { case media, event, weather }

private struct DashboardHero: View {
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var weather: WeatherStore
    let onOpen: (NotchTab) -> Void

    static func kind(media: MediaController, calendar: CalendarStore) -> HeroKind {
        if media.nowPlaying != nil { return .media }
        if nextEvent(calendar) != nil { return .event }
        return .weather
    }

    static func nextEvent(_ calendar: CalendarStore) -> CalendarEntry? {
        calendar.entries.first { !$0.isAllDay && Calendar.current.isDateInToday($0.start) && $0.end > Date() }
    }

    var body: some View {
        ZStack {
            switch Self.kind(media: media, calendar: calendar) {
            case .media:
                if let np = media.nowPlaying { MediaHero(np: np, media: media) }
            case .event:
                if let event = Self.nextEvent(calendar) { EventHero(event: event, calendar: calendar) }
            case .weather:
                WeatherHero(weather: weather)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .animation(Theme.spring, value: Self.kind(media: media, calendar: calendar))
    }
}

private struct MediaHero: View {
    let np: MediaController.NowPlaying
    let media: MediaController

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(nowPlaying: np, size: 112, radius: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    EqualizerView(isPlaying: np.isPlaying, bars: 4, color: Theme.mint, spacing: 2)
                        .frame(width: 14, height: 11)
                    Text("\(np.isPlaying ? L("Now Playing") : L("Paused")) · \(np.player.rawValue)".uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(np.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(np.artist)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ProgressBar(nowPlaying: np, showTimes: false) { media.seek(to: $0) }
                TransportControls(media: media, isPlaying: np.isPlaying, compact: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            ZStack {
                Color(white: 0.08)
                AmbientArtwork(nowPlaying: np).opacity(1.6)
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            }
        )
    }
}

private struct EventHero: View {
    let event: CalendarEntry
    let calendar: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(event.color).frame(width: 7, height: 7)
                Text(L("Up Next").uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            Text(event.title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let minutes = Int((event.start.timeIntervalSince(context.date) / 60).rounded(.up))
                let when = minutes <= 0 ? L("now") : LF("in %d min", minutes)
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))  ·  \(when)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            Spacer(minLength: 0)
            if event.joinURL != nil {
                Button { calendar.join(event) } label: {
                    Label(L("Join"), systemImage: "video.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.mint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [event.color.opacity(0.55), Color(white: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

private struct WeatherHero: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let s = weather.snapshot {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill").font(.system(size: 8, weight: .bold))
                    Text(weather.placeName.isEmpty ? L("Weather") : weather.placeName).lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                HStack(alignment: .center) {
                    Text(temp(s.temperature))
                        .font(.system(size: 54, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    WeatherIcon(code: s.code, isDay: s.isDay, size: 40)
                }
                Text(WeatherCode.description(s.code))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(LF("H %@   L %@   ·   Feels like %@", temp(s.high), temp(s.low), temp(s.feelsLike)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
            } else {
                WeatherPlaceholder(weather: weather)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyBackground(snapshot: weather.snapshot))
    }
}

// MARK: Glance list

private struct GlanceList: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var media: MediaController
    @ObservedObject var weather: WeatherStore
    @ObservedObject var screenTime: ScreenTimeStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusTimer
    let onOpen: (NotchTab) -> Void

    var body: some View {
        let hero = DashboardHero.kind(media: media, calendar: calendar)
        VStack(spacing: 0) {
            if hero == .event { weatherRow } else { calendarRow }
            divider
            if hero == .weather { focusRow } else { weatherRow }
            divider
            screenTimeRow
            divider
            clipboardRow
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 40)
    }

    private var calendarRow: some View {
        let next = calendar.entries.first
        let subtitle: String
        let title: String
        switch calendar.access {
        case .granted:
            title = next?.title ?? L("Nothing else today")
            subtitle = next.map { EventRow.timeText(for: $0) } ?? L("Calendar")
        case .denied:
            title = L("Calendar access is off"); subtitle = L("Calendar")
        case .unknown:
            title = L("Allow Calendar Access"); subtitle = L("See your next events here.")
        }
        return GlanceRow(symbol: "calendar", tint: Theme.coral, title: title, subtitle: subtitle) {
            if calendar.access == .unknown { calendar.requestAccess() } else { onOpen(.calendar) }
        } trailing: {
            if let next, next.joinURL != nil {
                JoinButton { calendar.join(next) }
            }
        }
    }

    private var weatherRow: some View {
        let s = weather.snapshot
        return GlanceRow(symbol: "cloud.sun.fill", tint: Theme.sky,
                         title: s.map { WeatherCode.description($0.code) } ?? L("Loading weather…"),
                         subtitle: s.map { LF("H %@  L %@  ·  Feels %@", temp($0.high), temp($0.low), temp($0.feelsLike)) }
                             ?? (weather.placeName.isEmpty ? L("Weather") : weather.placeName)) {
            onOpen(.weather)
        } trailing: {
            if let s {
                HStack(spacing: 6) {
                    WeatherIcon(code: s.code, isDay: s.isDay, size: 14)
                    Text(temp(s.temperature))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primary)
                }
            }
        }
    }

    private var screenTimeRow: some View {
        let top = screenTime.todayApps.first
        return GlanceRow(symbol: "hourglass", tint: Color(red: 1, green: 0.45, blue: 0.7),
                         title: L("Screen Time"),
                         subtitle: top.map { "\($0.name) · \(formatDuration($0.seconds))" } ?? L("today")) {
            onOpen(.screenTime)
        } trailing: {
            HStack(spacing: 8) {
                Text(formatDuration(screenTime.todayTotal))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                UsageDonut(categories: screenTime.todayCategories, store: screenTime, lineRatio: 0.6)
                    .frame(width: 24, height: 24)
            }
        }
    }

    private var clipboardRow: some View {
        let latest: String? = clipboard.items.first.map {
            switch $0.content {
            case .text(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            case .image: return L("Image")
            case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: ", ")
            }
        }
        return GlanceRow(symbol: "doc.on.clipboard", tint: Theme.amber,
                         title: latest ?? L("Copy something"), subtitle: L("Clipboard")) {
            if let first = clipboard.items.first { clipboard.copy(first) } else { onOpen(.clipboard) }
        } trailing: {
            Text("\(clipboard.items.count)/\(ClipboardStore.maxItems)")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            IconButton(symbol: "chevron.right", help: L("Clipboard")) { onOpen(.clipboard) }
        }
    }

    private var focusRow: some View {
        GlanceRow(symbol: "timer", tint: Theme.accent,
                  title: focus.phase == .focus ? L("Focus") : L("Break"),
                  subtitle: LF("Sessions today: %d", focus.sessionsToday)) {
            onOpen(.tools)
        } trailing: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(FocusFormat.clock(focus.remaining(at: context.date)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
            }
            IconButton(symbol: focus.isRunning ? "pause.fill" : "play.fill",
                       help: focus.isRunning ? L("Pause") : L("Start")) { focus.toggle() }
        }
    }
}

/// One line of the glance list: tinted icon, title + subtitle, trailing accessory. Whole row is clickable.
private struct GlanceRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "glance-\(symbol)" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hover.isHovered(hoverID) ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover.update(hoverID, inside: $0) }
        .animation(.easeOut(duration: 0.12), value: hover.isHovered(hoverID))
    }
}

// MARK: Control strip

private struct ControlStrip: View {
    @ObservedObject var controls: SystemHUDMonitor
    @ObservedObject var focus: FocusTimer
    let onOpen: (NotchTab) -> Void

    var body: some View {
        HStack(spacing: 12) {
            StripSlider(symbol: "sun.max.fill", value: controls.brightness, enabled: controls.brightnessAvailable) {
                controls.setBrightness($0)
            }
            StripSlider(symbol: controls.muted || controls.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        value: controls.muted ? 0 : controls.volume, enabled: controls.volumeAvailable) {
                controls.setVolume($0)
            }
            Button { focus.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: focus.isRunning ? "pause.fill" : "timer")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(focus.isActive ? FocusFormat.clock(focus.remaining(at: context.date)) : L("Focus"))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(focus.isRunning ? Color.black : Theme.primary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(focus.isRunning ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.fill)))
            }
            .buttonStyle(.plain)
            IconButton(symbol: "note.text", help: L("Notes")) { onOpen(.tools) }
            IconButton(symbol: "camera.viewfinder", help: L("Screenshots")) { onOpen(.files) }
        }
    }
}

/// Slim slider with the icon inside the fill (iOS Control Center style).
private struct StripSlider: View {
    let symbol: String
    let value: Double
    let enabled: Bool
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Color.white.opacity(enabled ? 0.9 : 0.3))
                    .frame(width: max(32, width * CGFloat(min(max(value, 0), 1))))
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.65))
                    Spacer()
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 11)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled, width > 0 else { return }
                onChange(Double(min(max(g.location.x / width, 0), 1)))
            })
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.85), value: value)
        }
        .frame(height: 32)
        .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - Controls widget (brightness + volume sliders)

private struct ControlsWidget: View {
    @ObservedObject var controls: SystemHUDMonitor

    var body: some View {
        WidgetFrame(symbol: "slider.horizontal.3", title: L("Controls"), tint: Theme.lilac) {
            VStack(alignment: .leading, spacing: 14) {
                LevelSlider(symbol: "sun.max.fill",
                            value: controls.brightness,
                            enabled: controls.brightnessAvailable,
                            caption: controls.brightnessAvailable ? L("Brightness") : L("Brightness unavailable")) {
                    controls.setBrightness($0)
                }
                LevelSlider(symbol: volumeSymbol,
                            value: controls.muted ? 0 : controls.volume,
                            enabled: controls.volumeAvailable,
                            caption: controls.volumeAvailable ? L("Volume") : L("Volume unavailable")) {
                    controls.setVolume($0)
                }
            }
        }
    }

    private var volumeSymbol: String {
        let v = controls.muted ? 0 : controls.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// iOS-style thick slider: drag or click anywhere on the track.
private struct LevelSlider: View {
    let symbol: String
    let value: Double
    let enabled: Bool
    let caption: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                let fill = max(30, width * CGFloat(min(max(value, 0), 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.white.opacity(enabled ? 0.92 : 0.3))
                        .frame(width: fill)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.65))
                        .padding(.leading, 10)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard enabled, width > 0 else { return }
                            onChange(Double(min(max(g.location.x / width, 0), 1)))
                        }
                )
                .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.85), value: value)
            }
            .frame(height: 30)
            Text("\(caption) · \(Int((value * 100).rounded())) %")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

private struct WidgetDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(width: 1).padding(.vertical, 4)
    }
}

/// Common widget frame: glass card, section label, content below.
private struct WidgetFrame<Content: View>: View {
    let symbol: String
    let title: String
    var tint: Color = Theme.accent
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(symbol: symbol, title: title, tint: tint, trailing: trailing)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
    }
}

/// Icon + title + subtitle row, as used in all list widgets.
private struct InfoRow: View {
    let symbol: String
    var symbolColor: Color = Theme.secondary
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(symbolColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CalendarWidget: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        WidgetFrame(symbol: "calendar", title: L("Up Next"), tint: Theme.coral) {
            switch store.access {
            case .unknown:
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("See your next events here."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    PillButton(title: L("Allow Access")) { store.requestAccess() }
                }
            case .denied:
                SmallHint(symbol: "lock", text: L("Calendar access is off"))
            case .granted:
                if store.entries.isEmpty {
                    SmallHint(symbol: "checkmark.circle", text: L("Nothing else today"))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.entries.prefix(3)) { entry in
                            HStack(spacing: 6) {
                                InfoRow(symbol: "circle.fill", symbolColor: entry.color,
                                        title: entry.title, subtitle: EventRow.timeText(for: entry))
                                if entry.joinURL != nil {
                                    JoinButton { store.join(entry) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MediaWidget: View {
    @ObservedObject var media: MediaController

    var body: some View {
        WidgetFrame(symbol: "music.note", title: L("Now Playing"), tint: Theme.mint) {
            if let np = media.nowPlaying {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ArtworkView(nowPlaying: np, size: 48, radius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(np.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                            Text(np.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        EqualizerView(isPlaying: np.isPlaying, bars: 4, color: Theme.accent, spacing: 2)
                            .frame(width: 16, height: 14)
                    }
                    ProgressBar(nowPlaying: np, showTimes: false) { media.seek(to: $0) }
                    TransportControls(media: media, isPlaying: np.isPlaying, compact: true)
                }
                .animation(Theme.spring, value: np.title)
            } else {
                MediaPlaceholder(media: media, compact: true)
            }
        }
        .background(
            AmbientArtwork(nowPlaying: media.nowPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
    }
}

/// Heavily blurred album art used as a coloured glow behind media content.
private struct AmbientArtwork: View {
    let nowPlaying: MediaController.NowPlaying?

    var body: some View {
        ZStack {
            if let np = nowPlaying, let url = np.artworkURL {
                Color.clear
                    .overlay {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                    }
                    .clipped()
                    .blur(radius: 30)
                    .saturation(1.4)
                    .opacity(0.38)
            } else if let np = nowPlaying {
                LinearGradient(colors: [(np.player == .spotify ? Theme.mint : Theme.coral).opacity(0.28), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .drawingGroup()
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: nowPlaying?.artworkURL)
    }
}

private struct ClipboardWidget: View {
    @ObservedObject var store: ClipboardStore

    var body: some View {
        WidgetFrame(symbol: "doc.on.clipboard", title: L("Clipboard"), tint: Theme.sky,
                    trailing: "\(store.items.count)/\(ClipboardStore.maxItems)") {
            if store.items.isEmpty {
                SmallHint(symbol: "doc.on.doc", text: L("Copy something"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(store.items.prefix(4))) { item in
                        ClipRow(item: item, isCopied: store.lastCopiedID == item.id) { store.copy(item) }
                    }
                }
            }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let isCopied: Bool
    let onCopy: () -> Void
    @ObservedObject private var hover = HoverTracker.shared

    var body: some View {
        let id = "cliprow-\(item.id.uuidString)"
        Button(action: onCopy) {
            HStack(spacing: 8) {
                Image(systemName: isCopied ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isCopied ? Color.green : Theme.secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover.isHovered(id) ? Theme.fillHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.update(id, inside: $0) }
        .animation(.easeOut(duration: 0.12), value: hover.isHovered(id))
    }

    private var symbol: String {
        if case .image = item.content { return "photo" }
        if case .files = item.content { return "doc" }
        return "text.alignleft"
    }

    private var label: String {
        switch item.content {
        case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Image")
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }
}

private struct FilesWidget: View {
    @ObservedObject var store: FileTrayStore
    let isTargeted: Bool

    var body: some View {
        WidgetFrame(symbol: "tray.full", title: L("File Tray"), tint: Theme.amber,
                    trailing: store.files.isEmpty ? nil : "\(store.files.count)") {
            if store.files.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(isTargeted ? 0.7 : 0.15),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 20, weight: .light))
                            Text(L("Drop files here"))
                                .font(.system(size: 11))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Color.white.opacity(isTargeted ? 0.9 : 0.4))
                    )
                    .frame(maxHeight: 120)
                    .animation(.easeOut(duration: 0.15), value: isTargeted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                    ForEach(Array(store.files.prefix(6))) { file in
                        VStack(spacing: 3) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 34, height: 34)
                            Text(file.url.lastPathComponent)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .onTapGesture(count: 2) { store.open(file) }
                        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
                        .help(file.url.path)
                    }
                }
            }
        }
    }
}

// MARK: - Shared controls

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "icon-\(symbol)" }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover.isHovered(hoverID) ? 1 : 0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(hover.isHovered(hoverID) ? Theme.fillHover : Theme.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.update(hoverID, inside: $0) }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }
}

private struct SmallHint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.tertiary)
    }
}

private struct ArtworkView: View {
    let nowPlaying: MediaController.NowPlaying
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.3)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url = nowPlaying.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        appIcon
                    }
                }
            } else {
                appIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    private var tint: Color {
        nowPlaying.player == .spotify ? Color(red: 0.11, green: 0.73, blue: 0.33)
                                      : Color(red: 0.98, green: 0.24, blue: 0.35)
    }

    private var appIcon: some View {
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: nowPlaying.player.bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage()
        }
        return Image(nsImage: icon).resizable().frame(width: size * 0.5, height: size * 0.5)
    }
}

private struct TransportControls: View {
    let media: MediaController
    let isPlaying: Bool
    let compact: Bool

    var body: some View {
        let small: CGFloat = compact ? 30 : 38
        let big: CGFloat = compact ? 36 : 48
        HStack(spacing: compact ? 12 : 20) {
            circleButton("backward.fill", size: small, filled: false) { media.previous() }
            circleButton(isPlaying ? "pause.fill" : "play.fill", size: big, filled: true) { media.playPause() }
            circleButton("forward.fill", size: small, filled: false) { media.next() }
        }
    }

    private func circleButton(_ symbol: String, size: CGFloat, filled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(filled ? Color.white : Color.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.12))))
                .shadow(color: filled ? Theme.accent.opacity(0.45) : .clear, radius: 10, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct MediaPlaceholder: View {
    @ObservedObject var media: MediaController
    let compact: Bool

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8) {
            if media.automationDenied {
                SmallHint(symbol: "lock", text: L("Allow Tenfold to control Spotify / Music"))
                PillButton(title: L("Open Settings")) { media.openAutomationSettings() }
            } else if let error = media.lastError {
                SmallHint(symbol: "exclamationmark.triangle", text: L("Couldn't read player"))
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(3)
            } else {
                SmallHint(symbol: "music.note", text: L("Nothing playing"))
                Text(L("Start Spotify or Music"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: compact ? .topLeading : .center)
    }
}

// MARK: - Card styling (full Clipboard / Files views)

private enum Card {
    static let height: CGFloat = 96
    static let radius: CGFloat = 14
    static let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)
}

private struct CardStyle: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: Card.height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Card.radius, style: .continuous)
                    .fill(hovering ? Theme.fillHover : Theme.fill)
            )
            .clipShape(RoundedRectangle(cornerRadius: Card.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Card.radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Card.radius, style: .continuous))
            .scaleEffect(hovering ? 1.04 : 1)
            .shadow(color: .black.opacity(hovering ? 0.4 : 0), radius: 8, y: 4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

private struct RemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(5)
    }
}

// MARK: - Clipboard (search + category columns)

struct ClipboardTab: View {
    @ObservedObject var store: ClipboardStore
    var keyboardMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if keyboardMode {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").foregroundStyle(Theme.accent)
                    Text(L("Press 1–0 to paste · Esc to close"))
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    if !AXIsProcessTrusted() {
                        Button {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                        } label: {
                            Text(L("Allow Accessibility to paste directly"))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .transition(.opacity)
            }
            ClipSearchField(query: $store.query)
            columns
        }
    }

    private var columns: some View {
        let items = store.filtered
        // Keys 1–0 always address the 10 newest items, independent of the search filter.
        let shortcuts = Dictionary(uniqueKeysWithValues: store.items.prefix(10).enumerated().map { ($1.id, $0) })
        // Colors only appears once a colour was copied (checked on the full history,
        // so the layout doesn't jump while searching).
        let kinds = ClipItem.Kind.allCases.filter { $0 != .color || store.items.contains { $0.kind == .color } }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(kinds, id: \.self) { kind in
                if kind != kinds.first { Rectangle().fill(Theme.divider).frame(width: 1) }
                ClipColumn(kind: kind, items: items.filter { $0.kind == kind }, store: store, shortcuts: shortcuts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(GlassCard(radius: 14))
        .animation(Theme.spring, value: items.map(\.id))
    }
}

private struct ClipSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $query, prompt: Text(L("Search")).foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill))
    }
}

private struct ClipColumn: View {
    let kind: ClipItem.Kind
    let items: [ClipItem]
    @ObservedObject var store: ClipboardStore
    let shortcuts: [UUID: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if items.isEmpty {
                Text("–")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) { entries }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var entries: some View {
        ForEach(items) { item in
            ClipEntry(item: item,
                      shortcut: shortcuts[item.id],
                      isCopied: store.lastCopiedID == item.id,
                      onCopy: { store.copy(item) },
                      onRemove: { store.remove(item) },
                      onPin: { store.togglePin(item) })
        }
    }

    private var title: String {
        switch kind {
        case .text: return L("Text")
        case .code: return L("Code")
        case .link: return L("Links")
        case .file: return L("Files")
        case .media: return L("Media")
        case .color: return L("Colors")
        }
    }
}

private struct ClipEntry: View {
    let item: ClipItem
    let shortcut: Int?
    let isCopied: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void
    let onPin: () -> Void

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "clip-\(item.id.uuidString)" }
    private var hovering: Bool { hover.isHovered(hoverID) }

    var body: some View {
        Button(action: onCopy) {
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Theme.fillHover : (item.kind == .code ? Theme.fill : Color.clear))
                )
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay {
                    if isCopied {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.7))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering && !isCopied {
                RemoveBadge(action: onRemove).padding(-4)
            }
        }
        .contextMenu {
            Button(item.isPinned ? L("Unpin") : L("Pin"), action: onPin)
            Button(L("Remove"), action: onRemove)
        }
        .animation(.easeOut(duration: 0.15), value: isCopied)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hover.update(hoverID, inside: $0) }
        .help(helpText)
    }

    /// Pin marker + paste shortcut (1–9, 0) for the 10 newest items.
    @ViewBuilder
    private var badge: some View {
        if item.isPinned || shortcut != nil {
            HStack(spacing: 3) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                if let shortcut {
                    Text("\(shortcut == 9 ? 0 : shortcut + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .padding(3)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let raw):
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.kind {
            case .code:
                Text(item.highlighted ?? AttributedString(s))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(4)
                    .padding(7)
            case .link:
                HStack(spacing: 6) {
                    iconTile("link", tint: Theme.sky)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(string: s)?.host ?? s)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Text(s)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.sky)
                            .lineLimit(1)
                    }
                }
                .padding(6)
            case .color:
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(item.swatch.map { Color(nsColor: $0) } ?? Theme.fill)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 22, height: 22)
                    Text(s)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(2)
                }
                .padding(6)
            default:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 2)
                    Text(s.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(6)
            }
        case .image(let img):
            let px = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
            mediaRow(Image(nsImage: img), fill: true, symbol: nil, title: L("Image"),
                     detail: "\(Int(px.width))×\(Int(px.height))")
        case .files(let urls):
            if item.kind == .media {
                let type = UTType(filenameExtension: urls[0].pathExtension)
                let isImage = type?.conforms(to: .image) ?? false
                let isAudio = type?.conforms(to: .audio) ?? false
                let ext = urls[0].pathExtension.uppercased()
                let detail = urls.count > 1 ? LF("%d files", urls.count)
                    : isImage ? (item.pixelSize.map { "\(ext) · \(Int($0.width))×\(Int($0.height))" } ?? ext)
                    : "\(ext) · \(isAudio ? L("Audio") : L("Video"))"
                mediaRow(item.thumbnail.map { Image(nsImage: $0) } ?? Image(systemName: "photo"),
                         fill: isImage && item.thumbnail != nil,
                         symbol: isImage ? nil : (isAudio ? "waveform" : "play.fill"),
                         title: urls[0].deletingPathExtension().lastPathComponent,
                         detail: detail)
            } else {
                HStack(spacing: 6) {
                    Image(nsImage: item.thumbnail ?? NSWorkspace.shared.icon(for: .data))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(urls.count == 1 ? urls[0].lastPathComponent : LF("%d files", urls.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(6)
            }
        }
    }

    private func iconTile(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.15)))
    }

    /// Thumbnail (photos fill, file icons fit) with an audio/video glyph, name and "type · size" line.
    private func mediaRow(_ image: Image, fill: Bool, symbol: String?, title: String, detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return HStack(spacing: 8) {
            shape
                .fill(Theme.fill)
                .frame(width: 40, height: 40)
                .overlay {
                    if fill {
                        image.resizable().scaledToFill()
                    } else {
                        image.resizable().scaledToFit().padding(5)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Theme.accent))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
    }

    private var helpText: String {
        switch item.content {
        case .text(let s): return String(s.prefix(300))
        case .image: return L("Image")
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        }
    }
}

// MARK: - Files

struct FilesTab: View {
    @ObservedObject var store: FileTrayStore
    @ObservedObject var screenshots: ScreenshotStore
    let isTargeted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tray
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScreenshotShelf(store: screenshots)
                .padding(12)
                .frame(width: 250)
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(GlassCard())
        }
    }

    @ViewBuilder
    private var tray: some View {
        if store.files.isEmpty {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(isTargeted ? 0.7 : 0.15),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(isTargeted ? 0.08 : 0.03))
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 26, weight: .light))
                        Text(L("Drop files on the notch to keep them here"))
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.45))
                )
                .animation(.easeOut(duration: 0.15), value: isTargeted)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Card.columns, spacing: 10) {
                    ForEach(store.files) { file in
                        FileCard(file: file, store: store)
                    }
                }
                .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(isTargeted ? 0.6 : 0), lineWidth: 1.5)
            )
        }
    }
}

/// Latest screenshots: drag out, click to copy, right-click for more.
private struct ScreenshotShelf: View {
    @ObservedObject var store: ScreenshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "camera.viewfinder", title: L("Screenshots"), tint: Theme.sky,
                         trailing: store.shots.isEmpty ? nil : "\(store.shots.count)")
            if store.shots.isEmpty {
                SmallHint(symbol: "camera.viewfinder", text: L("New screenshots appear here"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(store.shots) { shot in
                            ScreenshotThumb(shot: shot, store: store)
                        }
                    }
                }
            }
        }
    }
}

private struct ScreenshotThumb: View {
    let shot: ScreenshotStore.Shot
    let store: ScreenshotStore

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "shot-\(shot.id.path)" }

    var body: some View {
        Image(nsImage: store.thumbnail(for: shot))
            .resizable()
            .scaledToFill()
            .frame(height: 64)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(hover.isHovered(hoverID) ? 0.35 : 0.08), lineWidth: 1)
            )
            .overlay(alignment: .bottomLeading) {
                Text(shot.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .scaleEffect(hover.isHovered(hoverID) ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.isHovered(hoverID))
            .contentShape(Rectangle())
            .onHover { hover.update(hoverID, inside: $0) }
            .onTapGesture { store.copy(shot) }
            .onDrag { NSItemProvider(contentsOf: shot.id) ?? NSItemProvider() }
            .contextMenu {
                Button(L("Copy")) { store.copy(shot) }
                Button(L("Show in Finder")) { store.reveal(shot) }
                Divider()
                Button(L("Move to Trash")) { store.trash(shot) }
            }
            .help(L("Click to copy · drag to use"))
    }
}

struct FileCard: View {
    let file: TrayFile
    let store: FileTrayStore

    @ObservedObject private var hover = HoverTracker.shared
    private var hoverID: String { "file-\(file.id.uuidString)" }
    private var hovering: Bool { hover.isHovered(hoverID) }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(file.url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .modifier(CardStyle(hovering: hovering))
        .overlay(alignment: .topTrailing) {
            if hovering { RemoveBadge { store.remove(file) } }
        }
        .onHover { hover.update(hoverID, inside: $0) }
        .onTapGesture(count: 2) { store.open(file) }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu {
            Button(L("Open")) { store.open(file) }
            Button(L("Show in Finder")) { store.reveal(file) }
            Button(L("AirDrop")) { store.airDrop([file.url]) }
            Divider()
            Button(L("Remove from Tray")) { store.remove(file) }
        }
        .help(file.url.path)
    }
}

// MARK: - Media (full)

struct MediaTab: View {
    @ObservedObject var media: MediaController
    @ObservedObject var controls: SystemHUDMonitor

    var body: some View {
        if let np = media.nowPlaying {
            HStack(alignment: .top, spacing: 22) {
                ArtworkView(nowPlaying: np, size: 150, radius: 18)

                // Track info, progress, transport
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        EqualizerView(isPlaying: np.isPlaying, bars: 4, color: .green, spacing: 2)
                            .frame(width: 14, height: 11)
                        Text("\(np.isPlaying ? L("Now Playing") : L("Paused")) · \(np.player.rawValue)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    Text(np.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .padding(.top, 6)
                    Text(np.album.isEmpty ? np.artist : "\(np.artist) · \(np.album)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)

                    EqualizerView(isPlaying: np.isPlaying, bars: 36, color: Theme.accent, spacing: 4)
                        .frame(height: 34)
                        .padding(.top, 10)

                    Spacer(minLength: 4)

                    ProgressBar(nowPlaying: np, showTimes: true) { media.seek(to: $0) }

                    HStack(spacing: 18) {
                        ToggleIcon(symbol: "shuffle", isOn: np.shuffle, help: L("Shuffle")) { media.toggleShuffle() }
                        TransportControls(media: media, isPlaying: np.isPlaying, compact: false)
                        ToggleIcon(symbol: "repeat", isOn: np.repeatOn, help: L("Repeat")) { media.toggleRepeat() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                }
                .frame(maxHeight: .infinity)

                WidgetDivider()

                // Side column: output volume + open player
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "hifispeaker.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("Output"))
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(Theme.primary)

                    LevelSlider(symbol: "speaker.wave.2.fill",
                                value: controls.muted ? 0 : controls.volume,
                                enabled: controls.volumeAvailable,
                                caption: L("Volume")) { controls.setVolume($0) }

                    Spacer(minLength: 0)

                    PillButton(title: LF("Open %@", np.player.rawValue)) { media.openPlayer() }
                }
                .frame(width: 180)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .animation(Theme.spring, value: np.title)
            .padding(14)
            .modifier(GlassCard(radius: 22))
            .background(
                AmbientArtwork(nowPlaying: np)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
        } else {
            MediaPlaceholder(media: media, compact: false)
                .modifier(GlassCard(radius: 22))
        }
    }
}

/// Equalizer bars. Real spectrum from the system audio (AudioSpectrum) when available;
/// falls back to a smooth animation if the System Audio permission is missing or the feature is off.
private struct EqualizerView: View {
    let isPlaying: Bool
    let bars: Int
    let color: Color
    let spacing: CGFloat

    @ObservedObject private var spectrum = AudioSpectrum.shared

    var body: some View {
        Group {
            if isPlaying && spectrum.isLive {
                realBars
            } else {
                animatedBars
            }
        }
        .animation(.easeOut(duration: 0.35), value: isPlaying)
    }

    private var realBars: some View {
        SpectrumBars(bars: max(bars, 1), color: color, spacing: spacing)
    }

    private var animatedBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let count = max(bars, 1)
                let barWidth = max((geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(color.opacity(0.55 + 0.45 * Double(level(i, t))))
                            .frame(width: barWidth,
                                   height: max(barWidth, geo.size.height * level(i, t)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Fallback: smooth pseudo-random level per bar from two overlapping sine waves.
    private func level(_ index: Int, _ t: Double) -> CGFloat {
        guard isPlaying else { return 0.18 }
        let x = Double(index)
        let fast = sin(t * (6.0 + (x * 1.7).truncatingRemainder(dividingBy: 4.0)) + x * 1.3)
        let slow = sin(t * (2.2 + (x * 0.9).truncatingRemainder(dividingBy: 3.0)) + x * 0.7)
        let envelope = 0.75 + 0.25 * sin(t * 1.1 + x * 0.25)
        let value = (0.15 + 0.85 * abs(fast * 0.6 + slow * 0.4)) * envelope
        return CGFloat(min(max(value, 0.12), 1))
    }
}

/// Track progress with smooth local extrapolation between polls. Click/drag to seek.
private struct ProgressBar: View {
    let nowPlaying: MediaController.NowPlaying
    let showTimes: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date)
            let duration = nowPlaying.duration
            let fraction = duration > 0 ? CGFloat(min(elapsed / duration, 1)) : 0

            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { g in
                            guard duration > 0, geo.size.width > 0 else { return }
                            onSeek(Double(min(max(g.location.x / geo.size.width, 0), 1)) * duration)
                        }
                    )
                }
                .frame(height: 12)

                if showTimes {
                    HStack {
                        Text(Self.format(elapsed))
                        Spacer()
                        Text("-" + Self.format(max(duration - elapsed, 0)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct ToggleIcon: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Color.white.opacity(0.45))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Calendar (full): month grid | day + wheel + timeline

struct CalendarTab: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MonthGrid(store: store)
                .padding(12)
                .frame(width: 290)
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(GlassCard())

            VStack(alignment: .leading, spacing: 8) {
                DayHeader(store: store)
                DateWheel(store: store)
                    .frame(height: 50)
                DayTimeline(store: store)
                    .id(store.selectedDate)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(GlassCard())
        }
        .animation(Theme.spring, value: store.selectedDate)
    }
}

/// Compact month calendar: « ‹ October 2026 › »  +  7-column day grid.
private struct MonthGrid: View {
    @ObservedObject var store: CalendarStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(store.selectedDate.formatted(.dateTime.month(.wide)))
                        .foregroundStyle(Theme.primary)
                    Text(store.selectedDate.formatted(.dateTime.year()))
                        .foregroundStyle(Theme.accent)
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                Spacer(minLength: 4)
                navButton("chevron.left.2", help: L("Previous year")) { store.shiftYear(-1) }
                navButton("chevron.left", help: L("Previous month")) { store.shiftMonth(-1) }
                navButton("chevron.right", help: L("Next month")) { store.shiftMonth(1) }
                navButton("chevron.right.2", help: L("Next year")) { store.shiftYear(1) }
            }
            .frame(height: 22)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(store.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(height: 12)
                }
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(store.gridCells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        GridDayCell(day: day,
                                    isSelected: day == store.selectedDate,
                                    isToday: Calendar.current.isDateInToday(day),
                                    hasEvents: store.eventDays.contains(day))
                            .onTapGesture { withAnimation(Theme.spring) { store.select(day) } }
                    } else {
                        Color.clear.frame(height: 21)
                    }
                }
            }
            .id(store.selectedDate.formatted(.dateTime.year().month()))
            .transition(.opacity)
        }
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Theme.spring) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct GridDayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let hasEvents: Bool

    var body: some View {
        Text(day.formatted(.dateTime.day()))
            .font(.system(size: 11, weight: isSelected || isToday ? .bold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? Color.black : (isToday ? Theme.accent : Theme.primary.opacity(0.85)))
            .frame(width: 21, height: 21)
            .background(
                Circle().fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                Circle().strokeBorder(isToday && !isSelected ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(isSelected ? Color.black.opacity(0.55) : Theme.accent)
                    .frame(width: 3, height: 3)
                    .offset(y: -2)
                    .opacity(hasEvents ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(Theme.spring, value: isSelected)
    }
}

/// "SATURDAY · TODAY"  /  "3 October 2026"  ·  events count  ·  Today button
private struct DayHeader: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        let date = store.selectedDate
        let isToday = Calendar.current.isDateInToday(date)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text((date.formatted(.dateTime.weekday(.wide)) + (isToday ? " · " + L("Today") : "")).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.accent)
                Text(date.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if store.access == .granted {
                Text(store.dayEntries.isEmpty ? L("No events")
                     : (store.dayEntries.count == 1 ? L("1 event") : LF("%d events", store.dayEntries.count)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            if !isToday {
                Button {
                    withAnimation(Theme.spring) { store.goToToday() }
                } label: {
                    Text(L("Today"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }
}

/// Horizontal day wheel for the shown month – scroll (trackpad / Shift + wheel) or click; snaps to centre.
private struct DateWheel: View {
    @ObservedObject var store: CalendarStore

    private let cellWidth: CGFloat = 40
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let margin = max((geo.size.width - cellWidth) / 2, 0)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(store.monthDays, id: \.self) { day in
                            DayCell(day: day,
                                    isSelected: day == store.selectedDate,
                                    isToday: Calendar.current.isDateInToday(day),
                                    hasEvents: store.eventDays.contains(day))
                                .frame(width: cellWidth, height: geo.size.height)
                                .id(day)
                                .onTapGesture { withAnimation(Theme.spring) { store.select(day) } }
                                .visualEffect { content, geometry in
                                    let frame = geometry.frame(in: .scrollView(axis: .horizontal))
                                    let width = geometry.bounds(of: .scrollView(axis: .horizontal))?.width ?? 1
                                    let half = max(width / 2, 1)
                                    let t = min(abs(frame.midX - half) / half, 1)      // 0 centre … 1 edge
                                    return content
                                        .scaleEffect(1 - 0.18 * t)
                                        .opacity(1 - 0.75 * t)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $store.wheelSelection, anchor: .center)
                .onAppear { proxy.scrollTo(store.selectedDate, anchor: .center) }
                .onChange(of: store.selectedDate) { _, newValue in
                    withAnimation(Theme.spring) { proxy.scrollTo(newValue, anchor: .center) }
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.1),
                                           .init(color: .black, location: 0.9),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                )
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let hasEvents: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.55) : Theme.tertiary)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? Color.black : (isToday ? Theme.accent : Color.white))
            Circle()
                .fill(isSelected ? Color.black.opacity(0.55) : Theme.accent)
                .frame(width: 3, height: 3)
                .opacity(hasEvents ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.fill))
        )
        .shadow(color: isSelected ? Theme.accent.opacity(0.4) : .clear, radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(Theme.spring, value: isSelected)
    }
}

/// Events of the selected day as a compact timeline.
private struct DayTimeline: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        switch store.access {
        case .unknown:
            HStack(spacing: 12) {
                SmallHint(symbol: "calendar", text: L("Allow access to see your events"))
                PillButton(title: L("Allow Calendar Access")) { store.requestAccess() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            SmallHint(symbol: "lock", text: L("Calendar access is off – System Settings → Privacy & Security → Calendars"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .granted:
            if store.dayEntries.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                    Text(L("Nothing planned"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                              spacing: 6) {
                        ForEach(store.dayEntries) { entry in
                            TimelineRow(entry: entry) { store.join(entry) }
                        }
                    }
                }
            }
        }
    }
}

/// Small "Join" pill for events with a Teams / Zoom / Meet / Webex link.
private struct JoinButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.system(size: 8, weight: .bold))
                Text(L("Join")).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.mint))
        }
        .buttonStyle(.plain)
    }
}

private struct TimelineRow: View {
    let entry: CalendarEntry
    var onJoin: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            Text(entry.isAllDay ? L("All-day") : entry.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, alignment: .trailing)
            Capsule().fill(entry.color).frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !entry.isAllDay {
                    Text("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 0)
            if entry.joinURL != nil, let onJoin {
                JoinButton(action: onJoin)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(entry.color.opacity(0.12)))
    }
}

struct DateBlock: View {
    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0.38, blue: 0.36))
            Text(now.formatted(.dateTime.day()))
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(now.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EventRow: View {
    let entry: CalendarEntry

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func timeText(for entry: CalendarEntry) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(entry.start) {
            day = L("Today")
        } else if cal.isDateInTomorrow(entry.start) {
            day = L("Tomorrow")
        } else {
            day = entry.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if entry.isAllDay { return "\(day) · " + L("All day") }
        return "\(day) · \(time.string(from: entry.start)) – \(time.string(from: entry.end))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(entry.color).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Self.timeText(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(GlassCard(radius: 12))
    }
}

// MARK: - Shared

struct EmptyHint: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light))
            Text(text)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Weather

/// Sky gradient that follows the weather condition and time of day (dawn/dusk glow, night).
private struct SkyBackground: View {
    let snapshot: WeatherSnapshot?

    var body: some View {
        let colors = Self.colors(for: snapshot)
        ZStack {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            // Sun / moon glow
            RadialGradient(colors: [glowColor.opacity(0.55), .clear],
                           center: UnitPoint(x: 0.82, y: 0.05), startRadius: 0, endRadius: 160)
            // Keep text readable towards the bottom
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.8), value: snapshot?.code)
    }

    private var glowColor: Color {
        guard let s = snapshot else { return .clear }
        switch Self.phase(s) {
        case .night: return Color(white: 0.85).opacity(0.35)
        case .golden: return Color(red: 1, green: 0.75, blue: 0.4)
        case .day: return WeatherCode.category(s.code) == .clear ? Color(red: 1, green: 0.95, blue: 0.7) : .clear
        }
    }

    enum Phase { case day, golden, night }

    static func phase(_ s: WeatherSnapshot) -> Phase {
        let now = Date()
        for edge in [s.sunrise, s.sunset].compactMap({ $0 }) where abs(now.timeIntervalSince(edge)) < 50 * 60 {
            return .golden
        }
        return s.isDay ? .day : .night
    }

    static func colors(for snapshot: WeatherSnapshot?) -> [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        guard let s = snapshot else { return [c(0.12, 0.14, 0.2), c(0.2, 0.22, 0.3)] }
        let category = WeatherCode.category(s.code)
        switch phase(s) {
        case .golden:
            return category == .clear || category == .partly
                ? [c(0.36, 0.30, 0.58), c(0.93, 0.52, 0.36)]
                : [c(0.30, 0.28, 0.40), c(0.66, 0.45, 0.40)]
        case .night:
            switch category {
            case .clear, .partly: return [c(0.02, 0.04, 0.14), c(0.10, 0.14, 0.32)]
            case .storm: return [c(0.04, 0.04, 0.08), c(0.16, 0.14, 0.24)]
            default: return [c(0.07, 0.08, 0.12), c(0.18, 0.20, 0.26)]
            }
        case .day:
            switch category {
            case .clear: return [c(0.16, 0.45, 0.86), c(0.46, 0.72, 0.96)]
            case .partly: return [c(0.24, 0.48, 0.78), c(0.56, 0.70, 0.86)]
            case .cloudy, .fog: return [c(0.38, 0.43, 0.52), c(0.60, 0.64, 0.71)]
            case .drizzle, .rain: return [c(0.22, 0.29, 0.40), c(0.40, 0.47, 0.57)]
            case .snow: return [c(0.50, 0.58, 0.70), c(0.78, 0.83, 0.91)]
            case .storm: return [c(0.14, 0.15, 0.24), c(0.32, 0.30, 0.42)]
            }
        }
    }
}

private func temp(_ value: Double) -> String { "\(Int(value.rounded()))°" }

private struct WeatherIcon: View {
    let code: Int
    let isDay: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: WeatherCode.symbol(code, isDay: isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
    }
}

/// Dashboard card: compact, glanceable.
private struct WeatherWidget: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = weather.snapshot {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill").font(.system(size: 8, weight: .bold))
                    Text(weather.placeName.isEmpty ? L("Weather") : weather.placeName)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))

                HStack(alignment: .top) {
                    Text(temp(s.temperature))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    WeatherIcon(code: s.code, isDay: s.isDay, size: 24)
                }
                Text(WeatherCode.description(s.code))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(LF("H %@  L %@  ·  Feels %@", temp(s.high), temp(s.low), temp(s.feelsLike)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    ForEach(s.hours.prefix(5)) { hour in
                        VStack(spacing: 3) {
                            Text(hour.id.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.7))
                            WeatherIcon(code: hour.code, isDay: hour.isDay, size: 12)
                            Text(temp(hour.temperature))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                WeatherPlaceholder(weather: weather)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyBackground(snapshot: weather.snapshot))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct WeatherPlaceholder: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch weather.status {
            case .failed(let message):
                SmallHint(symbol: "exclamationmark.triangle", text: message)
                PillButton(title: L("Weather Settings")) {
                    NotificationCenter.default.post(name: .tenfoldOpenSettings, object: nil)
                }
            default:
                SmallHint(symbol: "cloud.sun", text: L("Loading weather…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Full weather view: current conditions + chips | sunrise/sunset, hourly strip, 7-day outlook.
struct WeatherTab: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        Group {
            if let s = weather.snapshot {
                HStack(alignment: .top, spacing: 18) {
                    current(s)
                        .frame(width: 280)
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        sunRow(s)
                        hourly(s)
                        outlook(s)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(14)
            } else {
                WeatherPlaceholder(weather: weather)
                    .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SkyBackground(snapshot: weather.snapshot))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func current(_ s: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "location.fill").font(.system(size: 9, weight: .bold))
                Text(weather.placeName.isEmpty ? L("Current location") : weather.placeName).lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.85))

            HStack(alignment: .center, spacing: 10) {
                Text(temp(s.temperature))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 2) {
                    WeatherIcon(code: s.code, isDay: s.isDay, size: 22)
                    Text(WeatherCode.description(s.code))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            Text(LF("H %@   L %@   ·   Feels like %@", temp(s.high), temp(s.low), temp(s.feelsLike)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))

            Spacer(minLength: 6)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                WeatherChip(symbol: "humidity.fill", label: L("Humidity"), value: "\(Int(s.humidity.rounded())) %")
                WeatherChip(symbol: "wind", label: L("Wind"), value: "\(Int(s.windSpeed.rounded())) \(s.windUnit)")
                WeatherChip(symbol: "sun.max.trianglebadge.exclamationmark", label: L("UV max"),
                            value: String(format: "%.0f", s.uvMax))
                WeatherChip(symbol: "gauge.with.dots.needle.33percent", label: L("Pressure"),
                            value: "\(Int(s.pressure.rounded())) hPa")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sunRow(_ s: WeatherSnapshot) -> some View {
        HStack(spacing: 14) {
            if let rise = s.sunrise {
                Label(rise.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill")
            }
            if let set = s.sunset {
                Label(set.formatted(date: .omitted, time: .shortened), systemImage: "sunset.fill")
            }
            Spacer()
            Text(LF("Updated %@", s.fetchedAt.formatted(date: .omitted, time: .shortened)))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .symbolRenderingMode(.multicolor)
    }

    private func hourly(_ s: WeatherSnapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(s.hours.enumerated()), id: \.element.id) { index, hour in
                VStack(spacing: 4) {
                    Text(index == 0 ? L("Now") : hour.id.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                    WeatherIcon(code: hour.code, isDay: hour.isDay, size: 14)
                    Text(temp(hour.temperature))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    private func outlook(_ s: WeatherSnapshot) -> some View {
        let lowest = s.days.map(\.low).min() ?? 0
        let highest = s.days.map(\.high).max() ?? 1
        let range = max(highest - lowest, 1)
        return HStack(spacing: 6) {
            ForEach(Array(s.days.enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 4) {
                    Text(index == 0 ? L("Today") : day.id.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                    WeatherIcon(code: day.code, isDay: true, size: 14)
                    Text(temp(day.high))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    // Temperature range bar, relative to the week
                    GeometryReader { geo in
                        let top = CGFloat((highest - day.high) / range) * geo.size.height
                        let height = max(CGFloat((day.high - day.low) / range) * geo.size.height, 3)
                        Capsule().fill(Color.white.opacity(0.15))
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(LinearGradient(colors: [Theme.amber, Theme.sky],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(height: height)
                                    .offset(y: top)
                            }
                    }
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    Text(temp(day.low))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct WeatherChip: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.2)))
    }
}

// MARK: - Screen Time

private struct UsageDonut: View {
    let categories: [CategoryUsage]
    let store: ScreenTimeStore
    let lineRatio: Double

    var body: some View {
        Chart(categories) { item in
            SectorMark(angle: .value("Time", item.seconds),
                       innerRadius: .ratio(lineRatio),
                       angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(store.color(for: item.id))
        }
        .chartLegend(.hidden)
        .overlay {
            if categories.isEmpty {
                Circle()
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 8)
            }
        }
    }
}

/// Dashboard card: today's donut + total + top app.
private struct ScreenTimeWidget: View {
    @ObservedObject var store: ScreenTimeStore

    var body: some View {
        WidgetFrame(symbol: "hourglass", title: L("Screen Time"), tint: Color(red: 1, green: 0.45, blue: 0.7)) {
            let categories = store.todayCategories
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    UsageDonut(categories: categories, store: store, lineRatio: 0.66)
                    VStack(spacing: 0) {
                        Text(formatDuration(store.todayTotal))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                        Text(L("today"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(height: 86)
                .frame(maxWidth: .infinity)

                if let top = store.todayApps.first {
                    HStack(spacing: 6) {
                        AppIconView(bundleID: top.id, size: 14)
                        Text(top.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(formatDuration(top.seconds))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }
}

/// Full module: category donut | ranked apps | optional insights sidebar.
struct ScreenTimeTab: View {
    @ObservedObject var store: ScreenTimeStore

    var body: some View {
        let categories = store.todayCategories
        let apps = store.todayApps
        let total = store.todayTotal
        HStack(alignment: .top, spacing: 12) {
            // Categories
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(symbol: "chart.pie.fill", title: L("Categories"), tint: Color(red: 1, green: 0.45, blue: 0.7))
                ZStack {
                    UsageDonut(categories: categories, store: store, lineRatio: 0.64)
                    VStack(spacing: 1) {
                        Text(formatDuration(total))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                            .contentTransition(.numericText())
                        Text(L("today"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 200)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(categories.prefix(store.expandedHeight ? 6 : 3)) { item in
                        HStack(spacing: 6) {
                            Circle().fill(store.color(for: item.id)).frame(width: 6, height: 6)
                            Text(item.id.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(formatDuration(item.seconds))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 210)
            .frame(maxHeight: .infinity, alignment: .top)
            .modifier(GlassCard())

            // Ranked apps
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(symbol: "list.number", title: L("Top apps"), tint: Theme.sky,
                             trailing: apps.isEmpty ? nil : LF("%d apps", apps.count))
                if apps.isEmpty {
                    SmallHint(symbol: "hourglass", text: L("Tracking started – use your Mac and check back."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let maxSeconds = apps.first?.seconds ?? 1
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 7) {
                            ForEach(Array(apps.prefix(10).enumerated()), id: \.element.id) { index, app in
                                RankedAppRow(rank: index + 1, app: app,
                                             fraction: app.seconds / max(maxSeconds, 1),
                                             color: store.color(for: app.category),
                                             isCurrent: app.id == store.currentApp)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(GlassCard())

            // Insights
            if store.showInsights {
                ScreenTimeInsights(store: store, total: total, categories: categories)
                    .padding(12)
                    .frame(width: 220)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .modifier(GlassCard())
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Theme.spring, value: store.showInsights)
    }
}

private struct RankedAppRow: View {
    let rank: Int
    let app: AppUsage
    let fraction: Double
    let color: Color
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 12)
            AppIconView(bundleID: app.id, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if isCurrent {
                        Circle().fill(Theme.mint).frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 4)
                    Text(formatDuration(app.seconds))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(color).frame(width: max(geo.size.width * CGFloat(fraction), 3))
                    }
                }
                .frame(height: 4)
            }
        }
        .animation(Theme.spring, value: fraction)
    }
}

private struct ScreenTimeInsights: View {
    @ObservedObject var store: ScreenTimeStore
    let total: Double
    let categories: [CategoryUsage]

    var body: some View {
        let yesterday = store.yesterdayTotal
        let change: Double? = yesterday > 60 ? (total - yesterday) / yesterday : nil
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "sparkles", title: L("Insights"), tint: Theme.amber)

            HStack(spacing: 8) {
                InsightTile(value: "\(store.today.switches)", label: L("App switches"))
                InsightTile(value: change.map { String(format: "%@%.0f%%", $0 >= 0 ? "+" : "", $0 * 100) } ?? "—",
                            label: L("vs yesterday"),
                            tint: change.map { $0 > 0 ? Theme.coral : Theme.mint } ?? Theme.secondary)
            }

            if let top = categories.first, total > 0 {
                Text(LF("Mostly %@ today (%d %%)", top.id.title, Int((top.seconds / total * 100).rounded())))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(L("ACTIVITY BY HOUR"))
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            Chart(Array(store.today.hourly.enumerated()), id: \.offset) { hour, seconds in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", seconds / 60))
                    .foregroundStyle(Theme.accentGradient)
                    .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 44)
        }
    }
}

private struct InsightTile: View {
    let value: String
    let label: String
    var tint: Color = Theme.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Tools: focus timer | quick notes | camera mirror

struct ToolsTab: View {
    let focus: FocusTimer
    let notes: NotesStore
    let camera: CameraController

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let width = max(geo.size.width - spacing * 2, 0)
            HStack(alignment: .top, spacing: spacing) {
                FocusCard(timer: focus)
                    .frame(width: width * 0.32)
                NotesCard(notes: notes)
                    .frame(width: width * 0.40)
                CameraCard(camera: camera)
                    .frame(width: width * 0.28)
            }
            .frame(height: geo.size.height, alignment: .top)
        }
    }
}

private struct FocusCard: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        let tint = timer.phase == .focus ? Theme.accent : Theme.mint
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "timer", title: timer.phase == .focus ? L("Focus") : L("Break"), tint: tint,
                         trailing: LF("Sessions today: %d", timer.sessionsToday))
            HStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let progress = timer.progress(at: context.date)
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: max(progress, 0.001))
                            .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(FocusFormat.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.primary)
                    }
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    Button { timer.toggle() } label: {
                        Label(timer.isRunning ? L("Pause") : (timer.isActive ? L("Resume") : L("Start")),
                              systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(tint))
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        IconButton(symbol: "arrow.counterclockwise", help: L("Reset")) { timer.reset() }
                        IconButton(symbol: "forward.end.fill", help: L("Skip")) { timer.skip() }
                        Menu {
                            ForEach(FocusTimer.presets) { preset in
                                Button(LF("%d / %d min", preset.focus, preset.rest)) { timer.choose(preset) }
                            }
                        } label: {
                            Text("\(timer.preset.focus)/\(timer.preset.rest)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L("Focus / break length"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
    }
}

private struct NotesCard: View {
    @ObservedObject var notes: NotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "note.text", title: L("Notes"), tint: Theme.amber, trailing: L("Saved automatically"))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if notes.text.isEmpty {
                    Text(L("Jot something down…"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
    }
}

private struct CameraCard: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "camera.fill", title: L("Camera"), tint: Theme.coral)
            switch camera.status {
            case .running:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Button { camera.stop() } label: {
                            Text(L("Turn off"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 22)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
            case .off:
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.tertiary)
                    PillButton(title: L("Turn on camera")) { camera.start() }
                    Text(L("Quick check before a meeting"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                VStack(spacing: 8) {
                    SmallHint(symbol: "lock", text: L("Camera access is off"))
                    PillButton(title: L("Open Settings")) { camera.openPrivacySettings() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
        .onDisappear { camera.stop() }        // camera only runs while visible
    }
}

// MARK: - Live activity (closed notch while music plays)

private struct LiveActivityView: View {
    let item: LiveItem
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let wing = item.wing
        HStack(spacing: 0) {
            leading.frame(width: wing)
            Color.clear.frame(width: notchWidth)
            trailing.frame(width: wing)
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch item {
        case .music(let track):
            ArtworkView(nowPlaying: track, size: max(height - 12, 14), radius: 6)
        case .focus(let phase, _, _, _, _):
            Image(systemName: phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(phase == .focus ? Theme.accent : Theme.mint)
        case .meeting(let title, _):
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case .music(let track):
            EqualizerView(isPlaying: track.isPlaying, bars: 4, color: Theme.accent, spacing: 2)
                .frame(width: 18, height: max(height * 0.4, 10))
        case .focus(let phase, let isRunning, let endDate, let remaining, _):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = isRunning ? max((endDate ?? context.date).timeIntervalSince(context.date), 0) : remaining
                Text(FocusFormat.clock(left))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(phase == .focus ? Theme.accent : Theme.mint)
                    .opacity(isRunning ? 1 : 0.55)
            }
        case .meeting(_, let start):
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let minutes = Int((start.timeIntervalSince(context.date) / 60).rounded(.up))
                Text(minutes <= 0 ? L("now") : LF("in %d min", minutes))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.coral)
                    .lineLimit(1)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

enum FocusFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - HUD

struct HUDView: View {
    let event: HUDEvent
    let notchWidth: CGFloat

    var body: some View {
        let wing = NotchMetrics.hudWing
        let barWidth = wing - 26
        let level = CGFloat(event.muted ? 0 : min(max(event.level, 0), 1))

        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: wing)
            Color.clear.frame(width: notchWidth)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Theme.accent).frame(width: barWidth * level)
            }
            .frame(width: barWidth, height: 4)
            .frame(width: wing)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    private var symbol: String {
        switch event.kind {
        case .brightness:
            return "sun.max.fill"
        case .volume:
            if event.muted || event.level <= 0.001 { return "speaker.slash.fill" }
            if event.level < 0.34 { return "speaker.wave.1.fill" }
            if event.level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Usage (Claude Code + Codex, from local session logs)

/// "376k", "2.31M", "86.7k" – three significant digits.
private func compactTokens(_ n: Int) -> String {
    let v = Double(n)
    func fmt(_ x: Double, _ unit: String) -> String {
        String(format: x >= 100 ? "%.0f%@" : x >= 10 ? "%.1f%@" : "%.2f%@", x, unit)
    }
    if v >= 1_000_000_000 { return fmt(v / 1_000_000_000, "B") }
    if v >= 1_000_000 { return fmt(v / 1_000_000, "M") }
    if v >= 1_000 { return fmt(v / 1_000, "k") }
    return "\(n)"
}

struct UsageTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UsageToolCard(name: "Claude Code", symbol: "sparkle", tint: Theme.accent,
                          summary: store.claude, showsPlan: false, isLoading: store.isLoading)
            UsageToolCard(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.sky,
                          summary: store.codex, showsPlan: true, isLoading: store.isLoading)
            UsageHeatmapCard(store: store)
                .frame(width: 250)
        }
        .onAppear { store.activate() }
    }
}

private struct UsageToolCard: View {
    let name: String
    let symbol: String
    let tint: Color
    let summary: UsageStore.ToolSummary
    let showsPlan: Bool
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(symbol: symbol, title: name, tint: tint, trailing: summary.plan?.capitalized)
            if isLoading {
                UsageLoader()
            } else if !summary.installed {
                SmallHint(symbol: "questionmark.folder", text: L("No session logs found on this Mac."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                plan
                VStack(alignment: .leading, spacing: 0) {
                    Text(compactTokens(summary.today.fresh))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                    Text(L("fresh tokens today"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    SwiftUI.GridRow { stat(L("Input"), summary.today.input); stat(L("Cache read"), summary.today.cacheRead) }
                    SwiftUI.GridRow { stat(L("Cache write"), summary.today.cacheWrite); stat(L("Processed"), summary.today.processed) }
                    SwiftUI.GridRow { stat(L("Output"), summary.today.output); stat(L("Sessions"), summary.sessionsToday, raw: true) }
                }
                Spacer(minLength: 0)
                if let footer {
                    Text(footer)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
    }

    @ViewBuilder
    private var plan: some View {
        if showsPlan, summary.primary != nil || summary.secondary != nil {
            VStack(spacing: 4) {
                if let p = summary.primary { limitRow(L("5-hour"), p) }
                if let w = summary.secondary { limitRow(L("Weekly"), w) }
            }
        } else {
            Text(showsPlan ? L("No plan data yet") : L("Plan usage not available locally"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
    }

    /// A finished window counts as 0 % – the log only knows the value at the last request.
    private func limitRow(_ title: String, _ limit: UsageStore.Limit) -> some View {
        let expired = limit.resetsAt <= Date()
        let used = expired ? 0 : min(max(limit.usedPercent, 0), 100)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                Text("\(Int(used.rounded())) %").foregroundStyle(Theme.primary).monospacedDigit()
                if !expired {
                    Text(LF("resets in %@", resetText(limit.resetsAt.timeIntervalSinceNow)))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(tint).frame(width: geo.size.width * used / 100)
                }
            }
            .frame(height: 4)
        }
    }

    /// "3h 40m" within a day, "6d 4h" beyond.
    private func resetText(_ seconds: Double) -> String {
        guard seconds >= 86_400 else { return formatDuration(seconds) }
        let hours = Int(seconds / 3600)
        return "\(hours / 24)d \(hours % 24)h"
    }

    private func stat(_ title: String, _ value: Int, raw: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.tertiary)
            Spacer(minLength: 2)
            Text(raw ? "\(value)" : compactTokens(value)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
    }

    private var footer: String? {
        [summary.lastModel, summary.lastProject].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Spinner shown while the session logs are read for the first time.
private struct UsageLoader: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
            Text(L("Reading session logs…"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

/// GitHub-style grid of the last 17 weeks, shaded by fresh tokens (both tools).
private struct UsageHeatmapCard: View {
    @ObservedObject var store: UsageStore

    private static let weeks = 17
    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 2.5

    var body: some View {
        let daily = store.daily
        let columns = Self.columns()
        let maxValue = max(daily.values.max() ?? 0, 1)
        let active = daily.values.filter { $0 > 0 }.count
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(symbol: "square.grid.3x3.fill", title: L("Activity"), tint: tint)
            if store.isLoading {
                UsageLoader()
            } else {
            sourcePicker
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(columns.indices, id: \.self) { c in
                    VStack(spacing: Self.gap) {
                        ForEach(columns[c].indices, id: \.self) { r in
                            let day = columns[c][r]
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(day.map { shade(daily[$0] ?? 0, max: maxValue) } ?? Color.clear)
                                .frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Text(LF("%d active days", active))
                Spacer(minLength: 4)
                Text(L("Less"))
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(level: level))
                        .frame(width: 8, height: 8)
                }
                Text(L("More"))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
            Text(L("Fresh tokens = input + cache write + output. Cache reads are not counted."))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.isLoading)
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassCard())
    }

    /// Week columns (first weekday on top); future days are nil.
    private static func columns() -> [[Date?]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) ?? weekStart
        return (0..<weeks).map { w in
            (0..<7).map { d in
                guard let day = cal.date(byAdding: .day, value: w * 7 + d, to: first), day <= today else { return nil }
                return day
            }
        }
    }

    /// All / Claude / Codex
    private var sourcePicker: some View {
        HStack(spacing: 4) {
            ForEach(UsageStore.HeatmapSource.allCases, id: \.self) { source in
                let selected = store.heatmapSource == source
                Button { withAnimation(Theme.spring) { store.heatmapSource = source } } label: {
                    Text(title(source))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : Theme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? tint(for: source) : Theme.fill))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func title(_ source: UsageStore.HeatmapSource) -> String {
        switch source {
        case .all: return L("All")
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    private func tint(for source: UsageStore.HeatmapSource) -> Color {
        switch source {
        case .all: return Theme.mint
        case .claude: return Theme.accent
        case .codex: return Theme.sky
        }
    }

    private var tint: Color { tint(for: store.heatmapSource) }

    private func shade(_ value: Int, max: Int) -> Color {
        guard value > 0 else { return color(level: 0) }
        return color(level: min(4, Int((Double(value) / Double(max) * 4).rounded(.up))))
    }

    private func color(level: Int) -> Color {
        level == 0 ? Color.white.opacity(0.07) : tint.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }
}
