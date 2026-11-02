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

    public let pipeline: DmenuPipeline
    private var rows: [Row]

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
        return state
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
    public func accept() -> DmenuCompletion? {
        if let selectedVisibleIndex,
           matches.indices.contains(selectedVisibleIndex) {
            let match = matches[selectedVisibleIndex]
            guard !match.row.nonselectable else { return nil }
            return completion(for: match)
        }
        guard pipeline.allowsCustomInput else { return nil }
        return DmenuCompletion(output: pipeline.formattedCustomOutput(for: query), outcome: .accepted)
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

    private func completion(for match: DmenuMatch) -> DmenuCompletion {
        DmenuCompletion(
            output: pipeline.formattedOutput(for: match, filter: query),
            outcome: .accepted
        )
    }
}

fileprivate extension DmenuPipeline {
    func formattedCustomOutput(for query: String) -> String {
        formatOutputLine(format, entry: query, index: -1, filter: query)
    }
}
