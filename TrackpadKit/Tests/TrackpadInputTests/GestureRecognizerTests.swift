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

        // The whole travel is delivered. The tap slop delays the *decision* to move, but
        // the movement made while deciding is released on commit rather than discarded —
        // swallowing it is what makes a pointer feel like it sticks before it starts.
        #expect(abs(total.x - 30) < 0.5)
        #expect(abs(total.y + 10) < 0.5)
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

    /// Two fingers rarely leave the glass in the same frame — the same thing that was
    /// quietly killing scroll momentum until it was found.
    @Test("A two-finger tap works when the fingers lift one after the other")
    func raggedTwoFingerTapIsRightClick() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 75)
        stream.place(1, xMM: 42, yMM: 75)
        stream.hold(0.05)
        stream.lift(1)
        stream.lift(0)

        let events = GestureRecognizer().run(stream)
        #expect(events.clicks == [.click(.right, count: 1)])
        #expect(events.moves.isEmpty, "the finger left behind must not move the pointer")
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

    @Test("Fingers landing one by one still swipe")
    func staggeredSwipe() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 15, yMM: 100)
        stream.hold(0.03)
        stream.place(1, xMM: 30, yMM: 100)
        stream.hold(0.03)
        stream.place(2, xMM: 45, yMM: 100)
        stream.hold(0.03)
        stream.place(3, xMM: 60, yMM: 100)
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

    @Test("Four fingers up open Mission Control")
    func swipeUp() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 15, yMM: 100)
        stream.place(1, xMM: 30, yMM: 100)
        stream.place(2, xMM: 45, yMM: 100)
        stream.place(3, xMM: 60, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).shortcuts == [.shortcut(.missionControl)])
    }

    @Test("Four fingers sideways navigate back, once per swipe")
    func swipeSideways() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 35, yMM: 75)
        stream.place(1, xMM: 45, yMM: 75)
        stream.place(2, xMM: 55, yMM: 75)
        stream.place(3, xMM: 65, yMM: 75)
        stream.hold(0.02)
        stream.moveAll(dxMM: -35, dyMM: 0, over: 0.25)
        stream.liftAll()

        // A long swipe must not fire repeatedly as it keeps travelling.
        #expect(GestureRecognizer().run(stream).shortcuts == [.shortcut(.navigateBack)])
    }

    /// With the three-finger drag turned off the swipes go back where they were, and this
    /// is the only thing that proves the mapping actually moved rather than the recogniser
    /// having grown a second, permanent one.
    @Test("With the drag off, three fingers swipe again")
    func threeFingerSwipeWithoutDrag() {
        var config = GestureConfig()
        config.threeFingerDrag = false

        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()

        let events = GestureRecognizer(config: config).run(stream)
        #expect(events.shortcuts == [.shortcut(.missionControl)])
        #expect(!events.contains(.dragBegan), "nothing should be picked up when the drag is off")
    }

    /// Landing a fourth finger during a scroll is ordinary. If the scroll is not closed,
    /// the system keeps holding an unfinished gesture — no rubber-band release, no
    /// momentum, and it can swallow the very shortcut the fourth finger is asking for.
    @Test("A fourth finger during a scroll closes the scroll first")
    func fourthFingerClosesScroll() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -10, over: 0.1)
        stream.place(2, xMM: 50, yMM: 90)
        stream.place(3, xMM: 62, yMM: 90)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()

        let events = GestureRecognizer().run(stream)
        let endedBeforeShortcut = events.prefix { event in
            if case .shortcut = event { false } else { true }
        }
        #expect(endedBeforeShortcut.contains { event in
            if case .scroll(_, _, .ended) = event { true } else { false }
        }, "the scroll must be terminated before the shortcut is emitted")
        #expect(events.shortcuts == [.shortcut(.missionControl)])
    }

    @Test("A short four-finger movement fires nothing")
    func fourFingerJitterIsIgnored() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 15, yMM: 75)
        stream.place(1, xMM: 30, yMM: 75)
        stream.place(2, xMM: 45, yMM: 75)
        stream.place(3, xMM: 60, yMM: 75)
        stream.hold(0.02)
        stream.moveAll(dxMM: 4, dyMM: 2, over: 0.1)
        stream.liftAll()

        #expect(GestureRecognizer().run(stream).shortcuts.isEmpty)
    }
}

/// Three fingers hold the mouse button down and carry the pointer.
///
/// Most of what is worth testing here is about the surface being small: the drag has to
/// survive a hand lifting off and landing again, and it has to survive fingers arriving
/// and leaving one at a time, which is the only way they ever do.
@Suite("Three-finger drag")
struct ThreeFingerDragTests {
    /// Places three fingers and drags them, without lifting.
    private func dragStream(dxMM: Double, dyMM: Double) -> TouchStreamBuilder {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: dxMM, dyMM: dyMM, over: 0.2)
        return stream
    }

    @Test("Three fingers moving pick the pointer up and carry it")
    func threeFingersDrag() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)

        #expect(events.filter { $0 == .dragBegan }.count == 1)
        #expect(events.filter { $0 == .dragEnded }.count == 1)
        #expect(events.last == .dragEnded, "the button must come up after the travel, not during")
        // The whole travel arrives: the slop delays the decision, not the movement.
        #expect(abs(events.totalMoveMM.y + 30) < 0.5)
    }

    @Test("A three-finger tap picks nothing up")
    func threeFingerTapDoesNothing() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.05)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(!events.contains(.dragBegan))
        #expect(!events.contains(.dragEnded))
        #expect(events.clicks.isEmpty, "and it is not a click either")
    }

    /// The pitfall this project has now paid for three times: fingers never leave in the
    /// same frame. A drag that ended when the surface finally emptied would first spend
    /// two frames handing the leftovers to the pointer — dropping the file somewhere on
    /// the way to wherever it was going.
    @Test("Lifting one finger at a time does not drop what is being carried")
    func raggedLiftKeepsHold() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.lift(2)
        stream.lift(1)
        stream.lift(0)
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.filter { $0 == .dragEnded }.count == 1)

        // Nothing may move after the fingers start leaving: the centroid of what is left
        // is not where the hand is.
        let afterLift = Array(events.drop { $0 != .dragEnded })
        #expect(afterLift.moves.isEmpty)
    }

    /// The reason the drag outlives the fingers at all. The surface is 65 mm wide and a
    /// window crossing a desktop needs several times that.
    @Test("Fingers landing again inside the window continue the same drag")
    func reGrabContinuesTheDrag() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.liftAll()
        stream.hold(0.15)
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.filter { $0 == .dragBegan }.count == 1, "one press, not two")
        #expect(events.filter { $0 == .dragEnded }.count == 1)
        // Both halves of the travel land, and the surface jumping back to the start
        // between them does not.
        #expect(abs(events.totalMoveMM.y + 60) < 1.0)
    }

    /// The phone sends only while it is being touched. So the moment the last finger leaves
    /// — exactly when the re-grab window opens — the frames stop, and a deadline waiting on
    /// them never arrives. The drag stayed picked up and swallowed every touch after it
    /// until the receiver's stall watchdog let go, a second and a half later. Shortening the
    /// window did nothing, because this deadline was never reached at all.
    @Test("The drag ends on time even when the phone goes silent at lift-off")
    func dragEndsWithoutIdleFrames() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.liftAll()

        let recognizer = GestureRecognizer()
        var events = recognizer.run(stream)
        #expect(!events.contains(.dragEnded), "the window is still open at this point")

        // Nothing arrives from here on. Time still has to pass.
        for _ in 0 ..< 20 { events += recognizer.tick(elapsed: 0.02) }
        #expect(events.filter { $0 == .dragEnded }.count == 1)
    }

    /// A hand still coming off the surface does send frames, and those milliseconds must
    /// not be paid for twice — that would expire the window at up to double speed.
    @Test("Ticks do not double-count time the frames already covered")
    func tickDoesNotDoubleCountFrameTime() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.lift(2)
        stream.hold(0.1)

        let recognizer = GestureRecognizer()
        var events = recognizer.run(stream)
        // The frames above already carried 0.1 s, more than half the window. One tick
        // covering the same span must not finish it off.
        events += recognizer.tick(elapsed: 0.1)
        #expect(!events.contains(.dragEnded))
        events += recognizer.tick(elapsed: 0.1)
        #expect(events.contains(.dragEnded))
    }

    /// Running out of a 65-mm surface mid-drag is the normal case, not the exception, and
    /// the hand needs longer to get a grip again than a finished drag should hang on for.
    /// The two are told apart by the hand being pressed against the border it was heading
    /// for — pure physics, no timing heuristics.
    @Test("A hand that ran out of surface gets time to take a new grip")
    func runningOutOfSurfaceWaitsLonger() {
        var stream = TouchStreamBuilder()
        // Low on the surface already, and still pushing downwards when the fingers go.
        stream.place(0, xMM: 20, yMM: 120)
        stream.place(1, xMM: 35, yMM: 120)
        stream.place(2, xMM: 50, yMM: 120)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 28, over: 0.15)
        stream.lift(2)
        stream.lift(1)
        stream.lift(0)
        // Longer than the ordinary window, well inside the one for a re-grab.
        stream.hold(0.5)
        stream.place(0, xMM: 20, yMM: 40)
        stream.place(1, xMM: 35, yMM: 40)
        stream.place(2, xMM: 50, yMM: 40)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 25, over: 0.15)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.filter { $0 == .dragBegan }.count == 1, "the same drag, a new grip")
        #expect(events.filter { $0 == .dragEnded }.count == 1)
    }

    /// The long window is for running out of room, not for every lift. A drag that finishes
    /// must still drop promptly — that is what the short window is for, and it is what the
    /// hand having stopped shows.
    @Test("A drag that comes to a stop drops promptly, even at the border")
    func finishingAtTheBorderStillDropsPromptly() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 120)
        stream.place(1, xMM: 35, yMM: 120)
        stream.place(2, xMM: 50, yMM: 120)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: 28, over: 0.15)
        // Arrived, and held still for a moment before letting go.
        stream.hold(0.08)
        stream.lift(2)
        stream.lift(1)
        stream.lift(0)
        stream.hold(0.3)

        let events = GestureRecognizer().run(stream)
        #expect(events.contains(.dragEnded))
    }

    @Test("Landing again after the window is a new gesture, not the old drag")
    func lateReGrabDoesNotContinue() {
        var stream = dragStream(dxMM: 0, dyMM: -30)
        stream.liftAll()
        stream.hold(0.6)
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -20, over: 0.2)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.filter { $0 == .dragBegan }.count == 2)
        #expect(events.filter { $0 == .dragEnded }.count == 2)
    }

    /// A fourth finger joining moves the centroid by centimetres without the hand moving
    /// at all. Following it would fling whatever is being carried across the screen.
    @Test("A finger joining mid-drag does not jerk the pointer")
    func extraFingerDoesNotJerk() {
        var stream = dragStream(dxMM: 0, dyMM: -20)
        stream.place(3, xMM: 20, yMM: 30)
        stream.hold(0.05)
        stream.moveAll(dxMM: 0, dyMM: -10, over: 0.1)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.filter { $0 == .dragBegan }.count == 1, "a fourth finger must not swipe")
        #expect(events.shortcuts.isEmpty)
        #expect(abs(events.totalMoveMM.y + 30) < 1.0, "only the hand's own travel counts")
    }

    /// Before the drag commits nothing has been picked up, so a fourth finger is still
    /// free to mean a swipe. This is what keeps four-finger gestures reachable at all —
    /// a hand cannot put four fingers down without passing through three.
    @Test("A fourth finger before the drag commits still swipes")
    func fourthFingerBeforeCommitSwipes() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 15, yMM: 100)
        stream.place(1, xMM: 30, yMM: 100)
        stream.place(2, xMM: 45, yMM: 100)
        stream.hold(0.03)
        stream.place(3, xMM: 60, yMM: 100)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.2)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        #expect(events.shortcuts == [.shortcut(.missionControl)])
        #expect(!events.contains(.dragBegan))
    }

    /// The acceleration curve damps to 0.4× at the bottom so that a pixel is reachable when
    /// pointing. Carrying something is the opposite job, and on a 65-mm surface that damping
    /// cannot be made up by moving further.
    @Test("Slow dragging is not read at the precision gain")
    func slowDragIgnoresThePrecisionZone() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 20, yMM: 100)
        stream.place(1, xMM: 35, yMM: 100)
        stream.place(2, xMM: 50, yMM: 100)
        stream.hold(0.02)
        // 10 mm over half a second — around 20 mm/s, deep in the damped zone.
        stream.moveAll(dxMM: 0, dyMM: -10, over: 0.5)
        stream.liftAll()
        stream.hold(0.5)

        let speeds = GestureRecognizer().run(stream).moveSpeeds
        #expect(!speeds.isEmpty)
        #expect(speeds.allSatisfy { $0 >= GestureConfig().dragSpeedFloorMMPerS })
    }

    /// Pointing keeps the precision zone — the floor is for drags only, and swapping the
    /// two would cost the fine targeting the curve exists for.
    @Test("Pointing keeps the slow, precise end of the curve")
    func slowPointingStaysPrecise() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 100)
        stream.hold(0.02)
        stream.move(0, dxMM: 0, dyMM: -10, over: 0.5)
        stream.liftAll()

        let speeds = GestureRecognizer().run(stream).moveSpeeds
        #expect(speeds.contains { $0 < GestureConfig().dragSpeedFloorMMPerS })
    }

    /// Two more fingers landing during a tap-drag used to leave the mouse button down for
    /// good: the phase moved on to the three-finger gesture and nothing on the way out
    /// ever released it. The Mac stayed stuck selecting text until a real click.
    @Test("Landing three fingers during a tap-drag releases the button")
    func tapDragThenThreeFingersReleases() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 75)
        stream.hold(0.05)
        stream.liftAll()
        stream.place(0, xMM: 30, yMM: 75)
        stream.hold(0.02)
        stream.move(0, dxMM: 10, dyMM: 0, over: 0.1)
        stream.place(1, xMM: 45, yMM: 75)
        stream.place(2, xMM: 58, yMM: 75)
        stream.hold(0.05)
        stream.liftAll()
        stream.hold(0.5)

        let events = GestureRecognizer().run(stream)
        let began = events.filter { $0 == .dragBegan }.count
        let ended = events.filter { $0 == .dragEnded }.count
        #expect(began > 0)
        #expect(ended == began, "every press must be released")
    }
}

/// The speed the acceleration curve is read at is a derived, noisy quantity, and the curve
/// multiplies every millimetre by it — so noise in the estimate lands directly in the
/// movement. Position is never smoothed; only this is.
@Suite("Speed smoothing")
struct SpeedSmoothingTests {
    /// A finger hesitating, or a frame arriving late over Wi-Fi, looks identical to a
    /// finger that stopped. Without damping the gain collapses for those frames and the
    /// stroke visibly stutters.
    private func stroke() -> TouchStreamBuilder {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 130)
        stream.hold(0.02)
        stream.move(0, dxMM: 0, dyMM: -40, over: 0.15)
        stream.hold(0.05)
        stream.move(0, dxMM: 0, dyMM: -20, over: 0.1)
        stream.liftAll()
        return stream
    }

    private func speeds(fallTime: Double) -> [Double] {
        var config = GestureConfig()
        config.speedFallTime = fallTime
        return GestureRecognizer(config: config).run(stroke()).moveSpeeds
    }

    @Test("A still moment mid-stroke no longer collapses the gain")
    func hesitationDoesNotCollapseTheGain() {
        let smoothed = speeds(fallTime: GestureConfig().speedFallTime)
        let raw = speeds(fallTime: 0)

        // Ignore the opening frames, where both are still filling their window.
        let smoothedFloor = smoothed.dropFirst(6).min() ?? 0
        let rawFloor = raw.dropFirst(6).min() ?? 0
        #expect(rawFloor < 1, "without damping the estimate reaches zero while the hand pauses")
        #expect(smoothedFloor > 50)
    }

    /// Damping falls only. A flick has to reach its gain on the first frame, or the pointer
    /// feels like it needs a run-up before it will cross the screen.
    @Test("Damping costs nothing on the way up")
    func risesArriveUndamped() {
        let smoothed = speeds(fallTime: GestureConfig().speedFallTime)
        let raw = speeds(fallTime: 0)
        #expect(abs((smoothed.max() ?? 0) - (raw.max() ?? 0)) < 0.001)
    }
}

/// Telling a flick apart from scrolling to a spot and stopping there. The difference lives
/// entirely in the last few tens of milliseconds before lift-off.
@Suite("Flick versus deliberate scroll")
struct FlickDetectionTests {
    private func exitVelocity(_ stream: TouchStreamBuilder) -> (x: Double, y: Double)? {
        guard case .scroll(_, _, .ended(let vx, let vy)) = GestureRecognizer().run(stream).scrolls.last
        else { return nil }
        return (vx, vy)
    }

    @Test("A flick coasts")
    func flickCoasts() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 110)
        stream.place(1, xMM: 42, yMM: 110)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -50, over: 0.12)
        stream.liftAll()

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.y < -300, "a 50 mm throw in 120 ms is around -400 mm/s")
    }

    /// The case the old exponential smoother got wrong: it still remembered the fast part
    /// and threw the page onwards after the user had visibly stopped.
    @Test("Slowing to a stop before lifting does not coast")
    func decelerationDoesNotCoast() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 130)
        stream.place(1, xMM: 42, yMM: 130)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -25, over: 0.1)
        stream.moveAll(dxMM: 0, dyMM: -6, over: 0.1)
        stream.moveAll(dxMM: 0, dyMM: -1, over: 0.12)
        stream.liftAll()

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.x == 0 && exit.y == 0)
    }

    @Test("Holding still after scrolling does not coast")
    func restingDoesNotCoast() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 130)
        stream.place(1, xMM: 42, yMM: 130)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -40, over: 0.12)
        stream.hold(0.3)
        stream.liftAll()

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.x == 0 && exit.y == 0, "the fingers had come to rest, so nothing was thrown")
    }

    /// A long slow scroll finished with a flick must coast at the flick's speed. An average
    /// over the gesture — which is what smoothing amounts to — would drown it.
    @Test("Only the end of the gesture sets the coasting speed")
    func recentMotionWins() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 140)
        stream.place(1, xMM: 42, yMM: 140)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -6, over: 0.6)    // slow: about 10 mm/s
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.1)   // then a throw: about 300 mm/s
        stream.liftAll()

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.y < -200, "the throw must win, not the average of the whole gesture")
    }

    /// Fingers do not leave the glass in the same frame. A flick normally ends by dropping
    /// to one contact and only then to none, and every other test here lifts both at once —
    /// which is why they all passed while short quick flicks refused to coast in real use.
    @Test("A flick still coasts when the fingers lift one after the other")
    func raggedLiftStillCoasts() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 110)
        stream.place(1, xMM: 42, yMM: 110)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -40, over: 0.1)
        stream.lift(1)
        stream.lift(0)

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.y < -200)
    }

    /// A short one, too: a flick can be over in a few centimetres and a fraction of a
    /// second, and that is exactly when the lift is most ragged.
    @Test("A short sharp flick coasts")
    func shortSharpFlickCoasts() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 90)
        stream.place(1, xMM: 42, yMM: 90)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -12, over: 0.05)   // 12 mm in 50 ms — about 240 mm/s
        stream.lift(1)
        stream.lift(0)

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.y < -100)
    }

    /// The counterpart: a ragged lift must not resurrect momentum the user did not ask for.
    @Test("Stopping first still does not coast, even with a ragged lift")
    func raggedLiftAfterStoppingDoesNotCoast() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 130)
        stream.place(1, xMM: 42, yMM: 130)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -30, over: 0.1)
        stream.hold(0.3)
        stream.lift(1)
        stream.lift(0)

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.x == 0 && exit.y == 0)
    }

    @Test("A slow steady scroll never coasts")
    func slowSteadyScrollDoesNotCoast() {
        var stream = TouchStreamBuilder()
        stream.place(0, xMM: 30, yMM: 120)
        stream.place(1, xMM: 42, yMM: 120)
        stream.hold(0.02)
        stream.moveAll(dxMM: 0, dyMM: -12, over: 1.2)   // 10 mm/s, well under the threshold
        stream.liftAll()

        guard let exit = exitVelocity(stream) else { Issue.record("no terminating scroll"); return }
        #expect(exit.x == 0 && exit.y == 0)
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

@Suite("Acceleration curve")
struct AccelerationTests {
    /// The shape that matters: damped below unity for precision, unity in the middle,
    /// rising to a cap. A straight line cannot do the first part at all.
    @Test("Slow is damped, middle is unity, fast is capped")
    func curveShape() {
        let curve = AccelerationCurve()
        #expect(curve.factor(speedMMPerS: 2) < 0.6, "creeping must move the pointer less than the finger")
        #expect(abs(curve.factor(speedMMPerS: 35) - 1.0) < 0.01)
        #expect(curve.factor(speedMMPerS: 5000) == curve.knots.last!.factor, "capped, never extrapolated")
    }

    @Test("The curve never goes backwards")
    func monotonic() {
        let curve = AccelerationCurve()
        for step in 0 ..< 130 {
            let speed = Double(step) * 7
            #expect(curve.factor(speedMMPerS: speed) <= curve.factor(speedMMPerS: speed + 7))
        }
    }

    @Test("Interpolation lands exactly on the knots")
    func hitsKnots() {
        let curve = AccelerationCurve()
        for knot in curve.knots {
            #expect(abs(curve.factor(speedMMPerS: knot.speedMMPerS) - knot.factor) < 1e-9)
        }
    }

    @Test("Sensitivity scales the whole curve without moving its shape")
    func sensitivityScales() {
        var curve = AccelerationCurve()
        let normal = curve.pointsPerMillimetre(speedMMPerS: 50)
        let shape = curve.factor(speedMMPerS: 50)
        curve.sensitivity = 2
        #expect(abs(curve.pointsPerMillimetre(speedMMPerS: 50) - normal * 2) < 1e-9)
        #expect(abs(curve.factor(speedMMPerS: 50) - shape) < 1e-9, "the curve itself must not move")
    }
}

@Suite("Pointer speed estimate")
struct PointerVelocityTests {
    /// Frames are the transport's business. The same physical movement must produce the
    /// same speed whether it arrived in 6 frames or 60, or gain would depend on the phone.
    @Test("Steady movement reads the same at any frame rate", arguments: [60.0, 120.0, 240.0])
    func frameRateIndependent(hz: Double) {
        var velocity = PointerVelocity()
        let step = 1 / hz
        var time = 0.0
        // 200 mm/s for long enough to fill the window.
        for _ in 0 ..< Int(hz * 0.2) {
            time += step
            velocity.add(delta: Vec(x: 200 * step, y: 0), dt: step, at: time)
        }
        #expect(abs(velocity.speed - 200) < 10)
    }

    /// The reversal rule. Without it the estimate still holds the speed built up going one
    /// way when the finger starts going the other, and the pointer bolts.
    @Test("A reversal drops the old speed instead of carrying it")
    func reversalResets() {
        var velocity = PointerVelocity()
        var time = 0.0
        for _ in 0 ..< 20 {
            time += 1.0 / 120
            velocity.add(delta: Vec(x: 3, y: 0), dt: 1.0 / 120, at: time)   // fast, rightwards
        }
        let before = velocity.speed
        #expect(before > 200)

        time += 1.0 / 120
        velocity.add(delta: Vec(x: -0.1, y: 0), dt: 1.0 / 120, at: time)    // now creeping left
        #expect(velocity.speed < before / 4, "the rightward speed must not survive the turn")
    }

    /// The burst rule: a flick after careful positioning should reach high gain at once.
    @Test("A sudden burst is picked up within a frame or two")
    func burstCatchesUp() {
        var velocity = PointerVelocity()
        var time = 0.0
        for _ in 0 ..< 20 {
            time += 1.0 / 120
            velocity.add(delta: Vec(x: 0.05, y: 0), dt: 1.0 / 120, at: time)  // 6 mm/s, slow
        }
        #expect(velocity.speed < 20)

        for _ in 0 ..< 2 {
            time += 1.0 / 120
            velocity.add(delta: Vec(x: 3, y: 0), dt: 1.0 / 120, at: time)     // 360 mm/s
        }
        #expect(velocity.speed > 200, "two frames of a flick must already read as fast")
    }

    /// A tremor reverses every frame, so it never accumulates the two samples an estimate
    /// needs — it can never present itself as travel.
    @Test("A wandering finger reads slow, not fast")
    func wanderingIsSlow() {
        var velocity = PointerVelocity()
        var time = 0.0
        for step in 0 ..< 20 {
            time += 1.0 / 120
            let sign: Double = step.isMultiple(of: 2) ? 1 : -1
            velocity.add(delta: Vec(x: 2 * sign, y: 0), dt: 1.0 / 120, at: time)
        }
        #expect(velocity.speed < 60, "back-and-forth is not crossing the screen")
    }

    @Test("Stale samples age out")
    func staleSamplesExpire() {
        var velocity = PointerVelocity()
        velocity.add(delta: Vec(x: 5, y: 0), dt: 1.0 / 120, at: 0.01)
        velocity.add(delta: Vec(x: 0.01, y: 0), dt: 1.0 / 120, at: 1.0)
        #expect(velocity.speed < 10, "a second-old flick says nothing about now")
    }
}
