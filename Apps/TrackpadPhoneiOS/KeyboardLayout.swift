import Foundation
import TrackpadProtocol

/// What pressing a key does.
enum KeyAction: Equatable {
    /// Types the character. Text rather than a key code, so a layout is only ever a table
    /// of characters — which is the whole reason Cyrillic costs nothing here.
    case text(String)
    /// A physical key: Return, Escape, an arrow. These are actions, not characters.
    case code(UInt16)
    case modifier(KeyModifiers)
    case shift
    case backspace
    /// Cycle the letter layout — the globe key.
    case cycleLayout
    /// Swap letters for numbers and punctuation.
    case toggleSymbols
    case hide
    /// Holds a gap in a row. Rendered as nothing, but takes its share of the width.
    case spacer
}

struct Key: Identifiable, Equatable {
    /// Label plus action is unique within a row, and stable across re-renders — which is
    /// what SwiftUI needs. A fresh UUID per rebuild would make every key a new view on
    /// every keystroke.
    var id: String { "\(label)-\(String(describing: action))" }
    var label: String
    var action: KeyAction
    /// Multiples of one letter key. Space is wide, Return and Shift are wider than a letter.
    var width: Double = 1
}

/// A named table of characters. Nothing here knows about key codes, so adding a language
/// is adding three rows of strings.
struct KeyboardLayout {
    var name: String
    /// Which dictionary to complete words from, as a bare language code — the device may
    /// hold it under `uk`, `uk_UA` or not at all, and `WordSuggestions` sorts that out.
    /// Nil where completion makes no sense, which is the symbol layout.
    var language: String?
    var rows: [[String]]
    /// Uppercase forms, when they are not simply `uppercased()`.
    var shiftedRows: [[String]]?

    func characters(shifted: Bool) -> [[String]] {
        guard shifted else { return rows }
        if let shiftedRows { return shiftedRows }
        return rows.map { $0.map { $0.uppercased() } }
    }

    static let english = KeyboardLayout(
        name: "EN",
        language: "en",
        rows: [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"],
        ],
        shiftedRows: nil
    )

    static let ukrainian = KeyboardLayout(
        name: "УКР",
        language: "uk",
        rows: [
            ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"],
            ["ф", "і", "в", "а", "п", "р", "о", "л", "д", "ж", "є"],
            ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю"],
        ],
        shiftedRows: nil
    )

    static let russian = KeyboardLayout(
        name: "РУС",
        language: "ru",
        rows: [
            ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"],
            ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"],
            ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю"],
        ],
        shiftedRows: nil
    )

    static let symbols = KeyboardLayout(
        name: "123",
        rows: [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            [".", ",", "?", "!", "'", "_", "=", "+"],
        ],
        shiftedRows: [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["\\", "|", "~", "<", ">", "€", "£", "¥", "•", "`"],
            [".", ",", "?", "!", "'", "§", "±", "…"],
        ]
    )

    static let letterLayouts = [english, ukrainian, russian]
}
