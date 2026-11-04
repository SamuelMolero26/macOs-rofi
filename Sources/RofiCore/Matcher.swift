import Foundation

/// rofi's `-matching` methods (source/helper.c:154-283).
public enum MatchingMethod: String, Sendable {
    case normal, regex, glob, fuzzy, prefix
}

/// Matching settings. Defaults follow rofi's config/config.c.
public struct MatchOptions: Sendable {
    public var method: MatchingMethod = .normal
    public var tokenize = true
    /// `matching_negate_char`: a raw byte, like rofi's `char`.
    public var negateByte = UInt8(ascii: "-")
    public var normalize = false
    public var caseSensitive = false
    public var caseSmart = false

    public init() {}
}

/// A compiled query. Every token must match; a token starting with the
/// negate char must not. Mirrors rofi's `helper_tokenize` and
/// `helper_token_match` (source/helper.c:286-322, 541-560).
public struct Matcher {
    private let tokens: [(regex: NSRegularExpression, invert: Bool)]
    private let normalize: Bool

    public init(query: String, options: MatchOptions) {
        let caseSensitive = isCaseSensitive(query: query, options: options)
        // strtok on " " only: tabs never split, empty tokens are skipped.
        let parts = options.tokenize
            ? query.split(separator: " ").map(String.init)
            : (query.isEmpty ? [] : [query])
        tokens = parts.map { compile($0, options, caseSensitive) }
        normalize = options.normalize
    }

    public func matches(_ text: String) -> Bool {
        let subject = self.subject(text)
        return tokens.allSatisfy { satisfies($0, subject) }
    }

    /// Script mode's `script_token_match` (source/modes/script.c:532-546): a
    /// token whose result on the text equals its invert flag is decided on
    /// meta instead. A plain token may match either one; a negated token
    /// must miss both.
    public func matches(_ text: String, meta: String?) -> Bool {
        let subject = self.subject(text)
        let metaSubject = meta.map(self.subject)
        return tokens.allSatisfy { token in
            let test = satisfies(token, subject)
            guard test == token.invert, let metaSubject else { return test }
            return satisfies(token, metaSubject)
        }
    }

    private func subject(_ text: String) -> String {
        normalize ? stripMarks(text) : text
    }

    /// `helper_token_match` for one token: matched, xor inverted.
    private func satisfies(_ token: (regex: NSRegularExpression, invert: Bool), _ subject: String) -> Bool {
        let range = NSRange(subject.startIndex..., in: subject)
        return (token.regex.firstMatch(in: subject, range: range) != nil) != token.invert
    }
}

/// rofi's `parse_case_sensitivity` (source/helper.c:1672-1691): with smart
/// case, only an uppercase letter (Unicode Lu) in the query turns it on.
public func isCaseSensitive(query: String, options: MatchOptions) -> Bool {
    guard options.caseSmart else { return options.caseSensitive }
    return query.unicodeScalars.contains { $0.properties.generalCategory == .uppercaseLetter }
}

private func compile(_ token: String, _ options: MatchOptions, _ caseSensitive: Bool)
    -> (regex: NSRegularExpression, invert: Bool)
{
    let bytes = token.utf8
    let invert = bytes.first == options.negateByte
    // rofi advances one byte (create_regex, source/helper.c:249-252). A stray
    // continuation byte left behind decodes to U+FFFD here; GRegex rejects that
    // pattern and the token never matches, so the two agree unless the text
    // itself holds U+FFFD.
    let text = invert ? String(decoding: bytes.dropFirst(), as: UTF8.self) : token
    let pattern = switch options.method {
    case .normal: escapeRegex(text)
    case .regex: text
    case .glob: globToRegex(text)
    case .fuzzy: fuzzyToRegex(text)
    case .prefix: "\\b" + escapeRegex(text)
    }
    // An invalid regex falls back to the literal text, as in create_regex.
    // The escaped fallback always compiles.
    let regex = makeRegex(pattern, options, caseSensitive) ?? makeRegex(escapeRegex(text), options, caseSensitive)!
    return (regex, invert)
}

private func makeRegex(_ pattern: String, _ options: MatchOptions, _ caseSensitive: Bool) -> NSRegularExpression? {
    let pattern = options.normalize ? stripMarks(pattern) : pattern
    // GRegex accepts "" (matches everything); NSRegularExpression rejects it.
    return try? NSRegularExpression(
        pattern: pattern.isEmpty ? "(?:)" : pattern,
        options: caseSensitive ? [] : [.caseInsensitive]
    )
}

/// The exact escape set of `g_regex_escape_string`, which glob and fuzzy
/// patterns are built on.
private func escapeRegex(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        if scalar == "\0" {
            out += "\\0"
            continue
        }
        if "\\|()[]{}^$*+?.".unicodeScalars.contains(scalar) {
            out += "\\"
        }
        out.unicodeScalars.append(scalar)
    }
    return out
}

/// `*` becomes `.*` and `?` becomes `\S` (source/helper.c:154-167). Every
/// literal `*` or `?` is escaped, so plain replacement is unambiguous.
private func globToRegex(_ text: String) -> String {
    escapeRegex(text)
        .replacingOccurrences(of: "\\*", with: ".*")
        .replacingOccurrences(of: "\\?", with: "\\S")
}

/// Each code point (an escape pair counts as one) becomes a group, joined
/// lazily: `ab` becomes `(a).*?(b)` (source/helper.c:168-194).
private func fuzzyToRegex(_ text: String) -> String {
    var units: [String] = []
    var scalars = escapeRegex(text).unicodeScalars[...]
    while let scalar = scalars.popFirst() {
        if scalar == "\\" {
            guard let escaped = scalars.popFirst() else { break }
            units.append("\\" + String(escaped))
        } else {
            units.append(String(scalar))
        }
    }
    return units.map { "(\($0))" }.joined(separator: ".*?")
}

/// `normalize-match`: NFKD, then drop combining marks
/// (utf8_helper_simplify_string, source/helper.c:205-226).
private func stripMarks(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: continue
        default: scalars.append(scalar)
        }
    }
    return String(scalars)
}
