import Foundation

/// Inertial scrolling after the fingers leave the surface.
///
/// macOS generates this in the HID layer for real trackpads, below where injected events
/// enter, so we have to produce it ourselves. Without it a scroll stops dead at lift-off,
/// which is the single most obvious tell that something is not a real trackpad.
///
/// Pure arithmetic over an explicit clock: no timers, no display link. The caller ticks
/// it, which is what makes the deceleration curve testable.
public struct MomentumEngine: Sendable {
    /// Fraction of velocity retained per second of coasting. Roughly matches the feel of
    /// AppKit's own deceleration.
    public var decayPerSecond: Double = 0.04
    /// Below this speed the scroll has visually stopped; keeping it alive only produces
    /// sub-pixel events that never render.
    public var stopSpeedMMPerS: Double = 8

    private var velocityX: Double = 0
    private var velocityY: Double = 0

    public init() {}

    public var isActive: Bool {
        (velocityX * velocityX + velocityY * velocityY).squareRoot() > stopSpeedMMPerS
    }

    public mutating func start(velocityX: Double, velocityY: Double) {
        self.velocityX = velocityX
        self.velocityY = velocityY
    }

    public mutating func stop() {
        velocityX = 0
        velocityY = 0
    }

    /// Advance by `dt` seconds.
    ///
    /// - Returns: millimetres to scroll during this tick, or nil once the coast is over.
    public mutating func tick(dt: Double) -> (dxMM: Double, dyMM: Double)? {
        guard isActive, dt > 0 else {
            stop()
            return nil
        }
        // Exponential decay integrated over the tick, so the curve does not depend on how
        // often the caller happens to tick.
        let retained = pow(decayPerSecond, dt)
        let dx = velocityX * (retained - 1) / log(decayPerSecond)
        let dy = velocityY * (retained - 1) / log(decayPerSecond)
        velocityX *= retained
        velocityY *= retained
        return (dx, dy)
    }
}
