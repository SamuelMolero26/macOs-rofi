/// The terminal result of a dmenu interaction.
public struct DmenuCompletion: Equatable, Sendable {
    public let output: String?
    public let outcome: DmenuOutcome

    public init(output: String?, outcome: DmenuOutcome) {
        self.output = output
        self.outcome = outcome
    }
}

/// The display state flags of one row, with upstream's values
/// (include/widgets/textbox.h:103-112). Styling them is left to the UI.
public struct DmenuRowState: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let urgent = DmenuRowState(rawValue: 1)
    public static let active = DmenuRowState(rawValue: 2)
    /// Toggled under `-multi-select`, not the highlighted row.
    public static let selected = DmenuRowState(rawValue: 4)
}

/// A dmenu run either completes through a command-line shortcut or needs an
/// interactive session.
public enum DmenuStart: Sendable {
    case completed(DmenuCompletion)
    case session(DmenuSession)
}

/// Pure interactive dmenu state. Query changes reuse the pipeline's configured
/// matching method and always select the first visible result.
public struct DmenuSession: Sendable {
    public private(set) var query: String
    public private(set) var matches: [DmenuMatch]
    public private(set) var selectedVisibleIndex: Int?
    /// The `-multi-select` count shown in place of the loading overlay, or nil
    /// when no row is toggled (source/modes/dmenu.c:936-943).
    public private(set) var selectionOverlay: String?

    public let pipeline: DmenuPipeline
    private var rows: [Row]
    /// Source indices toggled under `-multi-select`, upstream's selected_list.
    private var toggledRows: Set<Int> = []

    /// Selects the visible position of `selectedRow`, or the first visible row
    /// when it is nil, filtered out or out of range (source/view.c:369-383).
    init(pipeline: DmenuPipeline, rows: [Row], query: String, selectedRow: Int? = nil) {
        self.pipeline = pipeline
        self.rows = rows
        self.query = query
        matches = pipeline.matchingRows(in: rows, query: query)
        let visible = matches.firstIndex { $0.sourceIndex == selectedRow }
        selectedVisibleIndex = visible ?? (matches.isEmpty ? nil : 0)
    }

    /// How a visible row is drawn: `-a`/`-u` ranges resolved against the rows
    /// loaded so far, ORed with the row's own extras
    /// (source/modes/dmenu.c:436-466).
    public func state(of match: DmenuMatch) -> DmenuRowState {
        var state: DmenuRowState = []
        let index = match.sourceIndex
        if match.row.active || pipeline.activeRows.contains(where: { $0.contains(index, rowCount: rows.count) }) {
            state.insert(.active)
        }
        if match.row.urgent || pipeline.urgentRows.contains(where: { $0.contains(index, rowCount: rows.count) }) {
            state.insert(.urgent)
        }
        if toggledRows.contains(index) {
            state.insert(.selected)
        }
        return state
    }

    /// The row's display string, behind its ballot under `-multi-select`
    /// (source/modes/dmenu.c:365-411, 467-477).
    public func displayText(for match: DmenuMatch) -> String {
        let text = pipeline.displayString(for: match.row)
        guard pipeline.multiSelect else { return text }
        let ballot = toggledRows.contains(match.sourceIndex) ? pipeline.ballotSelected : pipeline.ballotUnselected
        return ballot + text
    }

    public mutating func updateQuery(_ query: String) -> DmenuCompletion? {
        self.query = query
        matches = pipeline.matchingRows(in: rows, query: query)
        selectedVisibleIndex = matches.isEmpty ? nil : 0
        return autoSelectCompletion()
    }

    /// Adds rows that arrived after the session started. New matches go last,
    /// so visible indices and the selection stay valid.
    public mutating func appendRows(_ newRows: [Row]) {
        let offset = rows.count
        rows += newRows
        matches += pipeline.matchingRows(in: newRows, query: query).map {
            DmenuMatch(sourceIndex: offset + $0.sourceIndex, row: $0.row)
        }
        if selectedVisibleIndex == nil && !matches.isEmpty {
            selectedVisibleIndex = 0
        }
    }

    public mutating func selectVisibleIndex(_ index: Int?) {
        guard let index else {
            selectedVisibleIndex = nil
            return
        }
        selectedVisibleIndex = matches.indices.contains(index) ? index : nil
    }

    public mutating func moveSelection(by offset: Int) {
        guard let current = selectedVisibleIndex, !matches.isEmpty else { return }
        if offset > matches.index(before: matches.endIndex) - current {
            selectedVisibleIndex = matches.index(before: matches.endIndex)
        } else if offset < -current {
            selectedVisibleIndex = matches.startIndex
        } else {
            selectedVisibleIndex = current + offset
        }
    }

    /// A valid selection wins over custom input, but a nonselectable row rejects
    /// acceptance. With no valid selection, the live query can be custom input.
    /// Toggled rows replace either output (source/modes/dmenu.c:880-892, 910-952).
    public func accept() -> DmenuCompletion? {
        if let match = highlightedMatch {
            guard !match.row.nonselectable else { return nil }
            return completion(for: match)
        }
        guard pipeline.allowsCustomInput else { return nil }
        return completion(for: nil)
    }

    /// kb-accept-alt, Shift+Return (source/keyb.c:127-130, source/view.c:1280-1293).
    /// Under `-multi-select` it toggles the highlighted row and moves to the
    /// next visible one, keeping the session open; otherwise it accepts like
    /// Return. Normal mode refuses a nonselectable row first, but the
    /// `-no-custom`/`-only-match` branch toggles before that check
    /// (source/modes/dmenu.c:853-879, 913-943).
    public mutating func acceptAlternate() -> DmenuCompletion? {
        guard pipeline.multiSelect, let match = highlightedMatch, let current = selectedVisibleIndex else {
            return accept()
        }
        if pipeline.allowsCustomInput && match.row.nonselectable { return nil }
        if toggledRows.remove(match.sourceIndex) == nil {
            toggledRows.insert(match.sourceIndex)
        }
        selectedVisibleIndex = min(current + 1, matches.count - 1)
        selectionOverlay = toggledRows.isEmpty ? nil : "\(toggledRows.count)/\(rows.count)"
        return nil
    }

    /// `-only-match` restarts the dialog instead of closing it; nil tells the
    /// UI to keep this session open (source/modes/dmenu.c:880-891).
    public func cancel() -> DmenuCompletion? {
        guard !pipeline.onlyMatch else { return nil }
        return DmenuCompletion(output: nil, outcome: .cancelled)
    }

    func autoSelectCompletion() -> DmenuCompletion? {
        guard pipeline.autoSelect, matches.count == 1 else { return nil }
        return completion(for: matches[0])
    }

    private var highlightedMatch: DmenuMatch? {
        guard let selectedVisibleIndex, matches.indices.contains(selectedVisibleIndex) else { return nil }
        return matches[selectedVisibleIndex]
    }

    /// `dmenu_print_results`: every toggled row in input order, else the
    /// highlighted row, else the query as custom input
    /// (source/modes/dmenu.c:808-826).
    private func completion(for match: DmenuMatch?) -> DmenuCompletion {
        let output: String
        if !toggledRows.isEmpty {
            output = toggledRows.sorted().map { index in
                pipeline.formattedOutput(for: DmenuMatch(sourceIndex: index, row: rows[index]), filter: query)
            }.joined()
        } else if let match {
            output = pipeline.formattedOutput(for: match, filter: query)
        } else {
            output = pipeline.formattedCustomOutput(for: query)
        }
        return DmenuCompletion(output: output, outcome: .accepted)
    }
}

extension DmenuPipeline {
    fileprivate func formattedCustomOutput(for query: String) -> String {
        formatOutputLine(format, entry: query, index: -1, filter: query)
    }
}
