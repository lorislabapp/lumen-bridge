import Foundation
import LumenHearing

/// A wake phrase found at the start of an utterance.
public struct WakeMatch: Sendable, Equatable {
    /// The words after the wake phrase (normalized), i.e. the command.
    public var remainder: String
    /// 1 for an exact "Lumen", lower for fuzzy forms.
    public var confidence: Double
    public var heard: String
}

/// Finds the wake phrase. Today it reads the transcript; a trained acoustic
/// wake-word model (custom "Lumen" keyword) can replace it behind this
/// protocol later — see README §Wake word.
public protocol WakePhraseSpotter: Sendable {
    func spot(transcript: String, audio: PCMAudio?) -> WakeMatch?
}

/// Transcript-based spotter for "Lumen" in French and English: exact word,
/// common ASR mishearings ("loumen", "lumène", "lu men"), one edit away, and
/// an optional lead-in ("dis", "hey", "ok"). Only at the start of the
/// utterance (≤ 2 tokens in), so "la lampe Lumen du salon" is not a wake.
public struct TranscriptWakeSpotter: WakePhraseSpotter {
    public static let wakeWord = "lumen"
    static let knownForms: Set<String> = [
        "lumen", "lumens", "lumene", "lumenn", "loumen", "loumene", "lumin", "lumene", "luman", "lummen",
        "lumenne", "loomen", "lumen's", "lumon",
        // French "Lu-mène" as Parakeet v3 writes it (measured on `say` Thomas, 2026-10-29).
        "lumaine", "loumaine", "lumaines", "lumeine",
    ]
    /// Words that are one edit from "lumen" but mean something else.
    static let blocked: Set<String> = ["women", "human", "lumière", "lumiere", "lemon", "lemen", "linen", "lume"]
    static let leadIns: Set<String> = ["dis", "hey", "ok", "okay", "eh", "he", "salut", "bonjour", "hello", "hi", "alors", "euh", "bon", "oh", "yo", "oui", "please", "stp"]

    public var maxLeadingTokens: Int

    public init(maxLeadingTokens: Int = 2) { self.maxLeadingTokens = maxLeadingTokens }

    public func spot(transcript: String, audio: PCMAudio?) -> WakeMatch? {
        let tokens = KeywordMatcher.normalize(transcript).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        var index = 0
        while index < tokens.count, index <= maxLeadingTokens {
            let token = tokens[index]
            if let confidence = score(token) {
                return WakeMatch(remainder: tokens[(index + 1)...].joined(separator: " "),
                                 confidence: index == 0 ? confidence : confidence * 0.95, heard: token)
            }
            // "lu men" / "lou men" split by the recogniser.
            // "L'humaine, ferme…" (same measurement) and "lu men".
            if index + 1 < tokens.count, (["lu", "lou", "loo", "le"].contains(token) && ["men", "mene", "man"].contains(tokens[index + 1]))
                || (token == "l" && ["humaine", "umaine", "umen"].contains(tokens[index + 1])) {
                return WakeMatch(remainder: tokens[(index + 2)...].joined(separator: " "), confidence: 0.8,
                                 heard: token + " " + tokens[index + 1])
            }
            guard Self.leadIns.contains(token) else { return nil }
            index += 1
        }
        return nil
    }

    func score(_ token: String) -> Double? {
        if token == Self.wakeWord { return 1 }
        if Self.blocked.contains(token) { return nil }
        if Self.knownForms.contains(token) { return 0.9 }
        guard token.hasPrefix("l"), (4...7).contains(token.count) else { return nil }
        return Self.editDistance(token, Self.wakeWord) <= 1 ? 0.75 : nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}

/// "non, annule" / "cancel": undo the last action inside its window.
public enum UndoPhrase {
    static let phrases: [String] = [
        "annule", "annuler", "annulez", "non annule", "non annuler", "annule ca", "annule tout", "non non annule",
        "cancel", "cancel that", "no cancel", "undo", "undo that", "no undo",
        "lumen annule", "lumen cancel", "lumen undo",
    ]

    public static func matches(_ transcript: String) -> Bool {
        var text = KeywordMatcher.normalize(transcript)
        for filler in ["s il te plait", "s il vous plait", "please", "stp"] {
            text = text.replacingOccurrences(of: filler, with: "").trimmingCharacters(in: .whitespaces)
        }
        text = text.split(separator: " ").joined(separator: " ")
        return phrases.contains(text)
    }
}
