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
    /// How long the speed the curve is read at takes to fall towards a slower estimate.
    ///
    /// Only falls are damped — a flick reaches its gain on the first frame. This is what
    /// keeps a momentary dip, from a finger hesitating or a frame arriving late over
    /// Wi-Fi, out of the movement. Zero turns the smoothing off.
    public var speedFallTime: Double = 0.09

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

    /// Three fingers hold the button down and drag, the way macOS's own three-finger drag
    /// does.
    ///
    /// It costs the three-finger swipes, which move to four — the same trade macOS makes
    /// when the setting is turned on, and for the same reason: a drag and a swipe both
    /// begin as three fingers moving, so no threshold separates them without making one of
    /// them fire by accident.
    public var threeFingerDrag = true
    /// Centroid travel before three fingers commit to dragging. Smaller than the tap slop
    /// because three fingers rest steadier than one, and a drag that hesitates before it
    /// picks anything up feels like the surface is stuck.
    public var dragSlopMM: Double = 1.5
    /// Slow dragging is read at no less than this speed.
    ///
    /// The acceleration curve damps to 0.4× down at the bottom, which is what makes a pixel
    /// reachable when *pointing*. Carrying something is the opposite job: the same damping
    /// turns a deliberate drag into hauling it through tar, and the surface is too small to
    /// make the distance up. Flooring the speed rather than adding a second curve means fast
    /// dragging still accelerates exactly like the pointer — it only removes the precision
    /// zone, which a drag has no use for. 35 mm/s is where the curve reaches unity.
    public var dragSpeedFloorMMPerS: Double = 35
    /// How long the button stays down after the fingers leave, waiting for them to return.
    ///
    /// Not a nicety: the surface is 65 mm wide and a window crossing a desktop needs more
    /// travel than that, so lifting and re-grabbing has to continue the same drag instead
    /// of dropping what it is carrying. Long enough to lift and replace a hand, short
    /// enough that a deliberate release does not feel sticky.
    public var dragResumeWindow: Double = 0.175
    /// Centroid travel before a swipe fires.
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
