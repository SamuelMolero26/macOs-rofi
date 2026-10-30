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

/// One visible dmenu match and its position in the original input.
public struct DmenuMatch: Equatable, Sendable {
    public let sourceIndex: Int
    public let row: Row

    public init(sourceIndex: Int, row: Row) {
        self.sourceIndex = sourceIndex
        self.row = row
    }
}

/// Shared dmenu configuration, matching and output projection.
public struct DmenuPipeline: Sendable {
    public var format = "s"
    public var separator: UInt8 = 0x0A
    public var filter: String?
    public var match = MatchOptions()
    public var autoSelect = false
    /// Disables custom input and keeps the session open on cancellation.
    public var onlyMatch = false
    /// Disables custom input but preserves normal cancellation.
    public var noCustom = false

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
        onlyMatch = args.has("-only-match")
        noCustom = args.has("-no-custom")
    }

    /// Matches row text while retaining each row's original input position.
    public func matchingRows(in rows: [Row], query: String) -> [DmenuMatch] {
        let matcher = Matcher(query: query, options: match)
        return rows.enumerated().compactMap { sourceIndex, row in
            matcher.matches(row.text) ? DmenuMatch(sourceIndex: sourceIndex, row: row) : nil
        }
    }

    /// Formats a match with its original input index and the supplied live
    /// filter. A nil filter is distinct from an interactive empty filter.
    public func formattedOutput(for match: DmenuMatch, filter: String?) -> String {
        formatOutputLine(
            format,
            entry: match.row.text,
            index: match.sourceIndex,
            filter: filter
        )
    }

    /// The no-UI `rofi -dmenu -dump` projection, one output line per match
    /// (source/modes/dmenu.c:989-1034).
    public func dump(rows: [Row]) -> [String] {
        if autoSelect && rows.count == 1 {
            return [formattedOutput(for: DmenuMatch(sourceIndex: 0, row: rows[0]), filter: filter)]
        }
        return matchingRows(in: rows, query: filter ?? "")
            .map { formattedOutput(for: $0, filter: filter) }
    }

}

/// Source compatibility for the first no-UI dmenu implementation.
public typealias DmenuDump = DmenuPipeline

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
