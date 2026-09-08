import Foundation
import QuartzCore

/// Critically-damped spring using Apple's "response + damping" parameterization.
/// Driven by CADisplayLink for frame-perfect, interruptible animation that
/// can be redirected at any moment and carries velocity through re-targets.
final class SpringAnimation {
    /// Apple's two-knob model.
    /// - `response`: time-to-target in seconds (lower = snappier).
    /// - `dampingRatio`: 1.0 = critically damped, < 1.0 = overshoots.
    let response: Double
    let dampingRatio: Double
    /// Precomputed natural frequency (1/response). Cached to avoid a
    /// sqrt/divide on every 120Hz tick.
    private let omega0: Double

    /// Live values.
    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    private var target: Double = 0
    private var startValue: Double = 0
    private var startTime: CFTimeInterval = 0
    private var onChange: ((Double) -> Void)?
    private var onRest: (() -> Void)?

    private(set) var isRunning: Bool = false

    init(response: Double = 0.4, dampingRatio: Double = 1.0,
         initialValue: Double = 0) {
        self.response = max(0.01, response)
        self.dampingRatio = dampingRatio
        self.omega0 = 1.0 / self.response
        self.value = initialValue
        self.target = initialValue
        self.startValue = initialValue
    }

    deinit { stop() }

    func set(value newValue: Double) {
        self.value = newValue
        self.startValue = newValue
        // Snap the target too, otherwise the next tick would pull back
        // toward a stale in-flight target.
        self.target = newValue
        self.velocity = 0
    }

    /// Animate to `newTarget`, starting from the live value with the live velocity.
    /// Replaces any in-flight animation; the spring continues from where it is.
    func animate(to newTarget: Double,
                 onChange: @escaping (Double) -> Void,
                 onRest: @escaping () -> Void = {}) {
        self.target = newTarget
        self.startValue = value
        self.startTime = CACurrentMediaTime()
        self.onChange = onChange
        self.onRest = onRest
        if !isRunning {
            isRunning = true
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        // CADisplayLink's target/selector init isn't available on macOS. Use a
        // high-frequency Timer on the main run loop instead — at 1/120s we get
        // 120Hz frame timing, and the main run loop pumps it during normal events.
        // Caller guarantees !isRunning, so no duplicate timer.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.fallbackTimer = timer
    }

    private var fallbackTimer: Timer?

    /// Update the target mid-flight. Velocity is preserved.
    func retarget(_ newTarget: Double) {
        target = newTarget
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        isRunning = false
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - startTime

        // Branch first: the hot path is critically-damped (dampingRatio == 1),
        // which needs only exp. Avoid sqrt/cos/sin unless under/over-damped.
        let zeta = dampingRatio
        let newValue: Double
        let newVelocity: Double
        if abs(zeta - 1.0) < 0.0001 {
            // Critically damped.
            let e = exp(-omega0 * elapsed)
            let a0 = startValue - target
            newValue = target + (a0 + (velocity + omega0 * a0) * elapsed) * e
            newVelocity = (velocity * (1 - omega0 * elapsed) - omega0 * omega0 * elapsed * a0) * e
        } else if zeta < 1.0 {
            // Under-damped second-order spring, mass normalized to 1.
            let damped = omega0 * sqrt(max(0.0001, 1 - zeta * zeta))
            let decay = exp(-zeta * omega0 * elapsed)
            let cosPart = cos(damped * elapsed)
            let sinPart = sin(damped * elapsed)
            let denom = sqrt(max(0.0001, 1 - zeta * zeta))
            let a0 = startValue - target
            let a1 = (velocity + zeta * omega0 * a0) / (omega0 * denom)
            newValue = target + decay * (a0 * cosPart + a1 * sinPart)
            newVelocity = decay * (
                (a1 * omega0 * denom * cosPart) -
                (a0 * damped * sinPart) -
                (zeta * omega0 * (a0 * cosPart + a1 * sinPart))
            )
        } else {
            // Over-damped: roots use sqrt(zeta^2 - 1), not sqrt(1 - zeta^2).
            let denom = sqrt(max(0.0001, zeta * zeta - 1))
            let r1 = -omega0 * (zeta - denom)
            let r2 = -omega0 * (zeta + denom)
            let a0 = startValue - target
            let a = (velocity - r2 * a0) / (r1 - r2)
            let b = a0 - a
            newValue = target + a * exp(r1 * elapsed) + b * exp(r2 * elapsed)
            newVelocity = a * r1 * exp(r1 * elapsed) + b * r2 * exp(r2 * elapsed)
        }

        self.value = newValue
        self.velocity = newVelocity
        onChange?(newValue)

        // Settled when value is within ~0.05 of target and velocity is near zero.
        let isAtRest = abs(newValue - target) < 0.05 && abs(newVelocity) < 0.5
        if isAtRest {
            self.value = target
            self.velocity = 0
            onChange?(target)
            stop()
            onRest?()
        }
    }
}

/// Two-axes spring helper for X/Y transforms.
final class Spring2D {
    let x: SpringAnimation
    let y: SpringAnimation
    var onChange: ((Double, Double) -> Void)?
    var onRest: (() -> Void)?

    private var restPending = false

    init(response: Double = 0.4, dampingRatio: Double = 1.0) {
        x = SpringAnimation(response: response, dampingRatio: dampingRatio)
        y = SpringAnimation(response: response, dampingRatio: dampingRatio)
    }

    func animate(toX tx: Double, toY ty: Double) {
        restPending = true
        x.animate(to: tx, onChange: { [weak self] _ in self?.emit() },
                  onRest: { [weak self] in self?.maybeRest() })
        y.animate(to: ty, onChange: { [weak self] _ in self?.emit() },
                  onRest: { [weak self] in self?.maybeRest() })
    }

    func retarget(toX tx: Double, toY ty: Double) {
        x.retarget(tx)
        y.retarget(ty)
    }

    func stop() { x.stop(); y.stop(); restPending = false }

    private func emit() { onChange?(x.value, y.value) }
    private func maybeRest() {
        if restPending, !x.isRunning, !y.isRunning {
            restPending = false
            onRest?()
        }
    }
}

/// Apple's exponential momentum projection. `decelerationRate ≈ 0.998`.
func projectMomentum(velocity: Double, decelerationRate: Double = 0.998) -> Double {
    return (velocity / 1000.0) * decelerationRate / (1.0 - decelerationRate)
}

/// Rubber-band resistance at edges. `overshoot` is the distance past the bound.
func rubberBand(overshoot: Double, dimension: Double, constant: Double = 0.55) -> Double {
    let abs = Swift.abs(overshoot)
    let sign = overshoot >= 0 ? 1.0 : -1.0
    return sign * (abs * dimension * constant) / (dimension + constant * abs)
}