import SwiftUI
import TrackpadProtocol
import UIKit

/// Captures typing without holding any text.
///
/// `UIKeyInput` is the whole trick: a view that adopts it and becomes first responder gets
/// the system keyboard and receives `insertText` / `deleteBackward`, with no text storage,
/// no cursor and no document to keep in sync. A `UITextField` would fight us on all three
/// — this is a wire, not an editor.
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((UInt16, KeyModifiers) -> Void)?
    /// Sticky modifiers from the accessory bar, applied to the next keystroke.
    var pendingModifiers: KeyModifiers = []
    var onModifiersConsumed: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // Return arrives as a newline, but in almost every application it is an action
        // rather than a character — sending it as text would insert a line break in a
        // search field instead of submitting it.
        if text == "\n" {
            emitKey(36)
            return
        }
        if !pendingModifiers.isEmpty {
            // A modified character is a shortcut. The Mac resolves the character to a key
            // position, because ⌘C is the C key regardless of the layout in use.
            let modifiers = pendingModifiers
            clearModifiers()
            onKeyWithText?(text, modifiers)
            return
        }
        onText?(text)
    }

    func deleteBackward() {
        emitKey(51)
    }

    /// Sent when a character carries modifiers: the Mac needs the character to find the key.
    var onKeyWithText: ((String, KeyModifiers) -> Void)?

    func emitKey(_ code: UInt16) {
        let modifiers = pendingModifiers
        clearModifiers()
        onKey?(code, modifiers)
    }

    private func clearModifiers() {
        guard !pendingModifiers.isEmpty else { return }
        pendingModifiers = []
        onModifiersConsumed?()
        refreshModifierButtons()
    }

    // MARK: Accessory bar

    /// Docked to the keyboard rather than drawn over it, so it follows the keyboard up and
    /// down instead of having to track its frame.
    override var inputAccessoryView: UIView? { accessory }

    private lazy var accessory: UIView = {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 46))
        bar.backgroundColor = UIColor(white: 0.13, alpha: 1)

        let keys = UIStackView(arrangedSubviews: [
            button("esc", key: 53), button("⇥", key: 48),
            button("←", key: 123), button("↓", key: 125), button("↑", key: 126), button("→", key: 124),
        ])
        let mods = UIStackView(arrangedSubviews: [
            modifierButton("⌃", .control), modifierButton("⌥", .option),
            modifierButton("⇧", .shift), modifierButton("⌘", .command),
        ])
        for stack in [keys, mods] {
            stack.spacing = 6
            stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
        }
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            keys.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            keys.heightAnchor.constraint(equalToConstant: 34),
            mods.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            mods.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            mods.heightAnchor.constraint(equalToConstant: 34),
            mods.leadingAnchor.constraint(greaterThanOrEqualTo: keys.trailingAnchor, constant: 12),
        ])
        return bar
    }()

    private func styled(_ title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = UIColor(white: 0.22, alpha: 1)
        button.tintColor = .white
        button.layer.cornerRadius = 7
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return button
    }

    private func button(_ title: String, key: UInt16) -> UIButton {
        let button = styled(title)
        button.addAction(UIAction { [weak self] _ in self?.emitKey(key) }, for: .touchUpInside)
        return button
    }

    /// Sticky rather than held: there is no way to hold ⌘ and tap a letter on a touch
    /// screen, so it stays armed until the next keystroke consumes it.
    private func modifierButton(_ title: String, _ modifier: KeyModifiers) -> UIButton {
        let button = styled(title)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if pendingModifiers.contains(modifier) {
                pendingModifiers.remove(modifier)
            } else {
                pendingModifiers.insert(modifier)
            }
            onModifiersChanged?(pendingModifiers)
            self.refreshModifierButtons()
        }, for: .touchUpInside)
        modifierButtons.append((button, modifier))
        return button
    }

    private var modifierButtons: [(UIButton, KeyModifiers)] = []
    var onModifiersChanged: ((KeyModifiers) -> Void)?

    func refreshModifierButtons() {
        for (button, modifier) in modifierButtons {
            let active = pendingModifiers.contains(modifier)
            button.backgroundColor = active ? .systemBlue : UIColor(white: 0.22, alpha: 1)
        }
    }

    // MARK: Traits

    // Autocorrection and smart punctuation would silently rewrite what was typed —
    // curly quotes into source code, a capital after every full stop. This is a keyboard,
    // not a writing assistant.
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
}

/// Bridges the capture view into SwiftUI and owns whether the keyboard is showing.
struct KeyboardCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var modifiers: KeyModifiers
    let onKeyInput: (KeyInput) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onText = { onKeyInput(KeyInput(text: $0)) }
        view.onKey = { code, mods in onKeyInput(KeyInput(keyCode: code, modifiers: mods)) }
        view.onKeyWithText = { text, mods in onKeyInput(KeyInput(modifiers: mods, text: text)) }
        view.onModifiersConsumed = { modifiers = [] }
        view.onModifiersChanged = { modifiers = $0 }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        if view.pendingModifiers != modifiers {
            view.pendingModifiers = modifiers
            view.refreshModifierButtons()
        }
        if isActive, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: KeyCaptureView?
    }
}
