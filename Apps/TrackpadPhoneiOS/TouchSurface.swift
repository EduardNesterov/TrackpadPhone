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

    /// Stable per-finger ids. UITouch instances persist for a touch's lifetime, so they
    /// key the map directly; the id is what travels on the wire.
    private var ids: [ObjectIdentifier: UInt8] = [:]
    private var live: [ObjectIdentifier: UITouch] = [:]
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
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if ids[key] == nil {
                ids[key] = nextID
                nextID &+= 1
            }
            live[key] = touch
        }
        emitSnapshot(at: touches.first?.timestamp)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // With one finger down, replay every coalesced sample. On a 120 Hz display that
        // is roughly twice the data UIKit would otherwise hand us, and it is the whole
        // reason tracking looks smooth rather than stepped.
        if live.count == 1, let touch = touches.first, let event,
           let samples = event.coalescedTouches(for: touch), samples.count > 1 {
            for sample in samples {
                emit(contacts: [contact(for: touch, at: sample)], at: sample.timestamp)
            }
            return
        }
        emitSnapshot(at: touches.first?.timestamp)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        let timestamp = touches.first?.timestamp
        for touch in touches {
            let key = ObjectIdentifier(touch)
            live[key] = nil
            ids[key] = nil
        }
        // A finger absent from the snapshot has lifted — there is no separate "up" event
        // to lose. See docs/ARCHITECTURE.md §3.
        emitSnapshot(at: timestamp)
        if live.isEmpty { nextID = 0 }
    }

    private func emitSnapshot(at timestamp: TimeInterval?) {
        let contacts = live.values.map { contact(for: $0, at: $0) }
        emit(contacts: contacts, at: timestamp ?? CACurrentMediaTime())
    }

    private func emit(contacts: [Contact], at timestamp: TimeInterval) {
        onFrame?(contacts, timestamp)
    }

    /// - Parameters:
    ///   - touch: the touch whose identity and phase we want.
    ///   - sample: where to read the position from — the touch itself, or one of its
    ///     coalesced samples, which share the same identity.
    private func contact(for touch: UITouch, at sample: UITouch) -> Contact {
        let point = sample.preciseLocation(in: self)
        let size = bounds.size
        let phase: TouchPhase = switch sample.phase {
        case .began: .began
        case .stationary: .stationary
        default: .moved
        }
        return Contact(
            id: ids[ObjectIdentifier(touch)] ?? 0,
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
