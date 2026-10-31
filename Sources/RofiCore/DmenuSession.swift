/// The terminal result of a dmenu interaction.
public struct DmenuCompletion: Equatable, Sendable {
    public let output: String?
    public let outcome: DmenuOutcome

    public init(output: String?, outcome: DmenuOutcome) {
        self.output = output
        self.outcome = outcome
    }
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

    private let pipeline: DmenuPipeline
    private let rows: [Row]

    fileprivate init(pipeline: DmenuPipeline, rows: [Row], query: String) {
        self.pipeline = pipeline
        self.rows = rows
        self.query = query
        matches = pipeline.matchingRows(in: rows, query: query)
        selectedVisibleIndex = matches.isEmpty ? nil : 0
    }

    public mutating func updateQuery(_ query: String) -> DmenuCompletion? {
        self.query = query
        matches = pipeline.matchingRows(in: rows, query: query)
        selectedVisibleIndex = matches.isEmpty ? nil : 0
        return autoSelectCompletion()
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

    /// A selectable row wins over custom input. Otherwise the live query is
    /// accepted as custom input when policy allows it (source/modes/dmenu.c:780-891).
    public func accept() -> DmenuCompletion? {
        if let selectedVisibleIndex,
           matches.indices.contains(selectedVisibleIndex) {
            let match = matches[selectedVisibleIndex]
            if !match.row.nonselectable {
                return completion(for: match)
            }
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

    fileprivate func autoSelectCompletion() -> DmenuCompletion? {
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

public extension DmenuPipeline {
    /// Applies dmenu's immediate shortcuts or creates pure interactive state.
    func start(rows: [Row]) -> DmenuStart {
        if autoSelect && rows.count == 1 {
            let match = DmenuMatch(sourceIndex: 0, row: rows[0])
            return .completed(DmenuCompletion(output: formattedOutput(for: match, filter: filter), outcome: .accepted))
        }
        if !allowsCustomInput && rows.isEmpty {
            return .completed(DmenuCompletion(output: nil, outcome: .accepted))
        }
        let session = DmenuSession(pipeline: self, rows: rows, query: filter ?? "")
        if let completion = session.autoSelectCompletion() {
            return .completed(completion)
        }
        return .session(session)
    }
}

fileprivate extension DmenuPipeline {
    var allowsCustomInput: Bool { !onlyMatch && !noCustom }

    func formattedCustomOutput(for query: String) -> String {
        formatOutputLine(format, entry: query, index: -1, filter: query)
    }
}
