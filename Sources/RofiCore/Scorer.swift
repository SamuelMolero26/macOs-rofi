/// rofi's `levenshtein` (source/helper.c:815-853): edit distance over code
/// points, lowercasing both sides unless `caseSensitive`. Used for
/// `-sorting-method normal` (source/view.c:518-521).
public func levenshtein(_ needle: String, _ haystack: String, caseSensitive: Bool) -> Int {
    let fold = { (s: Unicode.Scalar) in caseSensitive ? s : lowercased(s) }
    let needle = needle.unicodeScalars.map(fold)
    var column = Array(0...needle.count)
    for (x, haystackc) in haystack.unicodeScalars.map(fold).enumerated() {
        var lastdiag = x
        column[0] = x + 1
        for (y, needlec) in needle.enumerated() {
            let olddiag = column[y + 1]
            column[y + 1] = min(column[y + 1] + 1, column[y] + 1, lastdiag + (needlec == haystackc ? 0 : 1))
            lastdiag = olddiag
        }
    }
    return column[needle.count]
}

/// Scorers accepted by `-sorting-method`. Both return lower scores for better
/// matches, matching the comparison in rofi's view sorter.
public enum SortingMethod: String, Equatable, Sendable {
    case levenshtein
    case fzf

    /// helper.c:676-693: names compare exactly and `normal` aliases levenshtein.
    /// ponytail: `fzf-v2` is out of scope (issue #70), so it is rejected.
    init(arguments args: Arguments) throws {
        switch args.string("-sorting-method") {
        case nil, "normal", "levenshtein": self = .levenshtein
        case "fzf": self = .fzf
        case let value?:
            throw InvalidMatchingConfiguration(errors: [
                "\tconfig.sorting_method=\(value) is not a valid sorting strategy.\n"
                    + "Valid options are: normal or fzf.\n"
            ])
        }
    }
}

/// Stably rank an already-filtered result set. Empty input remains in source
/// order, as rofi bypasses scoring until the user enters a query.
func sortedByScore<Element>(
    _ elements: [Element], query: String, match: MatchOptions, method: SortingMethod,
    text: (Element) -> String
) -> [Element] {
    guard !query.isEmpty else { return elements }
    let caseSensitive = isCaseSensitive(query: query, options: match)
    let ranked = elements.enumerated().map { offset, element in
        let score =
            switch method {
            case .levenshtein:
                levenshtein(query, text(element), caseSensitive: caseSensitive)
            case .fzf:
                fuzzyScore(query, text(element), caseSensitive: caseSensitive)
            }
        return (offset: offset, element: element, score: score)
    }
    return ranked.sorted { first, second in
        first.score == second.score ? first.offset < second.offset : first.score < second.score
    }.map(\.element)
}

/// Max text length the fzf scorer accepts (FUZZY_SCORER_MAX_LENGTH).
private let maxLength = 256
/// MIN_SCORE is INT_MIN / 2; scores stay well inside Int32.
private let minScore = Int(Int32.min) / 2
private let leadingGapScore = -4
private let gapScore = -5
private let wordStartScore = 50
private let nonWordScore = 40
private let camelScore = wordStartScore + gapScore - 1
private let consecutiveScore = wordStartScore + gapScore
private let patternNonStartMultiplier = 1
private let patternStartMultiplier = 2

private enum CharClass { case lower, upper, digit, nonWord }

/// `rofi_scorer_get_character_class` (source/helper.c:934-946): glib's
/// islower/isupper/isdigit are exactly Ll, Lu and Nd.
private func characterClass(_ c: Unicode.Scalar) -> CharClass {
    switch c.properties.generalCategory {
    case .lowercaseLetter: .lower
    case .uppercaseLetter: .upper
    case .decimalNumber: .digit
    default: .nonWord
    }
}

/// `rofi_scorer_get_score_for` (source/helper.c:956-967).
private func score(_ prev: CharClass, _ curr: CharClass) -> Int {
    if prev == .nonWord && curr != .nonWord { return wordStartScore }
    if (prev == .lower && curr == .upper) || (prev != .digit && curr == .digit) { return camelScore }
    if curr == .nonWord { return nonWordScore }
    return 0
}

/// rofi's fzf-like `rofi_scorer_fuzzy_evaluate` (source/helper.c:968-1025),
/// used for `-sorting-method fzf`. Lower is better; a text over 256 code
/// points, or no alignment at all, scores `-(INT_MIN / 2)`.
public func fuzzyScore(_ pattern: String, _ text: String, caseSensitive: Bool) -> Int {
    let str = Array(text.unicodeScalars)
    guard str.count <= maxLength else { return -minScore }
    var pfirst = true
    var pstart = true
    var prev = CharClass.nonWord
    let scores = str.map { c in
        let cur = characterClass(c)
        defer { prev = cur }
        return score(prev, cur)
    }
    var dp = Array(repeating: minScore, count: str.count)
    // uleft/ulefts deliberately carry over from the previous row's last
    // column into the next row's first, exactly as in the C loop.
    var uleft = 0
    var ulefts = 0
    for pc in pattern.unicodeScalars {
        if isSpace(pc) {
            pstart = true
            continue
        }
        var lefts = minScore
        for (si, sc) in str.enumerated() {
            let left = dp[si]
            lefts = max(lefts + gapScore, left)
            if caseSensitive ? pc == sc : lowercased(pc) == lowercased(sc) {
                let t = scores[si] * (pstart ? patternStartMultiplier : patternNonStartMultiplier)
                dp[si] = pfirst ? leadingGapScore * si + t : max(uleft + consecutiveScore, ulefts + t)
            } else {
                dp[si] = minScore
            }
            uleft = left
            ulefts = lefts
        }
        pfirst = false
        pstart = false
    }
    let lefts = dp.reduce(minScore) { max($0 + gapScore, $1) }
    return -lefts
}

/// `g_unichar_tolower`: only Lu and Lt change, to their single-code-point
/// lowercase (the first code point of a special-case mapping).
func lowercased(_ c: Unicode.Scalar) -> Unicode.Scalar {
    switch c.properties.generalCategory {
    case .uppercaseLetter, .titlecaseLetter: c.properties.lowercaseMapping.unicodeScalars.first ?? c
    default: c
    }
}

/// `g_unichar_isspace`: tab, newline, CR and form feed, plus Zs, Zl and Zp.
/// Vertical tab is not a space.
func isSpace(_ c: Unicode.Scalar) -> Bool {
    switch c {
    case "\t", "\n", "\r", "\u{0C}": return true
    default:
        switch c.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
