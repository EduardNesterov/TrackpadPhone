import CoreGraphics
import Foundation

/// Turns finger motion into cursor motion.
///
/// M0 scope: tracking quality and latency only. The acceleration curve here is a
/// placeholder with plausible numbers — enough that "does this feel right?" is a
/// meaningful question — not the tuned curve M2 will build.
final class Pointer {
    struct Tuning {
        /// Cursor points per millimetre of finger travel at zero speed. Low = precise.
        var baseGain: Double = 2.0
        /// Extra gain per mm/s of finger speed.
        var speedGain: Double = 0.03
        var minGain: Double = 1.5
        var maxGain: Double = 12.0
        /// Overall multiplier, the one knob worth exposing on the command line.
        var sensitivity: Double = 1.0
    }

    var tuning = Tuning()

    private let source = CGEventSource(stateID: .hidSystemState)
    private var position: CGPoint
    private let bounds: CGRect

    /// Sub-point remainder. Without it, slow movement rounds to zero every frame and
    /// the cursor simply refuses to move — the classic symptom of injected pointer input.
    private var residual = CGPoint.zero

    init() {
        bounds = Pointer.desktopBounds()
        position = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Union of all active displays, in the top-left-origin space CGEvent uses.
    private static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// Re-read the real cursor position, so we don't fight a mouse the user just moved.
    func resync() {
        if let live = CGEvent(source: nil)?.location {
            position = live
        }
        residual = .zero
    }

    /// - Parameters:
    ///   - deltaMM: finger travel since the last frame, in millimetres.
    ///   - dt: elapsed seconds, taken from the phone's own clock so network jitter
    ///         cannot distort the speed that drives acceleration.
    func move(deltaMM: CGPoint, dt: Double) {
        let distance = hypot(deltaMM.x, deltaMM.y)
        let speed = dt > 0 ? distance / dt : 0
        let gain = min(max(tuning.baseGain + tuning.speedGain * speed, tuning.minGain), tuning.maxGain)
            * tuning.sensitivity

        let wantX = deltaMM.x * gain + residual.x
        let wantY = deltaMM.y * gain + residual.y

        let stepX = wantX.rounded(.towardZero)
        let stepY = wantY.rounded(.towardZero)
        residual = CGPoint(x: wantX - stepX, y: wantY - stepY)

        guard stepX != 0 || stepY != 0 else { return }

        position.x = min(max(position.x + stepX, bounds.minX), bounds.maxX - 1)
        position.y = min(max(position.y + stepY, bounds.minY), bounds.maxY - 1)

        post(.mouseMoved, deltaX: Int64(stepX), deltaY: Int64(stepY))
    }

    func click() {
        post(.leftMouseDown, clickState: 1)
        post(.leftMouseUp, clickState: 1)
    }

    private func post(
        _ type: CGEventType,
        deltaX: Int64 = 0,
        deltaY: Int64 = 0,
        clickState: Int64 = 0
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: .left
        ) else { return }

        // Absolute position alone is not enough: games, Blender and Figma's pan read
        // the delta fields, and see nothing without these.
        if deltaX != 0 || deltaY != 0 {
            event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        }
        if clickState != 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }
}
