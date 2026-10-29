import Darwin

/// `-matching` named a method rofi does not know (source/helper.c:726-731).
public struct InvalidMatchingMethod: Error, Equatable, CustomStringConvertible {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public var description: String {
        "config.matching=\(name) is not a valid matching strategy.\n"
            + "Valid options are: glob, regex, fuzzy, prefix or normal."
    }
}

/// rofi's no-UI dmenu path, `rofi -dmenu -dump` (source/modes/dmenu.c:989-1034).
public struct DmenuDump: Sendable {
    public var format = "s"
    public var separator: UInt8 = 0x0A
    public var filter: String?
    public var match = MatchOptions()
    public var autoSelect = false
    /// `-only-match` or `-no-custom`.
    public var onlyMatch = false

    /// Reads the options from the command line (source/modes/dmenu.c:550-560,
    /// 605-608 and the config options in source/xrmoptions.c).
    public init(arguments args: Arguments) throws {
        format = args.string("-format") ?? format
        separator = args.char("-sep") ?? separator
        filter = args.string("-filter")
        if let matching = args.string("-matching") {
            match.method = try parseMatching(matching) ?? match.method
        }
        match.tokenize = args.bool("tokenize", default: match.tokenize)
        match.caseSmart = args.bool("case-smart", default: match.caseSmart)
        match.normalize = args.bool("normalize-match", default: match.normalize)
        // ponytail: a byte above 0x7F maps to its Latin-1 scalar, while rofi
        // compares it against the token's first raw byte.
        if let negate = args.char("-matching-negate-char") {
            match.negateChar = Character(Unicode.Scalar(negate))
        }
        // dmenu forces case sensitivity on unless `-i`, whatever
        // `-case-sensitive` said (source/modes/dmenu.c:605-608).
        match.caseSensitive = !args.has("-i")
        autoSelect = args.bool("auto-select", default: autoSelect)
        onlyMatch = args.has("-only-match") || args.has("-no-custom")
    }

    /// The output for `rows`, one `formatOutputLine` result (each ending in
    /// a newline) per printed row.
    public func dump(rows: [Row]) -> [String] {
        // `-only-match` with no rows prints nothing (dmenu.c:992-997); the
        // dump below already does, so no separate check is needed.
        if autoSelect && rows.count == 1 {
            return [formatOutputLine(format, entry: rows[0].text, index: 0, filter: filter)]
        }
        let matcher = Matcher(query: filter ?? "", options: match)
        return rows.indices
            .filter { matcher.matches(rows[$0].text) }
            .map { formatOutputLine(format, entry: rows[$0].text, index: $0, filter: filter) }
    }
}

/// `config.matching`: every comma-separated name must be valid (ASCII case
/// ignored); the first one is used (source/helper.c:695-731). `""` splits
/// into no names, which returns nil and keeps the default.
// ponytail: rofi also rejects five or more names ("to many matching options").
private func parseMatching(_ value: String) throws -> MatchingMethod? {
    let names = value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false)
    let methods = try names.map { name in
        guard let method = MatchingMethod(rawValue: name.lowercased()) else {
            throw InvalidMatchingMethod(name: String(name))
        }
        return method
    }
    return methods.first
}

/// Reads `fd` to the end and splits it into rows on `separator`.
// ponytail: a read error other than EINTR ends the input silently.
public func readRows(fileDescriptor fd: Int32, separator: UInt8) -> [Row] {
    var splitter = RowSplitter(separator: separator)
    var rows: [Row] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        rows += splitter.feed(buffer[..<count])
    }
    if let last = splitter.finish() { rows.append(last) }
    return rows
}
