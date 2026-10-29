import Foundation

/// Whole-word phrase matching that ignores case, accents, ligatures and
/// punctuation, for French and English: "Au secours" matches "AU SÉCOURS !",
/// "aidez-moi" matches "Aidez moi", "élève" matches "eleve".
/// Matching only — no tone or emotion inference (EU AI Act art. 5).
public struct KeywordMatcher: Sendable {
    private let entries: [(original: String, needle: String)]

    public init(keywords: [String]) {
        entries = HearingSettings.sanitizedKeywords(keywords).compactMap { keyword in
            let normalized = Self.normalize(keyword)
            return normalized.isEmpty ? nil : (keyword, " \(normalized) ")
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Keywords (as the owner typed them) found in `text`, in keyword order.
    public func matches(in text: String) -> [String] {
        guard !entries.isEmpty else { return [] }
        let haystack = " \(Self.normalize(text)) "
        return entries.filter { haystack.contains($0.needle) }.map(\.original)
    }

    /// Lowercase, accent-free, ligature-expanded, letters and digits only,
    /// words separated by single spaces.
    public static func normalize(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        for (ligature, expansion) in [("œ", "oe"), ("æ", "ae"), ("ß", "ss"), ("ﬁ", "fi"), ("ﬂ", "fl")] {
            folded = folded.replacingOccurrences(of: ligature, with: expansion)
        }
        var out = ""
        out.reserveCapacity(folded.unicodeScalars.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }
}
