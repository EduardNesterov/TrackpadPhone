import CoreGraphics
import Foundation
import TrackpadProtocol

/// Types on the Mac's behalf.
///
/// Two routes, chosen by what the phone sent. Plain text goes in as Unicode, which sidesteps
/// keyboard layouts entirely — Cyrillic and emoji arrive intact without anyone mapping
/// characters to key codes. Anything with a modifier goes in as a *key*, because ⌘C is the
/// C key on the keyboard, not the character "c": on a Ukrainian layout the same physical key
/// produces "с", and sending that as text would type a letter instead of copying.
public struct Keyboard {
    private let source: CGEventSource?

    public init(source: CGEventSource?) {
        self.source = source
    }

    public func apply(_ input: KeyInput) {
        if input.keyCode != 0 {
            send(keyCode: CGKeyCode(input.keyCode), modifiers: input.modifiers)
            return
        }
        guard !input.text.isEmpty else { return }

        if input.modifiers.isEmpty {
            type(input.text)
        } else if let code = Keyboard.keyCode(for: input.text) {
            send(keyCode: code, modifiers: input.modifiers)
        }
        // A modified character with no key code — a shortcut on a key we have no mapping
        // for — is dropped rather than typed, since typing it would be plainly wrong.
    }

    // MARK: - Text

    public func type(_ text: String) {
        // One event carrying the whole string, not one per character: the receiving app
        // sees a single insertion, which is both faster and what a real IME produces.
        let utf16 = Array(text.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keys

    public func send(keyCode: CGKeyCode, modifiers: KeyModifiers) {
        let flags = Keyboard.flags(for: modifiers)

        for (mask, code) in Keyboard.modifierKeys where modifiers.contains(mask) {
            postModifier(code, flags: flags, down: true)
        }
        post(keyCode, flags: flags, down: true)
        post(keyCode, flags: flags, down: false)
        for (mask, code) in Keyboard.modifierKeys.reversed() where modifiers.contains(mask) {
            postModifier(code, flags: [], down: false)
        }
    }

    private func post(_ keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Modifiers must be pressed for real, as `flagsChanged`, not merely flagged on the
    /// key event — the same lesson the gesture shortcuts cost. Applications do read the
    /// flags, but leaving the actual modifier state unset also leaves it inconsistent, and
    /// later mouse events inherit a phantom modifier from it.
    private func postModifier(_ keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(3000)
    }

    private static let modifierKeys: [(KeyModifiers, CGKeyCode)] = [
        (.command, 55), (.shift, 56), (.option, 58), (.control, 59),
    ]

    private static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: - Character to key code

    /// US layout positions, used only when a modifier is held.
    ///
    /// Deliberately a fixed table rather than a lookup through the active input source:
    /// shortcuts are muscle memory tied to key *positions*, and macOS itself matches ⌘C to
    /// the C key whatever layout is active. Anything not listed simply has no shortcut.
    private static let codesByCharacter: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    static func keyCode(for text: String) -> CGKeyCode? {
        guard let character = text.lowercased().first else { return nil }
        return codesByCharacter[character]
    }

    // MARK: - Named keys

    public enum NamedKey: UInt16 {
        case returnKey = 36
        case tab = 48
        case space = 49
        case delete = 51
        case escape = 53
        case left = 123
        case right = 124
        case down = 125
        case up = 126
    }
}
