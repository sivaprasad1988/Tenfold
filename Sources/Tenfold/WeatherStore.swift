import AppKit
import Combine
import CoreLocation

// MARK: - Model

struct WeatherSnapshot: Equatable {
    struct Hour: Identifiable, Equatable {
        let id: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
    }

    struct Day: Identifiable, Equatable {
        let id: Date
        let code: Int
        let high: Double
        let low: Double
    }

    let temperature: Double
    let feelsLike: Double
    let humidity: Double
    let windSpeed: Double
    let windUnit: String
    let pressure: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let uvMax: Double
    let sunrise: Date?
    let sunset: Date?
    let hours: [Hour]          // next 12 hours
    let days: [Day]            // 7-day outlook
    let fetchedAt: Date
}

/// WMO weather interpretation codes (Open-Meteo).
enum WeatherCode {
    enum Category { case clear, partly, cloudy, fog, drizzle, rain, snow, storm }

    static func category(_ code: Int) -> Category {
        switch code {
        case 0, 1: return .clear
        case 2: return .partly
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .storm
        default: return .cloudy
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: return L("Clear")
        case 1: return L("Mainly clear")
        case 2: return L("Partly cloudy")
        case 3: return L("Overcast")
        case 45, 48: return L("Fog")
        case 51, 53, 55: return L("Drizzle")
        case 56, 57: return L("Freezing drizzle")
        case 61, 63: return L("Rain")
        case 65: return L("Heavy rain")
        case 66, 67: return L("Freezing rain")
        case 71, 73: return L("Snow")
        case 75: return L("Heavy snow")
        case 77: return L("Snow grains")
        case 80, 81: return L("Showers")
        case 82: return L("Heavy showers")
        case 85, 86: return L("Snow showers")
        case 95: return L("Thunderstorm")
        case 96, 99: return L("Thunderstorm, hail")
        default: return "—"
        }
    }

    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 85, 86: return "cloud.snow.fill"
        case 77: return "snowflake"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Open-Meteo responses

private struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let relative_humidity_2m: Double?
        let weather_code: Int?
        let is_day: Int?
        let wind_speed_10m: Double?
        let pressure_msl: Double?
    }

    struct Hourly: Decodable {
        let time: [TimeInterval]
        let temperature_2m: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }

    struct Daily: Decodable {
        let time: [TimeInterval]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let sunrise: [TimeInterval?]
        let sunset: [TimeInterval?]
        let uv_index_max: [Double?]
    }

    let current: Current
    let hourly: Hourly
    let daily: Daily
}

private struct GeocodingResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
    }
    let results: [Result]?
}

// MARK: - Store

/// Weather via Open-Meteo (free, no API key for non-commercial use).
@MainActor
final class WeatherStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Unit: String, CaseIterable, Identifiable {
        case celsius, fahrenheit
        var id: String { rawValue }
        var symbol: String { self == .celsius ? "°C" : "°F" }
    }

    enum LocationMode: String, CaseIterable, Identifiable {
        case automatic, city
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case idle, loading, ok
        case failed(String)
    }

    @Published var unit: Unit {
        didSet {
            guard unit != oldValue else { return }
            defaults.set(unit.rawValue, forKey: Keys.unit)
            refresh()
        }
    }

    @Published var locationMode: LocationMode {
        didSet {
            guard locationMode != oldValue else { return }
            defaults.set(locationMode.rawValue, forKey: Keys.mode)
            if locationMode == .automatic { requestLocation() } else if !cityQuery.isEmpty { applyCity() }
        }
    }

    /// Text field in Settings; applied with `applyCity()`.
    @Published var cityQuery: String

    @Published private(set) var placeName: String
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var status: Status = .idle

    private let defaults = UserDefaults.standard
    private let locationManager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var timer: Timer?

    private enum Keys {
        static let unit = "weather.unit"
        static let mode = "weather.mode"
        static let city = "weather.city"
        static let lat = "weather.lat"
        static let lon = "weather.lon"
        static let place = "weather.place"
    }

    override init() {
        let stored = UserDefaults.standard      // `self.defaults` is not usable before super.init
        unit = Unit(rawValue: stored.string(forKey: Keys.unit) ?? "") ?? .celsius
        locationMode = LocationMode(rawValue: stored.string(forKey: Keys.mode) ?? "") ?? .automatic
        cityQuery = stored.string(forKey: Keys.city) ?? ""
        placeName = stored.string(forKey: Keys.place) ?? ""
        if stored.object(forKey: Keys.lat) != nil {
            coordinate = CLLocationCoordinate2D(latitude: stored.double(forKey: Keys.lat),
                                                longitude: stored.double(forKey: Keys.lon))
        }
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        refresh()
        if locationMode == .automatic { requestLocation() }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Refreshes if the data is older than 10 minutes (called when the notch opens).
    func refreshIfStale() {
        guard let snapshot else { refresh(); return }
        if Date().timeIntervalSince(snapshot.fetchedAt) > 600 { refresh() }
    }

    func refresh() {
        guard let coordinate else {
            if locationMode == .automatic { requestLocation() }
            return
        }
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        Task { @MainActor in await load(latitude: lat, longitude: lon) }
    }

    func applyCity() {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        defaults.set(query, forKey: Keys.city)
        Task { @MainActor in
            status = .loading
            var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            components.queryItems = [URLQueryItem(name: "name", value: query),
                                     URLQueryItem(name: "count", value: "1"),
                                     URLQueryItem(name: "language", value: "en"),
                                     URLQueryItem(name: "format", value: "json")]
            do {
                let (data, _) = try await URLSession.shared.data(from: components.url!)
                let response = try JSONDecoder().decode(GeocodingResponse.self, from: data)
                guard let result = response.results?.first else {
                    status = .failed(LF("City “%@” not found", query))
                    return
                }
                let name = [result.name, result.country].compactMap { $0 }.joined(separator: ", ")
                setLocation(latitude: result.latitude, longitude: result.longitude, name: name)
                await load(latitude: result.latitude, longitude: result.longitude)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Location

    private func requestLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if coordinate == nil { status = .failed(L("Location access denied – choose a city in Settings")) }
        default:
            locationManager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.locationMode == .automatic else { return }
            self.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { @MainActor in
            guard self.locationMode == .automatic else { return }
            self.setLocation(latitude: lat, longitude: lon, name: self.placeName)
            await self.load(latitude: lat, longitude: lon)
            self.reverseGeocode(latitude: lat, longitude: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            if self.coordinate == nil { self.status = .failed(LF("Location unavailable: %@", message)) }
        }
    }

    private func reverseGeocode(latitude: Double, longitude: Double) {
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { [weak self] placemarks, _ in
            let name = placemarks?.first.map { [$0.locality, $0.country].compactMap { $0 }.joined(separator: ", ") }
            Task { @MainActor in
                guard let self, let name, !name.isEmpty else { return }
                self.placeName = name
                self.defaults.set(name, forKey: Keys.place)
            }
        }
    }

    private func setLocation(latitude: Double, longitude: Double, name: String) {
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        defaults.set(latitude, forKey: Keys.lat)
        defaults.set(longitude, forKey: Keys.lon)
        if !name.isEmpty {
            placeName = name
            defaults.set(name, forKey: Keys.place)
        }
    }

    // MARK: Forecast

    private func load(latitude: Double, longitude: Double) async {
        if snapshot == nil { status = .loading }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,pressure_msl"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max"),
            URLQueryItem(name: "temperature_unit", value: unit.rawValue),
            URLQueryItem(name: "wind_speed_unit", value: unit == .celsius ? "kmh" : "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
            snapshot = makeSnapshot(response)
            status = .ok
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func makeSnapshot(_ r: ForecastResponse) -> WeatherSnapshot {
        let now = Date()
        var hours: [WeatherSnapshot.Hour] = []
        for (i, t) in r.hourly.time.enumerated() {
            let date = Date(timeIntervalSince1970: t)
            guard date > now.addingTimeInterval(-3600), hours.count < 12,
                  i < r.hourly.temperature_2m.count, let temp = r.hourly.temperature_2m[i] else { continue }
            let code = i < r.hourly.weather_code.count ? (r.hourly.weather_code[i] ?? 3) : 3
            let day = i < r.hourly.is_day.count ? (r.hourly.is_day[i] ?? 1) == 1 : true
            hours.append(.init(id: date, temperature: temp, code: code, isDay: day))
        }

        var days: [WeatherSnapshot.Day] = []
        for (i, t) in r.daily.time.enumerated() {
            guard i < r.daily.temperature_2m_max.count, i < r.daily.temperature_2m_min.count,
                  let hi = r.daily.temperature_2m_max[i], let lo = r.daily.temperature_2m_min[i] else { continue }
            let code = i < r.daily.weather_code.count ? (r.daily.weather_code[i] ?? 3) : 3
            days.append(.init(id: Date(timeIntervalSince1970: t), code: code, high: hi, low: lo))
        }

        func first<T>(_ a: [T?]) -> T? { a.first ?? nil }
        let sunrise = first(r.daily.sunrise).map { Date(timeIntervalSince1970: $0) }
        let sunset = first(r.daily.sunset).map { Date(timeIntervalSince1970: $0) }

        return WeatherSnapshot(
            temperature: r.current.temperature_2m ?? hours.first?.temperature ?? 0,
            feelsLike: r.current.apparent_temperature ?? r.current.temperature_2m ?? 0,
            humidity: r.current.relative_humidity_2m ?? 0,
            windSpeed: r.current.wind_speed_10m ?? 0,
            windUnit: unit == .celsius ? "km/h" : "mph",
            pressure: r.current.pressure_msl ?? 0,
            code: r.current.weather_code ?? 3,
            isDay: (r.current.is_day ?? 1) == 1,
            high: days.first?.high ?? 0,
            low: days.first?.low ?? 0,
            uvMax: first(r.daily.uv_index_max) ?? 0,
            sunrise: sunrise,
            sunset: sunset,
            hours: hours,
            days: days,
            fetchedAt: now)
    }
}
