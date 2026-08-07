import Foundation

/// Every threshold that decides what a gesture *is*.
///
/// Collected in one struct on purpose: these are the numbers that get tuned by feel, and
/// having them scattered through the state machine would make tuning a search problem.
/// Distances are millimetres of finger travel, times are seconds.
public struct GestureConfig: Sendable, Equatable {
    // MARK: Taps

    /// How far a finger may drift and still count as a tap rather than a move.
    public var tapSlopMM: Double = 2.0
    /// Longest a finger may stay down and still register as a tap.
    public var tapMaxDuration: Double = 0.25
    /// Window for a second tap to become a double click.
    public var doubleClickWindow: Double = 0.4
    /// How far apart two taps may land and still be the same double click.
    public var doubleClickSlopMM: Double = 5.0
    /// After a tap, a finger landing within this window and moving starts a drag —
    /// the "tap and a half" that macOS calls dragging with tap.
    public var dragArmWindow: Double = 0.25

    // MARK: Scroll

    /// Centroid travel before two fingers commit to scrolling.
    public var scrollSlopMM: Double = 1.0
    /// Cursor points emitted per millimetre of finger travel.
    public var scrollGain: Double = 16.0
    /// Below this exit speed, lifting off just stops instead of coasting.
    public var momentumMinSpeedMMPerS: Double = 40
    /// How far back to look when deciding whether the fingers were still moving at
    /// lift-off. Long enough to survive one noisy frame, short enough that only the end
    /// of the gesture counts.
    public var flickWindow: Double = 0.06
    /// No movement for this long means the fingers had already stopped, whatever they
    /// were doing before.
    public var flickRestTimeout: Double = 0.05
    /// Movement inside the window below this is drift, not a throw.
    public var flickMinimumTravelMM: Double = 1.0

    // MARK: Pinch

    /// Change in finger separation before two fingers commit to pinching instead of scrolling.
    public var pinchSlopMM: Double = 4.0
    /// Further separation change per additional zoom step.
    public var pinchStepMM: Double = 8.0

    // MARK: Three fingers

    /// Centroid travel before a three-finger swipe fires.
    public var swipeThresholdMM: Double = 12.0

    public init() {}
}

/// Velocity-dependent pointer gain.
///
/// Injected pointer motion bypasses the HID driver's own acceleration, so without this a
/// trackpad is either too slow to cross the screen or too twitchy to hit a button. Slow
/// movement gets low gain for precision; fast movement gets high gain for reach.
public struct AccelerationCurve: Sendable, Equatable {
    /// Cursor points per millimetre at a standstill.
    public var base: Double = 2.0
    /// Additional points per millimetre for each mm/s of speed.
    public var perSpeed: Double = 0.03
    public var minimum: Double = 1.5
    public var maximum: Double = 12.0
    /// The single knob worth putting in front of a user.
    public var sensitivity: Double = 1.0

    public init() {}

    /// - Parameter speedMMPerS: finger speed in millimetres per second.
    /// - Returns: cursor points per millimetre of finger travel.
    public func gain(speedMMPerS: Double) -> Double {
        let raw = base + perSpeed * max(0, speedMMPerS)
        return min(max(raw, minimum), maximum) * sensitivity
    }
}
