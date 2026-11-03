import Foundation
import CoreLocation
import Combine

struct WeatherCondition {
    var description: String
    var symbol: String

    static func from(code: Int, isDay: Bool) -> WeatherCondition {
        func c(_ d: String, _ day: String, _ night: String? = nil) -> WeatherCondition {
            WeatherCondition(description: d, symbol: isDay ? day : (night ?? day))
        }
        switch code {
        case 0: return c("Clear sky", "sun.max.fill", "moon.stars.fill")
        case 1: return c("Mainly clear", "sun.max.fill", "moon.stars.fill")
        case 2: return c("Partly cloudy", "cloud.sun.fill", "cloud.moon.fill")
        case 3: return c("Overcast", "cloud.fill")
        case 45, 48: return c("Fog", "cloud.fog.fill")
        case 51, 53, 55: return c("Drizzle", "cloud.drizzle.fill")
        case 56, 57: return c("Freezing drizzle", "cloud.sleet.fill")
        case 61: return c("Light rain", "cloud.rain.fill")
        case 63: return c("Rain", "cloud.rain.fill")
        case 65: return c("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: return c("Freezing rain", "cloud.sleet.fill")
        case 71: return c("Light snow", "cloud.snow.fill")
        case 73: return c("Snow", "cloud.snow.fill")
        case 75: return c("Heavy snow", "snowflake")
        case 77: return c("Snow grains", "cloud.snow.fill")
        case 80, 81: return c("Rain showers", "cloud.sun.rain.fill", "cloud.moon.rain.fill")
        case 82: return c("Heavy showers", "cloud.heavyrain.fill")
        case 85, 86: return c("Snow showers", "cloud.snow.fill")
        case 95: return c("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: return c("Thunderstorm, hail", "cloud.bolt.rain.fill")
        default: return c("—", "cloud.fill")
        }
    }
}

struct WeatherData {
    struct Current {
        var temperature: Double
        var feelsLike: Double
        var humidity: Double
        var windSpeed: Double
        var windDirection: Double
        var pressure: Double
        var uv: Double
        var code: Int
        var isDay: Bool
        var condition: WeatherCondition { .from(code: code, isDay: isDay) }
    }
    struct Hour: Identifiable {
        var time: Date
        var temperature: Double
        var precipitation: Double
        var code: Int
        var isDay: Bool
        var id: Date { time }
        var condition: WeatherCondition { .from(code: code, isDay: isDay) }
    }
    struct Day: Identifiable {
        var date: Date
        var code: Int
        var high: Double
        var low: Double
        var sunrise: Date
        var sunset: Date
        var uvMax: Double
        var precipitation: Double
        var id: Date { date }
        var condition: WeatherCondition { .from(code: code, isDay: true) }
    }

    var current: Current
    var hours: [Hour]      // from the current hour onward
    var days: [Day]
    var timeZone: TimeZone
    var fetched: Date
}

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var data: WeatherData?
    @Published private(set) var placeName: String = ""
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?

    private var timer: Timer?
    private var active = false
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared
    private var lastCoordinate: CLLocationCoordinate2D?

    private init() {
        Publishers.CombineLatest4(settings.$useFahrenheit, settings.$useMph,
                                  settings.$followCurrentLocation, settings.$selectedLocationID)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$savedLocations.dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        LocationService.shared.$location
            .compactMap { $0 }
            .removeDuplicates { a, b in a.distance(from: b) < 2_000 }
            .sink { [weak self] _ in
                guard let self, self.settings.followCurrentLocation else { return }
                self.refresh()
            }
            .store(in: &cancellables)
    }

    var unitSymbol: String { settings.useFahrenheit ? "°F" : "°C" }
    var windUnit: String { settings.useMph ? "mph" : "kph" }

    func setActive(_ on: Bool) {
        active = on
        if on, timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard active else { return }
        Task { await load() }
    }

    private func resolveLocation() async -> (CLLocationCoordinate2D, String)? {
        let loc = LocationService.shared
        if settings.followCurrentLocation, loc.isAuthorized {
            loc.requestLocation()
            if let l = loc.location {
                let name = await loc.placeName(for: l) ?? "Current Location"
                return (l.coordinate, name)
            }
        }
        if let saved = settings.selectedLocation {
            return (CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude), saved.name)
        }
        // Zero-permission default: the city of the Mac's time zone.
        let tzCity = TimeZone.current.identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? "Cupertino"
        if let hit = try? await Geocoder.search(tzCity).first {
            return (CLLocationCoordinate2D(latitude: hit.latitude, longitude: hit.longitude), hit.name)
        }
        return nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let (coord, name) = await resolveLocation() else {
            errorMessage = "Choose a location in Settings"
            return
        }
        placeName = name
        lastCoordinate = coord
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", coord.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", coord.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure,uv_index"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "temperature_unit", value: settings.useFahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: settings.useMph ? "mph" : "kmh"),
        ]
        do {
            let (bytes, _) = try await URLSession.shared.data(from: comps.url!)
            let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: bytes)
            data = r.toWeather()
            errorMessage = nil
        } catch {
            if data == nil { errorMessage = "Weather unavailable" }
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let relative_humidity_2m: Double
        let apparent_temperature: Double
        let is_day: Int
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        let surface_pressure: Double
        let uv_index: Double?
    }
    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let precipitation_probability: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }
    struct Daily: Decodable {
        let time: [Double]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let sunrise: [Double]
        let sunset: [Double]
        let uv_index_max: [Double?]
        let precipitation_probability_max: [Double?]
    }

    let utc_offset_seconds: Int
    let current: Current
    let hourly: Hourly
    let daily: Daily

    func toWeather() -> WeatherData {
        let now = Date()
        let c = WeatherData.Current(
            temperature: current.temperature_2m, feelsLike: current.apparent_temperature,
            humidity: current.relative_humidity_2m, windSpeed: current.wind_speed_10m,
            windDirection: current.wind_direction_10m, pressure: current.surface_pressure,
            uv: current.uv_index ?? 0, code: current.weather_code, isDay: current.is_day == 1)
        var hours: [WeatherData.Hour] = []
        for (i, t) in hourly.time.enumerated() {
            let date = Date(timeIntervalSince1970: t)
            guard date.addingTimeInterval(3600) > now else { continue }
            hours.append(.init(time: date,
                               temperature: hourly.temperature_2m[safe: i].flatMap { $0 } ?? 0,
                               precipitation: hourly.precipitation_probability[safe: i].flatMap { $0 } ?? 0,
                               code: hourly.weather_code[safe: i].flatMap { $0 } ?? 0,
                               isDay: (hourly.is_day[safe: i].flatMap { $0 } ?? 1) == 1))
            if hours.count >= 25 { break }
        }
        var days: [WeatherData.Day] = []
        for (i, t) in daily.time.enumerated() {
            days.append(.init(date: Date(timeIntervalSince1970: t),
                              code: daily.weather_code[safe: i].flatMap { $0 } ?? 0,
                              high: daily.temperature_2m_max[safe: i].flatMap { $0 } ?? 0,
                              low: daily.temperature_2m_min[safe: i].flatMap { $0 } ?? 0,
                              sunrise: Date(timeIntervalSince1970: daily.sunrise[safe: i] ?? 0),
                              sunset: Date(timeIntervalSince1970: daily.sunset[safe: i] ?? 0),
                              uvMax: daily.uv_index_max[safe: i].flatMap { $0 } ?? 0,
                              precipitation: daily.precipitation_probability_max[safe: i].flatMap { $0 } ?? 0))
        }
        return WeatherData(current: c, hours: hours, days: days,
                           timeZone: TimeZone(secondsFromGMT: utc_offset_seconds) ?? .current, fetched: now)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct GeocodeResult: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?

    var detail: String { [admin1, country].compactMap { $0 }.joined(separator: ", ") }
}

enum Geocoder {
    private struct Response: Decodable { let results: [GeocodeResult]? }

    static func search(_ query: String) async throws -> [GeocodeResult] {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                            .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode(Response.self, from: data).results ?? []
    }
}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published private(set) var location: CLLocation?
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var nameCache: (CLLocation, String)?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        status = manager.authorizationStatus
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func requestLocation() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    func placeName(for location: CLLocation) async -> String? {
        if let cache = nameCache, cache.0.distance(from: location) < 2_000 { return cache.1 }
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        let name = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea ?? mark.name
        if let name { nameCache = (location, name) }
        return name
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.location = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if self.isAuthorized { self.manager.requestLocation() }
            Permissions.shared.refresh()
        }
    }
}
