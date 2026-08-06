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

/// Keyboard shortcuts we send in place of real multi-touch gestures.
///
/// macOS exposes no public API for synthesising a genuine pinch or swipe — the real
/// mechanism is a private event type that breaks across releases. Mapping onto shortcuts
/// covers the same intent through supported means. See docs/ARCHITECTURE.md §5.
public enum Shortcut: Sendable, Equatable {
    case missionControl
    case applicationWindows
    case spaceLeft
    case spaceRight
}

/// What the recogniser decided the fingers meant.
///
/// Deliberately physical and platform-free: distances in millimetres, no CGEvent, no
/// screen coordinates. That keeps the whole gesture layer testable without a Mac, a
/// window server, or Accessibility permission.
public enum InputEvent: Sendable, Equatable {
    /// Pointer motion. Acceleration is applied downstream, not here.
    case move(dxMM: Double, dyMM: Double, dt: Double)
    case click(MouseButton, count: Int)
    /// Press-and-hold drag: down, then a run of `move`, then `up`.
    case dragBegan
    case dragEnded
    case scroll(dxMM: Double, dyMM: Double, phase: ScrollPhase)
    /// Positive zooms in. One step per notch of pinch.
    case zoom(steps: Int)
    case shortcut(Shortcut)
}
