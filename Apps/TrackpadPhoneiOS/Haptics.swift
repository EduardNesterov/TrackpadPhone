import CoreHaptics
import TrackpadProtocol
import UIKit

/// Tactile feedback for the surface.
///
/// The phone's screen shows nothing while it is being used as a trackpad, so this is the
/// only confirmation a finger gets that anything registered at all. A trackpad without it
/// feels dead in a way that no amount of tracking accuracy makes up for.
///
/// CoreHaptics rather than `UIImpactFeedbackGenerator` because the two kinds need to feel
/// different — a click should be crisp and a recognised gesture blunt — and only the
/// former lets sharpness be set. The generator stays as the fallback for hardware without
/// a Taptic Engine.
@MainActor
final class Haptics {
    var isEnabled = true {
        didSet { if isEnabled { start() } else { stop() } }
    }

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private lazy var fallback = UIImpactFeedbackGenerator(style: .light)

    func start() {
        guard isEnabled, supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            // The engine is stopped whenever the app leaves the foreground, and audio
            // interruptions can reset it. Without both handlers it silently stays dead
            // after the first phone call or trip to the home screen.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.engine = nil
                    self?.start()
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            // Not worth surfacing: the fallback generator still works, and a trackpad
            // that buzzes a little differently beats one that refuses to run.
            engine = nil
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    func play(_ feedback: Feedback) {
        guard isEnabled else { return }
        let intensity = Float(feedback.intensity) / 255

        guard supportsHaptics else {
            fallback.impactOccurred(intensity: CGFloat(intensity))
            return
        }
        if engine == nil { start() }
        guard let engine else { return }

        // Sharpness is what separates the two: a click is a tick, a gesture is a thud.
        let sharpness: Float = switch feedback.kind {
        case .click: 0.85
        case .gesture: 0.25
        }

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.impactOccurred(intensity: CGFloat(intensity))
        }
    }
}
