import SwiftUI
import TrackpadProtocol
import UIKit

/// The trackpad surface.
///
/// Raw `touchesBegan/Moved/Ended` on a bare view, deliberately — a UIGestureRecognizer
/// adds recognition delay and can steal touches outright, and this app's whole job is to
/// forward touches untouched.
final class TouchSurfaceView: UIView {
    var onFrame: (([Contact], TimeInterval) -> Void)?
    var onLayout: ((CGSize, CGFloat) -> Void)?

    /// Wire ids for the fingers that are on the surface *right now*.
    ///
    /// Rebuilt from the event on every callback and never held across one. UIKit recycles
    /// `UITouch` objects, and Apple's documentation says outright not to retain them — a
    /// map that keeps them alive can hand a brand-new finger the id of one that is long
    /// gone, or keep reporting a finger that lifted while we were not told. Either way the
    /// Mac sees contacts that are not there, and a single finger moving becomes a
    /// three-finger drag: text selects itself and things happen that nobody asked for.
    private var ids: [ObjectIdentifier: UInt8] = [:]
    private var nextID: UInt8 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size, window?.screen.scale ?? 3)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        emitSnapshot(from: event, at: touches.first?.timestamp)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(in: event)
        // With one finger down, replay every coalesced sample. On a 120 Hz display that
        // is roughly twice the data UIKit would otherwise hand us, and it is the whole
        // reason tracking looks smooth rather than stepped.
        if active.count == 1, let touch = active.first, let event,
           let samples = event.coalescedTouches(for: touch), samples.count > 1 {
            let assigned = assignIDs(to: active)
            for sample in samples {
                emit(
                    contacts: [contact(for: touch, at: sample, id: assigned[ObjectIdentifier(touch)] ?? 0)],
                    at: sample.timestamp
                )
            }
            return
        }
        emitSnapshot(from: event, at: touches.first?.timestamp)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A finger absent from the snapshot has lifted — there is no separate "up" event
        // to lose. See docs/ARCHITECTURE.md §3.
        emitSnapshot(from: event, at: touches.first?.timestamp)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        emitSnapshot(from: event, at: touches.first?.timestamp)
    }

    /// The fingers actually on this view, according to the event rather than to anything
    /// we remember. A touch the system took away — a system gesture claiming it, a
    /// cancellation we were never handed — simply stops appearing here, which is the
    /// property the retained map did not have.
    private func activeTouches(in event: UIEvent?) -> [UITouch] {
        guard let all = event?.allTouches else { return [] }
        return all.filter { $0.view === self && $0.phase != .ended && $0.phase != .cancelled }
    }

    /// Ids for exactly the touches that are down, keeping the ones already handed out.
    ///
    /// The map is replaced rather than updated, so an id belongs to a finger only while
    /// that finger is on the surface. New ids avoid the ones in use, because the Mac keys
    /// contacts by id and two fingers sharing one collapse into a single contact — three
    /// fingers would arrive as two and the gesture would be misread rather than fail.
    private func assignIDs(to touches: [UITouch]) -> [ObjectIdentifier: UInt8] {
        var fresh: [ObjectIdentifier: UInt8] = [:]
        var taken = Set(touches.compactMap { ids[ObjectIdentifier($0)] })
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if let existing = ids[key] {
                fresh[key] = existing
            } else {
                let claimed = claimID(avoiding: taken)
                taken.insert(claimed)
                fresh[key] = claimed
            }
        }
        ids = fresh
        if ids.isEmpty { nextID = 0 }
        return fresh
    }

    private func claimID(avoiding taken: Set<UInt8>) -> UInt8 {
        for _ in 0 ..< 256 {
            let candidate = nextID
            nextID &+= 1
            if !taken.contains(candidate) { return candidate }
        }
        return nextID
    }

    private func emitSnapshot(from event: UIEvent?, at timestamp: TimeInterval?) {
        let active = activeTouches(in: event)
        let assigned = assignIDs(to: active)
        let contacts = active.map {
            contact(for: $0, at: $0, id: assigned[ObjectIdentifier($0)] ?? 0)
        }
        emit(contacts: contacts, at: timestamp ?? CACurrentMediaTime())
    }

    private func emit(contacts: [Contact], at timestamp: TimeInterval) {
        onFrame?(contacts, timestamp)
    }

    /// - Parameters:
    ///   - touch: the touch whose identity and phase we want.
    ///   - sample: where to read the position from — the touch itself, or one of its
    ///     coalesced samples, which share the same identity.
    private func contact(for touch: UITouch, at sample: UITouch, id: UInt8) -> Contact {
        let point = sample.preciseLocation(in: self)
        let size = bounds.size
        let phase: TouchPhase = switch sample.phase {
        case .began: .began
        case .stationary: .stationary
        default: .moved
        }
        return Contact(
            id: id,
            phase: phase,
            x: size.width > 0 ? Float(point.x / size.width) : 0,
            y: size.height > 0 ? Float(point.y / size.height) : 0,
            majorRadiusMM: Float(sample.majorRadius / DeviceSurface.pixelsPerInch * 25.4 * (window?.screen.scale ?? 3))
        )
    }
}

struct TouchSurface: UIViewRepresentable {
    let onFrame: ([Contact], TimeInterval) -> Void
    let onLayout: (CGSize, CGFloat) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        // Set here as well as in the initialiser, and never remove it: this defaults to
        // false on UIView, and when it is false the second finger produces no
        // touchesBegan at all. Every multi-finger gesture silently disappears while
        // single-finger tracking keeps working, which points the investigation at the
        // recogniser instead of here.
        view.isMultipleTouchEnabled = true
        view.onFrame = onFrame
        view.onLayout = onLayout
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        view.onFrame = onFrame
        view.onLayout = onLayout
    }
}
