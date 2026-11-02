import Foundation

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
    /// Rows arrive while the panel is open instead of being read up front.
    public var isAsync = true

    /// `-only-match` and `-no-custom` both disable custom input
    /// (source/modes/dmenu.c:605-608).
    var allowsCustomInput: Bool { !onlyMatch && !noCustom }

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
        // These only work in sync mode (source/modes/dmenu.c:536-542).
        isAsync = !autoSelect && !["-sync", "-dump", "-select", "-no-custom", "-only-match", "-selected-row"]
            .contains(where: args.has)
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

    /// dmenu's pre-UI shortcuts, resolved before any dialog exists
    /// (source/modes/dmenu.c:988-998). `-only-match`/`-no-custom` end an empty
    /// run silently; `-auto-select` prints a single row whatever the filter
    /// says. `-dump` and the interactive path share this resolution.
    public func shortcut(rows: [Row]) -> DmenuCompletion? {
        if !allowsCustomInput && rows.isEmpty {
            return DmenuCompletion(output: nil, outcome: .accepted)
        }
        if autoSelect && rows.count == 1 {
            let match = DmenuMatch(sourceIndex: 0, row: rows[0])
            return DmenuCompletion(output: formattedOutput(for: match, filter: filter), outcome: .accepted)
        }
        return nil
    }

    /// The no-UI `rofi -dmenu -dump` projection, one output line per match
    /// (source/modes/dmenu.c:989-1034). Command-line shortcuts resolve first,
    /// exactly as they do for the interactive path.
    public func dump(rows: [Row]) -> [String] {
        if let completion = shortcut(rows: rows) {
            return completion.output.map { [$0] } ?? []
        }
        return matchingRows(in: rows, query: filter ?? "")
            .map { formattedOutput(for: $0, filter: filter) }
    }

    /// Applies dmenu's immediate shortcuts or creates pure interactive state.
    public func start(rows: [Row]) -> DmenuStart {
        if let completion = shortcut(rows: rows) { return .completed(completion) }
        let session = DmenuSession(pipeline: self, rows: rows, query: filter ?? "")
        if let completion = session.autoSelectCompletion() { return .completed(completion) }
        return .session(session)
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
public func readRows(fileDescriptor fd: Int32, separator: UInt8) -> [Row] {
    var rows: [Row] = []
    readRowBatches(fileDescriptor: fd, separator: separator) { rows += $0 }
    return rows
}

/// Opens and reads the input on a background thread, calling `onRows` from it
/// with each non-empty batch, then `onEnd` once at end of input. Returns
/// without waiting for `open`, which blocks on a FIFO with no writer.
// ponytail: a partial line waits for its separator or EOF; rofi flushes it
// after 250 ms (source/modes/dmenu.c:275), which splits slow lines.
public func streamRows(
    open: @escaping @Sendable () -> Int32,
    separator: UInt8,
    onRows: @escaping @Sendable ([Row]) -> Void,
    onEnd: @escaping @Sendable () -> Void
) {
    Thread.detachNewThread {
        readRowBatches(fileDescriptor: open(), separator: separator, onRows)
        onEnd()
    }
}

/// The read loop behind `readRows` and `streamRows`: hands over each read's
/// completed rows, then the unterminated remainder at end of input.
// ponytail: a read error other than EINTR ends the input silently.
func readRowBatches(fileDescriptor fd: Int32, separator: UInt8, _ onRows: ([Row]) -> Void) {
    var splitter = RowSplitter(separator: separator)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        let rows = splitter.feed(buffer[..<count])
        if !rows.isEmpty { onRows(rows) }
    }
    if let last = splitter.finish() { onRows([last]) }
}
