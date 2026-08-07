import Foundation
import Testing
import TrackpadProtocol

@testable import TrackpadInput

@Suite("Pointer")
struct PointerTests {
    @Test("A one-finger swipe moves the pointer by the distance travelled")
    func swipeMovesPointer() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 75)
        stream.hold(0.02)
        stream.move(0, dxMM: 30, dyMM: -10, over: 0.25)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        let total = events.totalMoveMM

        // The tap slop is a dead zone, so a couple of millimetres are deliberately
        // swallowed before the pointer commits to moving.
        #expect(total.x > 26 && total.x <= 30)
        #expect(total.y < -8 && total.y >= -10)
        #expect(events.clicks.isEmpty, "a long drag is not a click")
    }

    @Test("Movement below the tap slop is swallowed, so a tap does not nudge the cursor")
    func tinyMovementIsIgnored() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.move(0, dxMM: 1.0, dyMM: 0.5, over: 0.05)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).moves.isEmpty)
    }
}

@Suite("Clicks")
struct ClickTests {
    @Test("A brief still touch is a click")
    func tapClicks() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.hold(0.05)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks == [.click(.left, count: 1)])
    }

    @Test("Holding too long is not a click")
    func longPressDoesNotClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.hold(0.5)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks.isEmpty)
    }

    @Test("Moving too far is not a click")
    func movedTouchDoesNotClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 75)
        stream.move(0, dxMM: 10, dyMM: 0, over: 0.1)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks.isEmpty)
    }

    /// macOS needs the click count on the event itself; a second click without it is
    /// simply two single clicks and never opens anything.
    @Test("Two taps in quick succession count as a double click")
    func doubleClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.hold(0.04)
        stream.liftAll()
        stream.place(1, xMM: 35.5, yMM: 75.5)
        stream.hold(0.04)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks == [
            .click(.left, count: 1),
            .click(.left, count: 2),
        ])
    }

    @Test("Taps far apart stay two single clicks")
    func tapsFarApartAreNotADoubleClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 15, yMM: 75)
        stream.hold(0.04)
        stream.liftAll()
        stream.place(1, xMM: 55, yMM: 75)
        stream.hold(0.04)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks == [
            .click(.left, count: 1),
            .click(.left, count: 1),
        ])
    }

    @Test("Two fingers tapped together are a right click")
    func twoFingerTapIsRightClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 75)
        stream.place(1, xMM: 42, yMM: 75)
        stream.hold(0.05)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        #expect(events.clicks == [.click(.right, count: 1)])
        #expect(events.scrolls.isEmpty)
    }

    @Test("Tap, then touch and move, is a drag")
    func tapAndAHalfDrags() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.hold(0.04)
        stream.liftAll()
        stream.place(1, xMM: 35, yMM: 75)
        stream.move(1, dxMM: 15, dyMM: 0, over: 0.15)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        #expect(events.contains(.dragBegan))
        #expect(events.contains(.dragEnded))
        #expect(events.totalMoveMM.x > 12)
    }
}

@Suite("Scroll")
struct ScrollTests {
    @Test("Two fingers sliding together scroll, with began and ended phases")
    func twoFingerScroll() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 60)
        stream.place(1, xMM: 42, yMM: 60)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 25, over: 0.2)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        let scrolls = events.scrolls

        guard case .scroll(_, _, .began) = scrolls.first else {
            Issue.record("scroll must open with .began — without it AppKit treats the whole run as a mouse wheel")
            return
        }
        guard case .scroll(_, _, .ended) = scrolls.last else {
            Issue.record("scroll must close with .ended, or the document never rubber-bands back")
            return
        }
        #expect(events.totalScrollMM.y > 20)
        #expect(events.moves.isEmpty, "two fingers must never move the pointer")
    }

    /// Fingers never land in the same frame in real use — one arrives tens of
    /// milliseconds before the other. Every other scroll test puts both down at once,
    /// which skips the one-finger prologue entirely.
    @Test("Two fingers landing a moment apart still scroll")
    func staggeredLandingScrolls() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 60)
        stream.hold(0.04)
        stream.place(1, xMM: 42, yMM: 60)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 25, over: 0.2)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        #expect(!events.scrolls.isEmpty, "the second finger must switch the gesture to scrolling")
        #expect(events.moves.isEmpty, "and the pointer must not have moved")
    }

    /// The same prologue, but the first finger drifts enough to commit to pointing before
    /// the second one lands — which is what happens when you are already moving the cursor
    /// and decide to scroll.
    @Test("Adding a second finger while the pointer is moving switches to scroll")
    func secondFingerInterruptsPointing() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 60)
        stream.move(0, dxMM: 10, dyMM: 0, over: 0.1)
        stream.place(1, xMM: 42, yMM: 60)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 25, over: 0.2)
        stream.liftAll()

        #expect(!GestureRecognizer().run(stream).scrolls.isEmpty)
    }

    @Test("Three fingers landing one by one still swipe")
    func staggeredThreeFingerSwipe() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.hold(0.03)
        stream.place(1, xMM: 35, yMM: 100)
        stream.hold(0.03)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).shortcuts == [.shortcut(.missionControl)])
    }

    @Test("Two fingers tapped a moment apart are still a right click")
    func staggeredTwoFingerTap() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 75)
        stream.hold(0.03)
        stream.place(1, xMM: 42, yMM: 75)
        stream.hold(0.04)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).clicks == [.click(.right, count: 1)])
    }

    @Test("Lifting off fast hands the momentum engine a velocity")
    func scrollCarriesExitVelocity() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 100)
        stream.place(1, xMM: 42, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -60, over: 0.15)
        stream.liftAll()

        guard case .scroll(_, _, .ended(_, let velocityY)) = GestureRecognizer().run(stream).scrolls.last else {
            Issue.record("expected a terminating scroll event")
            return
        }
        #expect(velocityY < -100, "a 60 mm flick in 150 ms is roughly -400 mm/s")
    }

    @Test("A slow release does not coast")
    func slowReleaseHasNoMomentum() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 60)
        stream.place(1, xMM: 42, yMM: 60)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 10, over: 1.5)
        stream.liftAll()

        guard case .scroll(_, _, .ended(let vx, let vy)) = GestureRecognizer().run(stream).scrolls.last else {
            Issue.record("expected a terminating scroll event")
            return
        }
        #expect(vx == 0 && vy == 0)
    }

    /// The regression that makes a trackpad feel broken: fingers rarely leave together,
    /// and handing the survivor to the pointer teleports the cursor at the end of every
    /// scroll.
    @Test("Lifting one finger out of two never moves the pointer")
    func partialLiftDoesNotJumpTheCursor() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 60)
        stream.place(1, xMM: 42, yMM: 60)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 20, over: 0.15)
        stream.lift(1)
        stream.move(0, dxMM: 8, dyMM: 8, over: 0.08)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        #expect(events.moves.isEmpty)
        #expect(events.clicks.isEmpty)
    }
}

@Suite("Pinch and swipe")
struct GestureTests {
    @Test("Spreading two fingers zooms in")
    func pinchOutZoomsIn() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 75)
        stream.place(1, xMM: 40, yMM: 75)
        stream.hold(0.02)
        stream.pinch(byMM: 30, over: 0.3)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        let steps = events.zooms.reduce(0) { total, event in
            if case .zoom(let step) = event { total + step } else { total }
        }
        #expect(steps > 0, "fingers moving apart must zoom in")
        #expect(events.scrolls.isEmpty, "a pure pinch must not also scroll")
    }

    /// The realistic pinch: thumb still, finger moves. The centroid drifts by half the
    /// spread, so the scroll threshold is crossed long before the pinch threshold — the
    /// symmetric test above never exercises this because its centroid does not move at all.
    @Test("A pinch with one finger anchored zooms, and does not scroll")
    func pinchWithAnchoredFingerZooms() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 40, yMM: 75)
        stream.place(1, xMM: 60, yMM: 75)
        stream.hold(0.02)
        stream.pinchOneAnchored(byMM: 30, over: 0.3)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        let steps = events.zooms.reduce(0) { total, event in
            if case .zoom(let step) = event { total + step } else { total }
        }
        #expect(steps > 0, "spreading the fingers must zoom in")
        #expect(events.scrolls.isEmpty, "and must not be mistaken for a scroll")
    }

    @Test("Bringing two fingers together zooms out")
    func pinchInZoomsOut() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 75)
        stream.place(1, xMM: 50, yMM: 75)
        stream.hold(0.02)
        stream.pinch(byMM: -24, over: 0.3)
        stream.liftAll()

        let steps = GestureRecognizer().run(stream).zooms.reduce(0) { total, event in
            if case .zoom(let step) = event { total + step } else { total }
        }
        #expect(steps < 0)
    }

    @Test("Three fingers up open Mission Control")
    func threeFingerSwipeUp() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).shortcuts == [.shortcut(.missionControl)])
    }

    @Test("Three fingers sideways switch spaces, once per swipe")
    func threeFingerSwipeSideways() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 45, yMM: 75)
        stream.place(1, xMM: 55, yMM: 75)
        stream.place(2, xMM: 65, yMM: 75)
        stream.hold(0.02)
        stream.moveAll(dxMM: -35, dyMM: 0, over: 0.25)
        stream.liftAll()

        // A long swipe must not fire repeatedly as it keeps travelling.
        #expect(GestureRecognizer().run(stream).shortcuts == [.shortcut(.spaceLeft)])
    }

    @Test("A short three-finger movement fires nothing")
    func threeFingerJitterIsIgnored() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 75)
        stream.place(1, xMM: 35, yMM: 75)
        stream.place(2, xMM: 50, yMM: 75)
        stream.hold(0.02)
        stream.moveAll(dxMM: 4, dyMM: 2, over: 0.1)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).shortcuts.isEmpty)
    }
}

@Suite("Momentum")
struct MomentumTests {
    @Test("Coasting decays and eventually stops")
    func decays() {
        var engine = MomentumEngine()
        engine.start(velocityX: 0, velocityY: -400)
        #expect(engine.isActive)

        var total = 0.0
        var ticks = 0
        while let step = engine.tick(dt: 1.0 / 120), ticks < 2000 {
            total += step.dyMM
            ticks += 1
        }

        #expect(!engine.isActive)
        #expect(total < -50, "a 400 mm/s flick should coast a meaningful distance")
        #expect(ticks < 600, "and settle within a few seconds rather than drifting forever")
    }

    /// The caller's tick rate is a scheduling detail; the coast must not travel further
    /// just because the display runs at 120 Hz instead of 60.
    @Test("Total distance does not depend on tick rate")
    func tickRateIndependent() {
        func distance(hz: Double) -> Double {
            var engine = MomentumEngine()
            engine.start(velocityX: 0, velocityY: -400)
            var total = 0.0
            while let step = engine.tick(dt: 1 / hz) { total += step.dyMM }
            return total
        }

        let slow = distance(hz: 60)
        let fast = distance(hz: 120)
        #expect(abs(slow - fast) / abs(slow) < 0.1)
    }

    @Test("A new touch cancels the coast")
    func stopHalts() {
        var engine = MomentumEngine()
        engine.start(velocityX: 100, velocityY: 100)
        engine.stop()
        #expect(!engine.isActive)
        #expect(engine.tick(dt: 0.008) == nil)
    }
}

@Suite("Acceleration")
struct AccelerationTests {
    @Test("Slow is precise, fast is far, and the top is clamped")
    func curveIsMonotonic() {
        let curve = AccelerationCurve()
        #expect(curve.gain(speedMMPerS: 0) == curve.base)
        #expect(curve.gain(speedMMPerS: 100) > curve.gain(speedMMPerS: 10))
        #expect(curve.gain(speedMMPerS: 100_000) == curve.maximum)
    }

    /// The floor only bites once someone tunes `base` below it — with the defaults it is
    /// a guard rail, not an active limit.
    @Test("The floor catches a base tuned too low")
    func floorClamps() {
        var curve = AccelerationCurve()
        curve.base = 0.1
        #expect(curve.gain(speedMMPerS: 0) == curve.minimum)
    }

    @Test("Sensitivity scales the whole curve")
    func sensitivityScales() {
        var curve = AccelerationCurve()
        let normal = curve.gain(speedMMPerS: 50)
        curve.sensitivity = 2
        #expect(abs(curve.gain(speedMMPerS: 50) - normal * 2) < 1e-9)
    }
}
