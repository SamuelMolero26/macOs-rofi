import Foundation

/// The `drun` mode (source/modes/drun.c): installed applications, most used
/// first, with Enter launching the selected application.
///
/// Discovery and launching sit behind application-specific dependencies. The
/// mode owns only row ordering, history, and menu actions.
public final class DrunMode: Mode {
    public let name = "drun"
    public private(set) var rows: [Row] = []

    private struct RankedApplication {
        let record: ApplicationRecord
        /// `sort_index`: rank from the end of history, 0 when absent
        /// (drun.c:889-910).
        var sortIndex = 0
    }

    private var applications: [RankedApplication] = [] {
        didSet { rows = applications.map { Row(parsing: $0.record.displayName) } }
    }
    private let history: History?
    private let launcher: ApplicationLauncher
    /// The last failed launch, worded as upstream's error dialog
    /// (helper.c:1428-1430); cleared by the next action.
    private var failure: String?

    /// Creates the mode from normalized application records. Duplicate
    /// identifiers keep the first record, preserving catalog precedence.
    public init(
        applications: [ApplicationRecord], history: History?,
        launcher: @escaping ApplicationLauncher
    ) {
        self.history = history
        self.launcher = launcher

        var seen: Set<String> = []
        var ranked = applications.compactMap { application -> RankedApplication? in
            guard seen.insert(application.identifier).inserted else { return nil }
            return RankedApplication(record: application)
        }

        // get_apps_history (drun.c:889-910).
        let recent = history?.list() ?? []
        for (index, identifier) in recent.enumerated() {
            for applicationIndex in ranked.indices
            where ranked[applicationIndex].record.identifier == identifier {
                ranked[applicationIndex].sortIndex = recent.count - index
            }
        }

        // drun_int_sort_list (drun.c:912-930): history first by rank, the rest
        // by name; g_qsort_with_data is stable.
        self.applications = ranked.enumerated()
            .sorted { first, second in
                if first.element.sortIndex != second.element.sortIndex {
                    return first.element.sortIndex > second.element.sortIndex
                }
                switch first.element.record.displayName.localizedCompare(
                    second.element.record.displayName)
                {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return first.offset < second.offset
                }
            }
            .map(\.element)
        // didSet does not run inside init.
        rows = self.applications.map { Row(parsing: $0.record.displayName) }
    }

    public var message: String? { failure }

    /// `_get_icon` (drun.c:1557-1580): the catalog supplies the icon identity.
    public func iconPath(at row: Int) -> String? {
        applications.indices.contains(row) ? applications[row].record.iconPath : nil
    }

    /// `drun_mode_result` (drun.c:1360-1449).
    public func result(
        _ action: MenuAction, input: inout String?, selectedRow: Int?
    ) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            return .switchTo(key)
        case .ok:
            guard let index = selectedRow, applications.indices.contains(index) else {
                return .reload
            }
            let application = applications[index].record
            if case .failure(let error) = launcher(application) {
                failure = error.dialogText
                return .reload
            }
            record(application.identifier)
            return .exit
        case .customInput:
            guard let input, !input.isEmpty else { return .exit }
            failure =
                ApplicationLaunchFailure(
                    command: input, reason: "drun cannot run typed commands"
                ).dialogText
            return .reload
        case .deleteEntry:
            if let index = selectedRow, applications.indices.contains(index),
                applications[index].sortIndex > 0
            {
                history?.remove(applications[index].record.identifier)
                applications.remove(at: index)
            }
            return .reload
        }
    }

    /// `history_set` on the application identifier after a successful launch
    /// (drun.c:476-481). The cache folder is created first.
    private func record(_ identifier: String) {
        guard let history else { return }
        try? FileManager.default.createDirectory(
            at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        history.set(identifier)
    }
}
