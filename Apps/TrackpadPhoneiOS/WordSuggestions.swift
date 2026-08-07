import UIKit

/// Word completions for the keyboard we draw ourselves.
///
/// `UITextChecker` rather than anything learned or shipped: it is offline, it costs nothing
/// to bundle, and it already knows Ukrainian and Russian morphology. That last part is most
/// of the value — in a language where every word has a dozen endings, a hand-rolled prefix
/// list is worse than no list at all.
///
/// What it cannot do is learn from this user, and that is a property of the architecture
/// rather than a shortcoming here: the Mac never tells the phone what was typed, because the
/// phone is a sensor and the text may land in any application on the desktop. So suggestions
/// are built from the letters typed since the last separator and from nothing else.
@MainActor
struct WordSuggestions {
    /// One checker for the app. Building one per keystroke is wasteful, and a SwiftUI view
    /// is rebuilt on every one of them.
    static let shared = WordSuggestions()

    private let checker = UITextChecker()

    /// Completions of `partial` in the current layout's language, longest-prefix first as
    /// the checker returns them.
    ///
    /// Only words that continue what was typed are offered, and the match is
    /// case-insensitive so that a capital at the start of a sentence still finds the
    /// dictionary's lower-case entry. The caller sends the *remainder* rather than the whole
    /// word, which is what keeps the phone from needing to know what the Mac's text field
    /// currently holds — it cannot know, and a keyboard that guesses at that types nonsense.
    func completions(for partial: String, language: String?, limit: Int = 3) -> [String] {
        // Two letters is where a completion stops being a list of the whole dictionary.
        guard partial.count >= 2, let language, let resolved = Self.resolve(language) else {
            return []
        }
        let range = NSRange(location: 0, length: (partial as NSString).length)
        let found = checker.completions(
            forPartialWordRange: range, in: partial, language: resolved
        ) ?? []

        let lowered = partial.lowercased()
        return found
            .filter { $0.count > partial.count && $0.lowercased().hasPrefix(lowered) }
            .prefix(limit)
            .map { String($0.dropFirst(partial.count)) }
    }

    /// Turns "uk" into whatever identifier this device actually has a dictionary under.
    ///
    /// The list depends on the keyboards enabled in iOS Settings, so it is neither fixed nor
    /// guessable: a phone may have `uk`, `uk_UA`, or nothing at all. Asking for a language it
    /// does not have simply returns no words, so the only cost of missing here is silence.
    private static func resolve(_ code: String) -> String? {
        if let cached = resolved[code] { return cached }
        let available = UITextChecker.availableLanguages
        let match = available.first { $0 == code }
            ?? available.first { $0.hasPrefix(code + "_") || $0.hasPrefix(code + "-") }
        resolved[code] = match
        return match
    }

    /// Nil is a real answer here — "this device has no dictionary for that" — so the cache
    /// stores optionals rather than treating a miss as "not looked up yet".
    private static var resolved: [String: String?] = [:]
}
