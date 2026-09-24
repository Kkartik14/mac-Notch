import Foundation
import IOKit.ps

/// Real battery monitor using IOKit Power Sources.
///
/// The monitor keeps the raw system read in one place so every battery UI
/// surface uses the same snapshot. It publishes only meaningful changes;
/// the timer is intentionally modest because power-source notifications and
/// the cached estimate are enough for a status surface.
final class BatteryMonitor {
    struct Charge: Equatable {
        let level: Double
        let pluggedIn: Bool
        let isCharging: Bool
        let isFullyCharged: Bool
        let isLowPowerMode: Bool
        let minutesRemaining: Int?
        let healthPercent: Int?
        let cycleCount: Int?

        // Keep the compact initializer useful for previews and older callers.
        init(
            level: Double,
            pluggedIn: Bool,
            minutesRemaining: Int?,
            isCharging: Bool = false,
            isFullyCharged: Bool = false,
            isLowPowerMode: Bool = false,
            healthPercent: Int? = nil,
            cycleCount: Int? = nil
        ) {
            self.level = level
            self.pluggedIn = pluggedIn
            self.isCharging = isCharging
            self.isFullyCharged = isFullyCharged
            self.isLowPowerMode = isLowPowerMode
            self.minutesRemaining = minutesRemaining
            self.healthPercent = healthPercent
            self.cycleCount = cycleCount
        }
    }

    private var callback: ((Charge) -> Void)?
    private var timer: Timer?
    private var powerObserver: NSObjectProtocol?
    private var lastEmittedCharge: Charge?
    /// Latest reading, even if unchanged since the last callback.
    private(set) var current: Charge?

    deinit { stop() }

    func start(callback: @escaping (Charge) -> Void) {
        self.callback = callback
        lastEmittedCharge = nil
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
        callback = nil
        if let obs = powerObserver {
            NotificationCenter.default.removeObserver(obs)
            powerObserver = nil
        }
    }

    func refresh(forcePublish: Bool = false) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        // The estimate is global, not per-source. A source-specific value is
        // preferred below because it also tells us whether the estimate is
        // until empty or until full.
        let estimate = IOPSGetTimeRemainingEstimate()
        let fallbackMinutes: Int? = estimate > 0 ? Int((estimate / 60.0).rounded()) : nil
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        for psRef in list {
            guard let dict = IOPSGetPowerSourceDescription(blob, psRef)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard
                let current = intValue(in: dict, key: kIOPSCurrentCapacityKey),
                let maxCapacity = intValue(in: dict, key: kIOPSMaxCapacityKey),
                maxCapacity > 0
            else { continue }

            let level = Swift.min(1, Swift.max(0, Double(current) / Double(maxCapacity)))
            let pluggedIn = (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let isFullyCharged = boolValue(in: dict, key: kIOPSIsChargedKey)
                ?? (current >= maxCapacity)
            let isCharging = boolValue(in: dict, key: kIOPSIsChargingKey)
                ?? (pluggedIn && !isFullyCharged)

            let timeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let sourceMinutes = intValue(in: dict, key: timeKey)
            let minutes: Int?
            if isFullyCharged {
                minutes = nil
            } else {
                minutes = positiveMinutes(sourceMinutes) ?? fallbackMinutes
            }

            let designCapacity = intValue(in: dict, key: kIOPSDesignCapacityKey)
            let healthPercent = Self.healthPercent(
                maxCapacity: maxCapacity,
                designCapacity: designCapacity
            )
            let cycleCount = intValue(in: dict, key: "Cycle Count")
                ?? intValue(in: dict, key: "CycleCount")

            let charge = Charge(
                level: level,
                pluggedIn: pluggedIn,
                minutesRemaining: minutes,
                isCharging: isCharging,
                isFullyCharged: isFullyCharged,
                isLowPowerMode: lowPowerMode,
                healthPercent: healthPercent,
                cycleCount: cycleCount
            )
            self.current = charge

            if forcePublish || shouldPublish(charge) {
                lastEmittedCharge = charge
                callback?(charge)
            }
            break // first valid battery is the system battery; ignore UPS extras
        }
    }

    private func shouldPublish(_ charge: Charge) -> Bool {
        guard let previous = lastEmittedCharge else { return true }
        return abs(charge.level - previous.level) > 0.005
            || charge.pluggedIn != previous.pluggedIn
            || charge.isCharging != previous.isCharging
            || charge.isFullyCharged != previous.isFullyCharged
            || charge.isLowPowerMode != previous.isLowPowerMode
            || charge.minutesRemaining != previous.minutesRemaining
            || charge.healthPercent != previous.healthPercent
            || charge.cycleCount != previous.cycleCount
    }

    private func intValue(in dict: [String: Any], key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }

    private func boolValue(in dict: [String: Any], key: String) -> Bool? {
        if let value = dict[key] as? Bool { return value }
        if let value = dict[key] as? NSNumber { return value.boolValue }
        return nil
    }

    private func positiveMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func healthPercent(maxCapacity: Int, designCapacity: Int?) -> Int? {
        guard let designCapacity, designCapacity > 0, maxCapacity >= 0 else { return nil }
        let percentage = (Double(maxCapacity) / Double(designCapacity) * 100).rounded()
        return min(100, max(0, Int(percentage)))
    }

    static func timeRemainingText(
        minutes: Int?,
        isCharging: Bool,
        isFullyCharged: Bool = false
    ) -> String? {
        guard !isFullyCharged, let minutes, minutes > 0 else { return nil }
        let duration: String
        if minutes >= 60 {
            duration = String(format: "~%dh %02dm", minutes / 60, minutes % 60)
        } else {
            duration = "~\(minutes)m"
        }
        return isCharging ? "\(duration) until full" : "\(duration) remaining"
    }

    static func etaText(minutes: Int?) -> String? {
        timeRemainingText(minutes: minutes, isCharging: true)
    }
}
