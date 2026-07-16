import Foundation
import QuartzCore

/// Old-TV vertical hold: DSNK rolls with mass/momentum, spring-attracted to upright.
/// Full rolls only fire on a strong kick after ~1 minute cooldown.
final class LogoRollPhysics {
    /// Unwrapped roll in logo-heights (display uses fract).
    private(set) var position: Float = 0
    private(set) var velocity: Float = 0

    private var nextImpulseAt: CFTimeInterval
    private var lastTime: CFTimeInterval?
    private var prevBeatPulse: Float = 0

    init() {
        // First roll eligible after roughly one cooldown window.
        nextImpulseAt = CACurrentMediaTime() + Double.random(
            in: Double(Config.logoRollMinGap) * 0.7...Double(Config.logoRollMaxGap)
        )
    }

    /// Advance simulation. Returns (wrapped offset 0…1, velocity in logo-heights/sec).
    @discardableResult
    func update(now: CFTimeInterval, beatPulse: Float) -> (offset: Float, velocity: Float) {
        let dt: Float
        if let last = lastTime {
            dt = Float(min(max(now - last, 1.0 / 240.0), 1.0 / 20.0))
        } else {
            dt = 1.0 / 60.0
        }
        lastTime = now

        let thresh = Config.logoRollKickThreshold
        let strongKickOnset = beatPulse > thresh && prevBeatPulse <= thresh
        if now >= nextImpulseAt, strongKickOnset {
            // Upward roll impulse (positive → content scrolls up / TV roll)
            velocity += Config.logoRollImpulse
            nextImpulseAt = now + Double.random(
                in: Double(Config.logoRollMinGap)...Double(Config.logoRollMaxGap)
            )
        }
        prevBeatPulse = beatPulse

        // Magnetic pull toward nearest upright pose (integer roll)
        let nearest = position.rounded()
        let error = position - nearest
        let mass = max(Config.logoRollMass, 0.05)
        let accel = (-Config.logoRollSpring * error - Config.logoRollDamping * velocity) / mass
        velocity += accel * dt
        position += velocity * dt

        // Settle numerically near an upright pose so we don't accumulate huge values
        let settled = position.rounded()
        if abs(velocity) < 0.02, abs(position - settled) < 0.002 {
            position = settled
            velocity = 0
        }

        var wrapped = position.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        return (wrapped, velocity)
    }
}
