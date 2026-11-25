//
//  WeatherManager.swift
//  Hoverbird
//
//  Local weather for the Calendar section: Location Services for where you are,
//  Open-Meteo (free, no account) for the forecast. Fetched only when the
//  Calendar section opens, at most every 30 minutes.
//

import AppKit
import CoreLocation
import SwiftUI

struct DayForecast: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let code: Int
    let high: Double
    let low: Double
}

struct WeatherSnapshot: Equatable {
    let temperature: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let city: String?
    let days: [DayForecast]
    let fetched: Date
}

@MainActor
final class WeatherManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherManager()

    enum Status: Equatable { case idle, loading, needsPermission, denied, failed }

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var status: Status = .idle

    private let manager = CLLocationManager()
    private var cityCache: (CLLocation, String)?
    private let fahrenheit = Locale.current.measurementSystem == .us

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refreshIfNeeded() {
        if let snapshot, Date().timeIntervalSince(snapshot.fetched) < 1800 { return }
        refresh()
    }

    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .needsPermission
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = .denied
        default:
            status = .loading
            manager.requestLocation()
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let s = manager.authorizationStatus
            if s != .notDetermined && s != .denied && s != .restricted { self.refresh() }
            else if s == .denied || s == .restricted { self.status = .denied }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.fetch(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in if self.snapshot == nil { self.status = .failed } }
    }

    private func fetch(_ location: CLLocation) async {
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", lat)),
            .init(name: "longitude", value: String(format: "%.3f", lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "4"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any] else {
            status = snapshot == nil ? .failed : .idle
            return
        }
        let times = daily["time"] as? [String] ?? []
        let codes = daily["weather_code"] as? [Int] ?? []
        let highs = daily["temperature_2m_max"] as? [Double] ?? []
        let lows = daily["temperature_2m_min"] as? [Double] ?? []
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        var days: [DayForecast] = []
        for i in 0..<min(times.count, codes.count, highs.count, lows.count) {
            if let day = parser.date(from: times[i]) {
                days.append(DayForecast(day: day, code: codes[i], high: highs[i], low: lows[i]))
            }
        }
        let city = await cityName(for: location)
        snapshot = WeatherSnapshot(
            temperature: current["temperature_2m"] as? Double ?? 0,
            code: current["weather_code"] as? Int ?? 0,
            isDay: (current["is_day"] as? Int ?? 1) == 1,
            high: days.first?.high ?? 0, low: days.first?.low ?? 0,
            city: city, days: days, fetched: Date())
        status = .idle
    }

    private func cityName(for location: CLLocation) async -> String? {
        if let (cached, name) = cityCache, cached.distance(from: location) < 5000 { return name }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let name = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea
        if let name { cityCache = (location, name) }
        return name
    }

    // MARK: WMO weather codes

    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }
}
