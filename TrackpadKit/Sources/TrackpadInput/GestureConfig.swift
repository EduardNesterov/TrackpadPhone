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
    ///
    /// The surface is the thing that sets this. Two fingers on a phone have perhaps 40 mm of
    /// spread in them before the hand has to be repositioned, so at eight millimetres a
    /// notch a whole pinch bought five — and a zoom that needs three pinches to cross its
    /// range reads as the gesture not working rather than as a slow setting. Smaller steps
    /// are both faster and smoother, because the notch is what makes zoom visibly stepped.
    /// The menu has a slider over it.
    public var pinchStepMM: Double = 4.5
    /// Below this closing or opening speed at lift-off, a pinch just stops.
    ///
    /// The same distinction the scroll flick makes: fingers that had already come to rest
    /// were placing the zoom exactly where it is, and coasting past it would be the surface
    /// disagreeing with the hand. Lower than the scroll's, and deliberately: a pinch has
    /// forty millimetres of hand in it rather than a whole arm, so most real ones are slower
    /// than a scroll flick and the scroll's bar would refuse nearly every one.
    public var zoomMomentumMinSpeedMMPerS: Double = 25
    /// Where the coast finally comes to rest — a different question from whether to start
    /// one, and a separate number for exactly that reason.
    ///
    /// These were one number, which meant the coast ended the instant it began: a pinch that
    /// had just cleared the bar to start was already under the bar to stop. Only a throw
    /// several times over the threshold coasted visibly at all, and that is precisely what
    /// "inertia does not work on small pinches" looked like from the hand.
    public var zoomMomentumStopSpeedMMPerS: Double = 6
    /// Fraction of the pinch speed left after a second of coasting. A little shorter than
    /// the scroll's, because overshooting a zoom is harder to correct than overshooting a
    /// page — but only a little: what looked like a taste for very short coasts was the stop
    /// speed above cutting every one of them off.
    public var zoomMomentumDecayPerSecond: Double = 0.05

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
    /// How much of each border the drag keeps travelling in, as a fraction of the surface
    /// along that axis. Zero turns it off.
    ///
    /// Selecting text down a long page runs out of surface long before it runs out of page,
    /// and carrying a window across a desktop runs out of it sideways sooner still. The
    /// pointer is *pushed* rather than the view scrolled, because a synthesised scroll would
    /// not arrive: while an AppKit application is tracking a mouse drag it runs its own event
    /// loop taking only dragged and up events, so wheel events sit in the queue until the
    /// drag is over. Every one of those applications already scrolls itself when the pointer
    /// reaches the edge of its view — and it extends the selection correctly while doing so,
    /// which nothing outside the application could do as well.
    ///
    /// A fraction rather than millimetres, and that is the whole correction here. The zone
    /// is one thing measured two ways: how much of the hand's remaining travel to hand over
    /// to the push. Three fingers occupy one band of the surface, so what is left to travel
    /// is what is left of the surface — the same share of a phone held sideways (140 × 65 mm
    /// measured) as of one held upright, where the axes swap. A fixed ten millimetres was
    /// tuned against the upright figure and left a *sixth* of that zone sideways, which is
    /// why the sideways push read as not working at all.
    public var dragEdgePushMarginFraction: Double = 0.15
    /// Travel per second at the very border, tapering to nothing at the edge of the zone,
    /// so the push arrives gradually instead of snatching the pointer. Zero turns it off,
    /// and the menu has a slider for it — how fast a page should run past is taste, and
    /// depends on the page.
    public var dragEdgePushMaxMMPerS: Double = 30
    /// How long a hand has to keep pressing into the border before the push reaches its top
    /// speed, and how many times the starting rate that is.
    ///
    /// Nudging an icon into place and carrying a window across a desktop are the same
    /// gesture with different amounts of patience behind them, and one speed cannot serve
    /// both: enough to cross a 2560-point screen would shove the icon past its target, and
    /// gentle enough to place it takes half a minute to cross. Ramping asks nothing of the
    /// user and answers both — the first moments are gentle, and a hand that stays gets
    /// carried. macOS's own edge autoscroll does the same thing.
    public var dragEdgePushRampSeconds: Double = 1.2
    public var dragEdgePushRampMax: Double = 5
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
    /// The same window when the hand ran out of surface instead of finishing.
    ///
    /// Wanting a prompt release and wanting time to re-grab are two different wishes, and
    /// one number cannot serve both. They are told apart by physics rather than by timing:
    /// a hand that ran out of room is *pressed against the border it was heading for*, and
    /// a hand that is done is not. Getting the guess wrong is cheap in both directions —
    /// either the object hangs on for a moment, or it drops and gets picked up again.
    public var dragEdgeResumeWindow: Double = 5.0
    /// Fingers back on the surface that have not made three within this long are not a
    /// re-grab, and the drag lets go.
    ///
    /// This is what makes a five-second window affordable. While the button is held the
    /// recogniser swallows everything — the surface is committed to a drag that may already
    /// be over — and five seconds of a dead trackpad is not a price worth paying for a
    /// window nobody uses every time. A real re-grab lands its three fingers inside about a
    /// tenth of a second, so anything slower is a hand that means something else.
    public var dragRegrabTimeout: Double = 0.3
    /// How close to the border counts as being against it.
    public var dragEdgeMarginMM: Double = 8
    /// Below this speed at lift-off the hand had already stopped, so it was finishing —
    /// even at the very border.
    public var dragRunOutSpeedMMPerS: Double = 25
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
