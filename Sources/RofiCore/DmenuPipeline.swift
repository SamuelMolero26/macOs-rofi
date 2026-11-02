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

/// `-matching` enabled the fifth recognized method (source/helper.c:709-715).
public struct TooManyMatchingMethods: Error, Equatable, CustomStringConvertible {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var description: String {
        "config.matching=\(value) to many matching options enabled."
    }
}

/// Which end of a row too long to fit gives way to an ellipsis.
public enum EllipsizeMode: Equatable, Sendable {
    case start, middle, end
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
    /// Upstream's `display_name`: one string names both the prompt and the
    /// window, so `-p` and `-window-title` each change both.
    public var prompt = "dmenu"
    /// `-mesg`: always Pango markup (source/view.c:1760-1762).
    public var message: String?
    /// Visible result rows, or nil to keep the default panel size.
    public var lines: Int?
    /// `-b`: bottom center, not dmenu's full-width bar.
    public var atBottom = false
    /// `-selected-row`: the source row selected at start, or nil for the first
    /// visible row.
    public var selectedRow: Int?
    /// `-select`: a query whose first matching row is selected at start.
    public var select: String?
    /// `-a`: rows drawn as active.
    public var activeRows: [RowRange] = []
    /// `-u`: rows drawn as urgent.
    public var urgentRows: [RowRange] = []
    /// `-multi-select`: Shift+Return toggles rows, and accepting prints them all.
    public var multiSelect = false
    /// Prefixes for toggled and untoggled rows under `-multi-select`.
    public var ballotSelected = "☑ "
    public var ballotUnselected = "☐ "
    /// `-display-columns`: 1-based pieces of the display source to show, or
    /// nil to show it whole.
    public var displayColumns: [String]?
    /// `-display-column-separator`: the case-insensitive regex that splits the
    /// display source into columns.
    public var displayColumnSeparator = "\t"
    /// `-markup-rows`: rows are Pango markup, drawn styled and matched on
    /// their text.
    public var markupRows = false
    /// `-password`: the query is masked.
    public var password = false
    /// Where long rows are cut (source/widgets/listview.c:804).
    public var ellipsizeMode = EllipsizeMode.end

    /// The window title around `prompt` (source/view.c:1892-1894).
    public var windowTitle: String { "rofi - \(prompt)" }

    /// Rows the panel is sized around, or nil for the default panel. A message
    /// adds to the window, so it must not take from the default rows
    /// (source/xcb/view.c:896-897).
    public var fixedRows: Int? {
        lines ?? (message == nil ? nil : Int(defaultMenuLines))
    }

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
        // `-p` is read last, so it wins (source/modes/dmenu.c:591-595, 1035).
        prompt = args.string("-p") ?? args.string("-window-title") ?? prompt
        message = args.string("-mesg")
        // The default overrides nothing, so it counts as unset, and the theme
        // value is a signed int (source/modes/dmenu.c:575-590). A negative
        // height is meaningless here, so it shows no rows like `-l 0`.
        if let value = args.uint("-l"), value != defaultMenuLines {
            lines = max(0, Int(Int32(truncatingIfNeeded: value)))
        }
        atBottom = args.has("-b")
        // UINT32_MAX is upstream's "no row" default, so a value that wraps to
        // it selects nothing (source/modes/dmenu.c:548, 555).
        if let row = args.uint("-selected-row"), row != UInt32.max {
            selectedRow = Int(row)
        }
        select = args.string("-select")
        // Contract: source/modes/dmenu.c:561-572.
        activeRows = args.string("-a").map(parseRowRanges) ?? []
        urgentRows = args.string("-u").map(parseRowRanges) ?? []
        // Contract: source/modes/dmenu.c:543-545 and 981-984.
        multiSelect = args.has("-multi-select")
        ballotSelected = args.string("-ballot-selected-str") ?? ballotSelected
        ballotUnselected = args.string("-ballot-unselected-str") ?? ballotUnselected
        // The separator is only read with columns (source/modes/dmenu.c:659-664).
        // g_strsplit splits "" into no items.
        if let columns = args.string("-display-columns") {
            displayColumns = columns.isEmpty ? [] : columns.components(separatedBy: ",")
            displayColumnSeparator = args.string("-display-column-separator") ?? displayColumnSeparator
        }
        markupRows = args.has("-markup-rows")
        password = args.has("-password")
        // `-ellipsize-mode` is applied after `-keep-right`, and an unknown mode
        // keeps the previous one (source/modes/dmenu.c:1039-1055).
        // ponytail: rofi g_warning()s an unknown mode; it is dropped here.
        if args.has("-keep-right") { ellipsizeMode = .start }
        switch args.string("-ellipsize-mode")?.lowercased() {
        case "start": ellipsizeMode = .start
        case "middle": ellipsizeMode = .middle
        case "end": ellipsizeMode = .end
        default: break
        }
    }

    /// How a row is shown, before any ballot: its `display` extra or else its
    /// text, projected onto `-display-columns`. A list position after the
    /// first is joined by a tab even when the one before it was out of range
    /// (source/modes/dmenu.c:365-411).
    public func displayString(for row: Row) -> String {
        let source = row.display ?? row.text
        guard let displayColumns else { return source }
        let pieces = splitColumns(source, separator: displayColumnSeparator)
        var result = ""
        for (i, item) in displayColumns.enumerated() {
            // `(unsigned int)g_ascii_strtoull(item, NULL, 10)`.
            let index = Int(UInt32(truncatingIfNeeded: strtoull(item, nil, 10)))
            guard index > 0 && index <= pieces.count else { continue }
            if i > 0 { result += "\t" }
            result += pieces[index - 1]
        }
        return result
    }

    /// The source row selected when the dialog opens: the first row matching
    /// `-select` with the configured matching, else `-selected-row`
    /// (source/modes/dmenu.c:1005-1017). Both force sync input, so `rows` is
    /// the whole input.
    public func initialSelection(in rows: [Row]) -> Int? {
        if let select {
            let matcher = Matcher(query: select, options: match)
            if let row = rows.firstIndex(where: { matcher.matches($0.text) }) {
                return row
            }
        }
        return selectedRow
    }

    /// Interactive matching, retaining each row's original input position.
    /// Under `-markup-rows` a row matches on its markup's text, and a row
    /// whose markup is invalid never matches (source/modes/dmenu.c:668-708).
    public func matchingRows(in rows: [Row], query: String) -> [DmenuMatch] {
        matchingRows(in: rows, query: query, text: markupRows ? { stripPangoMarkup($0.text) } : \.text)
    }

    private func matchingRows(in rows: [Row], query: String, text: (Row) -> String?) -> [DmenuMatch] {
        let matcher = Matcher(query: query, options: match)
        return rows.enumerated().compactMap { sourceIndex, row in
            guard let text = text(row), matcher.matches(text) else { return nil }
            return DmenuMatch(sourceIndex: sourceIndex, row: row)
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
    /// exactly as they do for the interactive path. Rows match on their raw
    /// text, even under `-markup-rows`.
    public func dump(rows: [Row]) -> [String] {
        if let completion = shortcut(rows: rows) {
            return completion.output.map { [$0] } ?? []
        }
        return matchingRows(in: rows, query: filter ?? "", text: \.text)
            .map { formattedOutput(for: $0, filter: filter) }
    }

    /// Applies dmenu's immediate shortcuts or creates pure interactive state.
    public func start(rows: [Row]) -> DmenuStart {
        if let completion = shortcut(rows: rows) { return .completed(completion) }
        let session = DmenuSession(
            pipeline: self,
            rows: rows,
            query: filter ?? "",
            selectedRow: initialSelection(in: rows)
        )
        if let completion = session.autoSelectCompletion() { return .completed(completion) }
        return .session(session)
    }

}

/// Source compatibility for the first no-UI dmenu implementation.
public typealias DmenuDump = DmenuPipeline

/// `DEFAULT_MENU_LINES` (include/settings.h:231).
private let defaultMenuLines: UInt32 = 15

/// `config.matching`: every comma-separated name must be valid (ASCII case
/// ignored); the first one is used (source/helper.c:695-731). `""` splits
/// into no names, which returns nil and keeps the default.
private func parseMatching(_ value: String) throws -> MatchingMethod? {
    let names = value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false)
    var firstMethod: MatchingMethod?
    var recognizedCount = 0
    for name in names {
        guard let method = MatchingMethod(rawValue: name.lowercased()) else {
            throw InvalidMatchingMethod(name: String(name))
        }
        firstMethod = firstMethod ?? method
        recognizedCount += 1
        if recognizedCount == 5 {
            throw TooManyMatchingMethods(value: value)
        }
    }
    return firstMethod
}

/// `g_regex_split_simple(separator, string, G_REGEX_CASELESS, 0)`: empty pieces
/// and capture groups are kept, an empty match splits between characters, ""
/// splits into nothing, and an invalid pattern yields no pieces.
// ponytail: ICU regex syntax stands in for PCRE, and an unmatched capture
// group gives "" even after the last matched one, which GLib omits.
private func splitColumns(_ string: String, separator: String) -> [String] {
    guard !string.isEmpty,
          let regex = try? NSRegularExpression(pattern: separator, options: .caseInsensitive) else { return [] }
    let text = string as NSString
    var pieces: [String] = []
    var pieceStart = 0
    var lastMatchWasEmpty = false
    for match in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
        let range = match.range
        // An empty match where the last piece ended splits nothing.
        if range.length == 0 && range.location == pieceStart { continue }
        pieces.append(text.substring(with: NSRange(location: pieceStart, length: range.location - pieceStart)))
        for group in 1..<match.numberOfRanges {
            let groupRange = match.range(at: group)
            pieces.append(groupRange.location == NSNotFound ? "" : text.substring(with: groupRange))
        }
        pieceStart = NSMaxRange(range)
        lastMatchWasEmpty = range.length == 0
    }
    // An empty match at the very end leaves no trailing piece.
    if !(lastMatchWasEmpty && pieceStart == text.length) {
        pieces.append(text.substring(from: pieceStart))
    }
    return pieces
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
