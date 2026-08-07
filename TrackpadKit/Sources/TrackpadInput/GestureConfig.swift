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

    /// Trailing window for the pointer speed estimate. Shorter reacts faster but lets
    /// per-frame noise into the gain; longer is smoother but lags a change of pace.
    public var pointerVelocityWindow: Double = 0.06

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

/// Velocity-dependent pointer gain, as a piecewise-linear curve over knots.
///
/// A curve rather than a formula, because that is what everyone who has worked on this for
/// years converged on: Windows interpolates five inflection points, libinput describes
/// three zones. A single `base + k · speed` line cannot express the shape that matters —
/// in particular it cannot go *below* unity, and the sub-unity zone at low speed is
/// precisely what makes fine targeting possible. libinput decelerates to 0.3× down there.
///
/// Gain is unitless and multiplies `pointsPerMM`, so sensitivity and curve shape stay
/// independent: moving the slider does not change where acceleration kicks in.
public struct AccelerationCurve: Sendable, Equatable {
    public struct Knot: Sendable, Equatable {
        public var speedMMPerS: Double
        public var factor: Double

        public init(_ speedMMPerS: Double, _ factor: Double) {
            self.speedMMPerS = speedMMPerS
            self.factor = factor
        }
    }

    /// Cursor points per millimetre of finger travel at unity gain.
    public var pointsPerMM: Double = 6.0
    /// The one knob worth putting in front of a user.
    public var sensitivity: Double = 1.0

    /// Ascending by speed. Interpolated linearly between knots and clamped outside them —
    /// extrapolating past the last knot would let a fast flick reach unbounded gain.
    public var knots: [Knot] = [
        Knot(0, 0.40),     // barely moving: heavily damped, so a pixel is reachable
        Knot(12, 0.75),
        Knot(35, 1.00),    // unity — a millimetre of finger is pointsPerMM of screen
        Knot(90, 1.75),
        Knot(200, 3.00),
        Knot(400, 4.40),
        Knot(700, 5.20),   // capped: beyond this the screen is already crossed
    ]

    public init() {}

    /// - Returns: cursor points per millimetre of finger travel at this speed.
    public func pointsPerMillimetre(speedMMPerS: Double) -> Double {
        pointsPerMM * factor(speedMMPerS: speedMMPerS) * sensitivity
    }

    /// The unitless part of the curve.
    public func factor(speedMMPerS: Double) -> Double {
        guard let first = knots.first, let last = knots.last else { return 1 }
        if speedMMPerS <= first.speedMMPerS { return first.factor }
        if speedMMPerS >= last.speedMMPerS { return last.factor }

        for (low, high) in zip(knots, knots.dropFirst()) where speedMMPerS <= high.speedMMPerS {
            let span = high.speedMMPerS - low.speedMMPerS
            guard span > 0 else { return low.factor }
            let position = (speedMMPerS - low.speedMMPerS) / span
            return low.factor + (high.factor - low.factor) * position
        }
        return last.factor
    }
}
