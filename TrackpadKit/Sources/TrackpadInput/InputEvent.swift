import Foundation

public enum MouseButton: Sendable, Equatable {
    case left
    case right
}

/// Phase of a continuous scroll, mirroring what macOS expects from a real trackpad.
///
/// These are not decoration. Without began/changed/ended, AppKit treats pixel scrolling
/// as a discrete mouse wheel: no rubber-band at document edges, no smooth deceleration,
/// visible stepping. Getting the phases right is most of what makes injected scrolling
/// feel native.
public enum ScrollPhase: Sendable, Equatable {
    case began
    case changed
    /// Carries the exit velocity in mm/s so the caller can run inertia.
    case ended(velocityX: Double, velocityY: Double)
}

/// System actions we trigger in place of real multi-touch gestures.
///
/// Named for intent rather than for a key combination, because the key combination is not
/// always how they are delivered. Measured on macOS 26: synthesised keystrokes reach the
/// event stream with correct modifier flags and ordinary application shortcuts act on them
/// (⌘N opened a Finder window in the probe), but *symbolic hotkeys* — Mission Control,
/// space switching, App Exposé — are refused no matter how the modifier is expressed.
///
/// So Mission Control is triggered by launching its application, and the sideways swipes
/// map to back/forward, which is an ordinary shortcut and works. Space switching has no
/// public route at all and is deliberately absent. See docs/ARCHITECTURE.md §5.
public enum Shortcut: Sendable, Equatable {
    case missionControl
    case navigateBack
    case navigateForward
}

/// What the recogniser decided the fingers meant.
///
/// Deliberately physical and platform-free: distances in millimetres, no CGEvent, no
/// screen coordinates. That keeps the whole gesture layer testable without a Mac, a
/// window server, or Accessibility permission.
public enum InputEvent: Sendable, Equatable {
    /// Pointer motion, with the speed the acceleration curve should be read at.
    ///
    /// The speed travels with the event rather than being recomputed downstream, because
    /// estimating it well takes a trailing window and a reversal rule — logic that belongs
    /// where it can be tested, not in the layer that talks to CoreGraphics.
    case move(dxMM: Double, dyMM: Double, speedMMPerS: Double)
    case click(MouseButton, count: Int)
    /// Press-and-hold drag: down, then a run of `move`, then `up`.
    case dragBegan
    case dragEnded
    case scroll(dxMM: Double, dyMM: Double, phase: ScrollPhase)
    /// Positive zooms in. One step per notch of pinch.
    case zoom(steps: Int)
    case shortcut(Shortcut)
}
