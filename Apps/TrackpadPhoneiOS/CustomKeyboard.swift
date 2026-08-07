import SwiftUI
import TrackpadProtocol

/// A keyboard we draw ourselves.
///
/// The system keyboard would be less work, but its height is fixed by iOS and in landscape
/// it leaves the keys small and a wide empty band above them. Drawing it means choosing how
/// much of the screen it takes — here most of it, leaving a strip at the top that still
/// works as a trackpad, so the cursor can be nudged without dismissing anything.
///
/// The cost of leaving the system keyboard behind is dictation and emoji. Cyrillic is not
/// among the losses: text goes to the Mac as Unicode, so a layout is only a table of
/// characters and `KeyboardLayout` carries three of them.
struct CustomKeyboard: View {
    let onKeyInput: (KeyInput) -> Void
    @Binding var isVisible: Bool

    @State private var layoutIndex = 0
    @State private var showingSymbols = false
    @State private var shifted = false
    @State private var capsLocked = false
    @State private var modifiers: KeyModifiers = []

    /// The letters typed since the last separator — everything the phone knows about the
    /// word in progress, and everything it can know. See `WordSuggestions`.
    @State private var typedWord = ""
    /// The *tails* of the current completions, not the whole words: what tapping one sends.
    @State private var completions: [String] = []

    private var layout: KeyboardLayout {
        showingSymbols ? .symbols : KeyboardLayout.letterLayouts[layoutIndex]
    }

    var body: some View {
        VStack(spacing: 6) {
            suggestionStrip.frame(height: 34)
            row(commandKeys).frame(height: 40)
            ForEach(Array(letterRows.enumerated()), id: \.offset) { _, keys in
                row(keys)
            }
            row(bottomKeys).frame(height: 48)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
    }

    // MARK: Suggestions

    /// Always present, even with nothing to offer.
    ///
    /// Keys that move under a thumb mid-word are worse than a band of empty space: the strip
    /// appears and disappears with every word, and every appearance would shift the whole
    /// keyboard down a row's height just as the next letter is being aimed at.
    private var suggestionStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(completions.enumerated()), id: \.offset) { _, tail in
                Button {
                    accept(tail)
                } label: {
                    Text(typedWord + tail)
                        .font(.system(size: 16))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            // Keeps two suggestions from stretching to the width of three.
            if completions.count < 3 {
                ForEach(0 ..< (3 - completions.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Sends the rest of the word and a space.
    ///
    /// The remainder rather than the whole word, so nothing has to be taken back: the Mac's
    /// text field already holds the letters that were typed, and the phone has no way to
    /// read it and check. Backspacing what it *believes* is there would eat real text on
    /// every disagreement.
    private func accept(_ tail: String) {
        send(KeyInput(modifiers: [], text: tail + " "))
        typedWord = ""
        completions = []
        if !capsLocked { shifted = false }
    }

    private func refreshCompletions() {
        completions = WordSuggestions.shared.completions(
            for: typedWord, language: showingSymbols ? nil : layout.language
        )
    }

    // MARK: Rows

    /// Widths are worked out here rather than left to the stack.
    ///
    /// `layoutPriority` looks like it should do this and does not: it decides who gets
    /// space *first*, so a space bar asking for five units simply took the whole row and
    /// starved every letter beside it to nothing. Proportions need actual arithmetic.
    private func row(_ keys: [Key]) -> some View {
        GeometryReader { geometry in
            let spacing = 6.0
            let units = keys.reduce(0) { $0 + $1.width }
            let unit = max(0, (geometry.size.width - spacing * Double(keys.count - 1)) / units)
            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    keyButton(key).frame(width: unit * key.width)
                }
            }
        }
    }

    private var letterRows: [[Key]] {
        let characters = layout.characters(shifted: shifted || capsLocked)
        var rows = characters.map { row in
            row.map { Key(label: $0, action: .text($0)) }
        }
        // Shift and backspace flank the last row, as on every keyboard since the typewriter.
        if rows.count >= 3 {
            let letters = Double(rows[2].count)
            // Sized so the last row's letters line up with the row above rather than
            // stretching to fill: the flanking keys absorb the difference.
            let flank = max(1.3, (Double(rows[1].count) - letters) / 2 + 1.3)
            rows[2].insert(Key(label: capsLocked ? "⇪" : "⇧", action: .shift, width: flank), at: 0)
            rows[2].append(Key(label: "⌫", action: .backspace, width: flank))
        }
        return rows
    }

    /// Everything a Mac keyboard has that a phone keyboard does not.
    private var commandKeys: [Key] {
        [
            Key(label: "esc", action: .code(53), width: 1.3),
            Key(label: "⇥", action: .code(48)),
            Key(label: "←", action: .code(123)),
            Key(label: "↓", action: .code(125)),
            Key(label: "↑", action: .code(126)),
            Key(label: "→", action: .code(124)),
            Key(label: "", action: .spacer, width: 2.5),
            Key(label: "⌃", action: .modifier(.control)),
            Key(label: "⌥", action: .modifier(.option)),
            Key(label: "⇧", action: .modifier(.shift)),
            Key(label: "⌘", action: .modifier(.command)),
        ]
    }

    private var bottomKeys: [Key] {
        var keys = [Key(label: showingSymbols ? "АБВ" : "123", action: .toggleSymbols, width: 1.4)]
        if !showingSymbols {
            keys.append(Key(label: layout.name, action: .cycleLayout, width: 1.4))
        }
        keys.append(Key(label: "space", action: .text(" "), width: 5))
        keys.append(Key(label: "⏎", action: .code(36), width: 1.8))
        keys.append(Key(label: "⌄", action: .hide, width: 1.2))
        return keys
    }

    // MARK: Keys

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        if case .spacer = key.action {
            Color.clear
        } else {
            Button {
                press(key)
            } label: {
                Text(key.label)
                    .font(.system(size: key.label.count > 2 ? 15 : 21, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background(for: key), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func background(for key: Key) -> Color {
        if case .modifier(let modifier) = key.action, modifiers.contains(modifier) {
            return .accentColor
        }
        if case .shift = key.action, shifted || capsLocked {
            return .accentColor
        }
        if case .text = key.action { return Color(white: 0.26) }
        return Color(white: 0.18)
    }

    // MARK: Input

    private func press(_ key: Key) {
        switch key.action {
        case .text(let character):
            send(KeyInput(modifiers: modifiers, text: character))
            // A letter continues the word in progress; anything else ends it. Held that way
            // rather than by asking what the character *is not*, because the layouts carry
            // apostrophes and hyphens that sit inside words in some languages and between
            // them in others, and the checker is the one that knows.
            if modifiers.isEmpty, character.first?.isLetter == true {
                typedWord += character
            } else {
                typedWord = ""
            }
            refreshCompletions()
            // Shift is a one-shot unless locked, exactly as on the system keyboard.
            if !capsLocked { shifted = false }
            modifiers = []

        case .code(let code):
            send(KeyInput(keyCode: code, modifiers: modifiers))
            // Return, tab, escape and the arrows all leave the word behind — the caret may
            // now be anywhere at all.
            typedWord = ""
            refreshCompletions()
            modifiers = []

        case .backspace:
            send(KeyInput(keyCode: 51, modifiers: modifiers))
            typedWord = String(typedWord.dropLast())
            refreshCompletions()
            modifiers = []

        case .modifier(let modifier):
            // Sticky: a touch screen has no way to hold a key down while pressing another,
            // so the modifier waits for the next keystroke and then clears itself.
            if modifiers.contains(modifier) {
                modifiers.remove(modifier)
            } else {
                modifiers.insert(modifier)
            }

        case .shift:
            if shifted, !capsLocked {
                capsLocked = true
                shifted = false
            } else if capsLocked {
                capsLocked = false
            } else {
                shifted = true
            }

        case .cycleLayout:
            layoutIndex = (layoutIndex + 1) % KeyboardLayout.letterLayouts.count
            // The dictionary changed under the word, so the word is no longer a prefix of
            // anything worth offering.
            typedWord = ""
            refreshCompletions()

        case .toggleSymbols:
            showingSymbols.toggle()
            shifted = false
            typedWord = ""
            refreshCompletions()

        case .hide:
            isVisible = false

        case .spacer:
            break
        }
    }

    private func send(_ input: KeyInput) {
        onKeyInput(input)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
