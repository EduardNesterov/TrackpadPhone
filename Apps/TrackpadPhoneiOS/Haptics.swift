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
    private lazy var fallback = UIImpactFeedbackGenerator(style: .heavy)

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

    /// User-facing multiplier, 0...1. Perception depends heavily on how the phone is
    /// resting — flat on a desk, most of the energy goes into the desk rather than the
    /// finger — so this is not something a fixed value can get right for everyone.
    var strength: Double = 1.0

    func play(_ feedback: Feedback) {
        guard isEnabled else { return }
        let intensity = Float(min(1, Double(feedback.intensity) / 255 * strength))
        guard intensity > 0.02 else { return }

        guard supportsHaptics else {
            fallback.impactOccurred(intensity: CGFloat(intensity))
            return
        }
        if engine == nil { start() }
        guard let engine else { return }

        do {
            let pattern = try CHHapticPattern(events: events(for: feedback.kind, intensity: intensity),
                                              parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.impactOccurred(intensity: CGFloat(intensity))
        }
    }

    /// Attack plus body, rather than a bare transient.
    ///
    /// A lone `.hapticTransient` lasts around ten milliseconds, and high sharpness makes
    /// it a high-frequency tick: audible, but the actual displacement is tiny and a finger
    /// resting on glass barely registers it. Low sharpness moves the chassis further, and
    /// a short continuous tail gives the skin long enough to notice. The transient is kept
    /// only for the edge, so a click still reads as a click and not a hum.
    private func events(for kind: FeedbackKind, intensity: Float) -> [CHHapticEvent] {
        func parameters(_ sharpness: Float) -> [CHHapticEventParameter] {
            [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ]
        }

        switch kind {
        case .click:
            return [
                CHHapticEvent(eventType: .hapticTransient, parameters: parameters(0.55), relativeTime: 0),
                CHHapticEvent(eventType: .hapticContinuous, parameters: parameters(0.1),
                              relativeTime: 0, duration: 0.045),
            ]
        case .gesture:
            // Longer and duller, so a recognised gesture cannot be mistaken for a click.
            return [
                CHHapticEvent(eventType: .hapticContinuous, parameters: parameters(0.0),
                              relativeTime: 0, duration: 0.11),
            ]
        }
    }
}
