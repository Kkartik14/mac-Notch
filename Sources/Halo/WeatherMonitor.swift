import Foundation
import CoreLocation

/// Real weather monitor using CoreLocation + open-meteo (no API key).
/// Updates every 10 minutes.
final class WeatherMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let permissionLedger: HaloPermissionRequestLedger
    private var callback: ((WeatherActivity) -> Void)?
    private var refreshTimer: Timer?
    private var pendingTask: URLSessionDataTask?
    private var lastFetched: Date = .distantPast
    private var lastActivity: WeatherActivity?
    /// Latest activity for previews, even if quiet.
    var current: WeatherActivity? { lastActivity }

    init(permissionLedger: HaloPermissionRequestLedger = .shared) {
        self.permissionLedger = permissionLedger
        super.init()
    }

    deinit {
        refreshTimer?.invalidate()
        pendingTask?.cancel()
    }

    private static func locationAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways: return true
        case .authorized: return true // macOS "when in use" grant
        default: return false
        }
    }

    func start(callback: @escaping (WeatherActivity) -> Void) {
        self.callback = callback
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        let status = manager.authorizationStatus
        if status == .notDetermined && !permissionLedger.hasRequested(.location) {
            permissionLedger.markRequested(.location)
            manager.requestWhenInUseAuthorization()
        } else if Self.locationAuthorized(status) {
            manager.startUpdatingLocation()
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// Explicit retry used by the Permissions page. Automatic startup access
    /// is ledger-gated; an intentional user action may ask while undecided.
    func requestLocationAccess() {
        guard manager.authorizationStatus == .notDetermined else { return }
        permissionLedger.markRequested(.location)
        manager.requestWhenInUseAuthorization()
    }

    static func authorizationStatus() -> CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if Self.locationAuthorized(manager.authorizationStatus) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        manager.stopUpdatingLocation()
        fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Fall back to a default location so the UI has something useful.
        fetch(lat: 37.3318, lon: -122.0312)
    }

    private func refresh() {
        if let loc = manager.location {
            fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        } else if Date().timeIntervalSince(lastFetched) > 60 * 30 {
            // Fall back after a long stretch of no location data.
            fetch(lat: 37.3318, lon: -122.0312)
        }
    }

    private func fetch(lat: Double, lon: Double) {
        // Throttle to once per 5 minutes.
        if Date().timeIntervalSince(lastFetched) < 300, let last = lastActivity {
            callback?(last)
            return
        }
        // Coalesce: never have two weather requests in flight.
        pendingTask?.cancel()
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=auto&temperature_unit=celsius"
        guard let url = URL(string: urlString) else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current_weather"] as? [String: Any] else { return }
            let temp = (current["temperature"] as? Double).map { Int($0.rounded()) } ?? 0
            let code = current["weathercode"] as? Int ?? 0
            let wind = (current["windspeed"] as? Double).map { Int($0.rounded()) } ?? 0
            let isDay = (current["is_day"] as? Int ?? 1) == 1
            var hi: Int? = nil
            var lo: Int? = nil
            if let daily = json["daily"] as? [String: Any],
               let maxArr = daily["temperature_2m_max"] as? [Double],
               let minArr = daily["temperature_2m_min"] as? [Double],
               let max0 = maxArr.first, let min0 = minArr.first {
                hi = Int(max0.rounded())
                lo = Int(min0.rounded())
            }
            let (symbol, label) = Self.symbol(for: code, isDay: isDay)
            let activity = WeatherActivity(temperatureC: temp, condition: label, symbol: symbol, windKph: wind, highC: hi, lowC: lo, isDay: isDay)
            DispatchQueue.main.async {
                self.lastActivity = activity
                self.lastFetched = Date()
                self.pendingTask = nil
                self.callback?(activity)
            }
        }
        pendingTask = task
        task.resume()
    }

    static func symbol(for code: Int, isDay: Bool = true) -> (String, String) {
        switch code {
        case 0: return (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
        case 3: return ("cloud.fill", "Overcast")
        case 45, 48: return ("cloud.fog.fill", "Foggy")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 65, 66, 67: return ("cloud.rain.fill", "Rainy")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Snow")
        case 80, 81, 82: return ("cloud.heavyrain.fill", "Showers")
        case 85, 86: return ("cloud.snow.fill", "Snow Showers")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm")
        default: return ("cloud.fill", "Unknown")
        }
    }
}
