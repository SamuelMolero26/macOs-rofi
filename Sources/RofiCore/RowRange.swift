/// A row range from `-u`, `-a` or the script `urgent`/`active` headers.
/// Both ends are inclusive; negative values count from the end, so -1 is the
/// last row. Parsing mirrors rofi's `parse_pair` (source/helper.c:1620-1652).
public struct RowRange: Equatable, Sendable {
    public var start: Int
    public var stop: Int

    public init(start: Int, stop: Int) {
        self.start = start
        self.stop = stop
    }

    /// Mirrors rofi's `get_index` and membership check
    /// (source/modes/dmenu.c:413-455): an end that is out of range becomes
    /// UINT_MAX, so a bad start matches nothing and a bad stop matches every
    /// row from start onward.
    public func contains(_ index: Int, rowCount: Int) -> Bool {
        guard let first = resolve(start, rowCount) else { return false }
        guard let last = resolve(stop, rowCount) else { return index >= first }
        return index >= first && index <= last
    }
}

/// Parses a comma-separated range list such as `0,2-4,-2:` (rofi's
/// `parse_ranges`, source/helper.c:1653-1670). Empty tokens are skipped.
public func parseRowRanges(_ input: String) -> [RowRange] {
    input.split(separator: ",").map(parsePair)
}

private func parsePair(_ token: Substring) -> RowRange {
    let text = token.drop { $0 == " " || $0 == "\t" }
    // A colon, or a leading minus, selects Python-style `a:b` with exclusive end.
    let pythonic = text.contains(":") || text.first == "-"
    let parts = text.split(separator: pythonic ? ":" : "-", omittingEmptySubsequences: false)
    var range = RowRange(start: strtol10(parts[0]), stop: strtol10(parts[0]))
    for part in parts.dropFirst() {
        if part.isEmpty {
            // An empty end means "last row" and is never decremented.
            range.stop = -1
            continue
        }
        range.stop = strtol10(part) - (pythonic ? 1 : 0)
    }
    return range
}

private func resolve(_ index: Int, _ rowCount: Int) -> Int? {
    if index >= 0 { return index }
    return -index <= rowCount ? rowCount + index : nil
}

/// `strtol(s, NULL, 10)`: leading whitespace, optional sign, digits, else 0.
// ponytail: overflow returns 0 instead of strtol's LONG_MAX clamp.
private func strtol10(_ s: Substring) -> Int {
    var rest = s.drop(while: \.isWhitespace)
    var sign = 1
    if let c = rest.first, c == "-" || c == "+" {
        sign = c == "-" ? -1 : 1
        rest = rest.dropFirst()
    }
    return sign * (Int(rest.prefix { ("0"..."9").contains($0) }) ?? 0)
}
