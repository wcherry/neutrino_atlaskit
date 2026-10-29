import Foundation

/// Rules of the Atlas Markdown dialect that more than one part of AtlasCore needs.
public enum AtlasMarkdown {
    /// The spec this package implements. It must match the vendored corpus's manifest.
    public static let specVersion = "1.0.0-draft"

    /// The key two strings are compared by, for tags and link resolution: NFC, then
    /// case-folded (SPEC §4.4, §7). Display always keeps the original spelling.
    public static func matchKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether `name` (without its `#`) is a tag under SPEC §4.4: `/`-separated segments of
    /// letters, marks, decimal digits, `_` and `-`, not made of digits alone.
    public static func isValidTag(_ name: String) -> Bool {
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(isTagScalar) }) else { return false }
        return name.unicodeScalars.contains { $0 != "/" && $0.properties.generalCategory != .decimalNumber }
    }

    static func isTagScalar(_ s: Unicode.Scalar) -> Bool {
        if s == "_" || s == "-" { return true }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }
}
