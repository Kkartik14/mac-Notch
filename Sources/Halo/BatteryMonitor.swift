import Foundation
import IOKit.ps

/// Real battery monitor using IOKit Power Sources.
/// Fires the callback whenever the level or plug state changes.
final class BatteryMonitor {
    struct Charge { let level: Double; let pluggedIn: Bool; let minutesRemaining: Int? }

    private var callback: ((Charge) -> Void)?
    private var timer: Timer?
    private var powerObserver: NSObjectProtocol?
    private var lastLevel: Double = -1
    private var lastPlugged: Bool?
    /// Latest reading, even if unchanged since the last callback.
    private(set) var current: Charge?

    deinit { stop() }

    func start(callback: @escaping (Charge) -> Void) {
        self.callback = callback
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Store the token so it can be removed in stop()/deinit.
        // Previously leaked an observer on every start().
        if powerObserver == nil {
            powerObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("NSProcessInfoPowerStateDidChange"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = powerObserver {
            NotificationCenter.default.removeObserver(obs)
            powerObserver = nil
        }
    }

    func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        // Estimate once, not per-source: it is global, not per-battery.
        // >0 = valid minutes estimate; <=0 covers unknown/unlimited.
        let estimate = IOPSGetTimeRemainingEstimate()
        let minutes: Int? = estimate > 0 ? Int((estimate / 60.0).rounded()) : nil
        for psRef in list {
            guard let dict = IOPSGetPowerSourceDescription(blob, psRef)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard
                let current = dict[kIOPSCurrentCapacityKey] as? Int,
                let max = dict[kIOPSMaxCapacityKey] as? Int,
                max > 0
            else { continue }
            let level = Double(current) / Double(max)
            let pluggedIn = (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // Real estimate from the power source. Time remaining while charging
            // is time-until-full; on battery it is time-until-empty. The UI only
            // shows it while plugged in. <= 0 covers unknown/unlimited.
            let charge = Charge(level: level, pluggedIn: pluggedIn, minutesRemaining: minutes)
            self.current = charge
            if abs(level - lastLevel) > 0.005 || pluggedIn != lastPlugged {
                lastLevel = level
                lastPlugged = pluggedIn
                callback?(charge)
            }
            break // first valid battery is the system battery; ignore UPS extras
        }
    }

    static func etaText(minutes: Int?) -> String? {
        guard let m = minutes, m > 0 else { return nil }
        if m >= 60 { return String(format: "~%dh %02dm until full", m / 60, m % 60) }
        return "~\(m)m until full"
    }
}
