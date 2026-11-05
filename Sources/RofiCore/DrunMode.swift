import Foundation

/// What drun reads from a bundle's `Contents/Info.plist`, standing in for a
/// .desktop file's keys (source/modes/drun.c:502-816, Name at 730).
public struct AppBundleInfo: Equatable, Sendable {
    /// `CFBundleIdentifier`: the desktop id (drun.c:512-517).
    public var identifier: String?
    /// `CFBundleDisplayName`.
    public var displayName: String?
    /// `CFBundleName`.
    public var name: String?

    public init(identifier: String? = nil, displayName: String? = nil, name: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.name = name
    }
}

/// The application folders as `DrunMode` sees them, so the mode can run on a
/// fake.
public protocol AppBundleSource {
    /// The entries of `path`, links resolved, or nil when it cannot be opened
    /// (drun.c:823-827).
    func entries(in path: String) -> [FileBrowserEntry]?
    /// The bundle's Info.plist values; empty when it has none.
    func info(ofBundle path: String) -> AppBundleInfo
}

extension DiskFileSystem: AppBundleSource {
    /// ponytail: Info.plist only; names localized in InfoPlist.strings are
    /// not read, so a localized system shows the bundle's own names.
    public func info(ofBundle path: String) -> AppBundleInfo {
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        func value(_ key: String) -> String? { plist?[key] as? String }
        return AppBundleInfo(
            identifier: value("CFBundleIdentifier"), displayName: value("CFBundleDisplayName"),
            name: value("CFBundleName"))
    }
}

/// The `drun` mode (source/modes/drun.c): the installed applications, most
/// used first, Enter launches one.
///
/// `.app` bundles take the place of .desktop files and `open` the place of
/// the Exec line.
/// ponytail: no actions, generic names, categories, keywords or
/// `drun-match-fields` / `drun-display-format` (only the name is shown and
/// matched), no entry cache (drun.c:933-1185), no completer for file
/// arguments (1366-1388, 1426-1446), no `max-history-size` flag.
public final class DrunMode: Mode {
    public let name = "drun"
    public private(set) var rows: [Row] = []

    /// The folders searched, in order; earlier ones win a duplicate bundle id.
    public static func applicationDirectories(home: String) -> [String] {
        [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", home + "/Applications",
        ]
    }

    private struct App {
        var id: String
        var name: String
        var path: String
        /// `sort_index`: its rank from the end of the history, 0 when not in
        /// it (drun.c:889-910).
        var sortIndex = 0
    }

    private var apps: [App] = [] {
        didSet { rows = apps.map { Row(parsing: $0.name) } }
    }
    private let history: History?
    private let opener: FileBrowserOpener
    /// The last failed launch, worded as upstream's error dialog
    /// (helper.c:1428-1430); cleared by the next action.
    private var failure: String?

    /// `get_apps` (drun.c:1186-1251): walk the folders, rank by the
    /// history, sort. A nil `history` keeps none, as `disable-history`.
    public init(
        home: String, history: History?, directories: [String]? = nil,
        source: any AppBundleSource = DiskFileSystem(),
        opener: @escaping FileBrowserOpener = openWithSystemOpener
    ) {
        self.history = history
        self.opener = opener
        var found: [App] = []
        var seen: Set<String> = []
        for directory in directories ?? Self.applicationDirectories(home: home) {
            Self.walk(directory, source: source, into: &found, seen: &seen)
        }
        // get_apps_history (drun.c:889-910).
        let recent = history?.list() ?? []
        for (index, id) in recent.enumerated() {
            for i in found.indices where found[i].id == id { found[i].sortIndex = recent.count - index }
        }
        // drun_int_sort_list (drun.c:912-930): history first by rank, the rest
        // by name; g_qsort_with_data is stable.
        apps = found.enumerated()
            .sorted { a, b in
                if a.element.sortIndex != b.element.sortIndex { return a.element.sortIndex > b.element.sortIndex }
                switch a.element.name.localizedCompare(b.element.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.offset < b.offset
                }
            }
            .map(\.element)
        // didSet does not run inside init.
        rows = apps.map { Row(parsing: $0.name) }
    }

    public var message: String? { failure }

    /// `_get_icon` (drun.c:1557-1580): the bundle's own icon stands in for
    /// the desktop file's Icon key (drun.c:790).
    public func iconPath(at row: Int) -> String? {
        apps.indices.contains(row) ? apps[row].path : nil
    }

    /// `drun_mode_result` (drun.c:1360-1449).
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            // drun.c:1424-1425.
            return .switchTo(key)
        case .ok:
            guard let index = selectedRow, apps.indices.contains(index) else { return .reload }
            let app = apps[index]
            // exec_cmd_entry (drun.c:1390-1397, 351-484) exits even when the
            // launch fails; as in the file browser the failure is the message
            // and the view stays open. Upstream runs from rofi's directory.
            if case .failure(let error) = opener(app.path, FileManager.default.currentDirectoryPath) {
                failure = error.dialogText
                return .reload
            }
            record(app.id)
            return .exit
        case .customInput:
            // No text leaves MODE_EXIT (drun.c:1363, 1402-1403).
            guard let input, !input.isEmpty else { return .exit }
            // ponytail: upstream runs the typed text as a command
            // (drun.c:1402-1410); here it is refused with a message so a
            // mistyped app name does not vanish silently.
            failure = FileBrowserOpenFailure(command: input, reason: "drun cannot run typed commands").dialogText
            return .reload
        case .deleteEntry:
            // drun.c:1411-1423: only an entry in the history is removed, from
            // the history and the list. Upstream's `sort_index >= 0` test
            // also catches the first entry read; that quirk is not kept.
            if let index = selectedRow, apps.indices.contains(index), apps[index].sortIndex > 0 {
                history?.remove(apps[index].id)
                apps.remove(at: index)
            }
            return .reload
        }
    }

    /// `history_set` on the desktop id after a launch (drun.c:476-481). The
    /// cache folder is created first; upstream assumes it exists.
    private func record(_ id: String) {
        guard let history else { return }
        try? FileManager.default.createDirectory(
            at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        history.set(id)
    }

    /// `walk_dir` (drun.c:818-877): hidden names are skipped and plain
    /// folders are walked; an `.app` folder is an entry and is never walked.
    /// A bundle id already seen is skipped (drun.c:519-523); a bundle without
    /// one is known by its path.
    /// ponytail: a linked folder is not walked, so a link loop cannot hang the
    /// scan; a linked bundle is still listed.
    private static func walk(
        _ directory: String, source: any AppBundleSource, into found: inout [App], seen: inout Set<String>
    ) {
        guard let entries = source.entries(in: directory) else { return }
        for entry in entries where entry.kind == .directory && !entry.name.hasPrefix(".") {
            let path = directory + "/" + entry.name
            guard entry.name.lowercased().hasSuffix(".app") else {
                if !entry.isLink { walk(path, source: source, into: &found, seen: &seen) }
                continue
            }
            let info = source.info(ofBundle: path)
            let id = nonEmpty(info.identifier) ?? path
            guard seen.insert(id).inserted else { continue }
            let name = nonEmpty(info.displayName) ?? nonEmpty(info.name) ?? String(entry.name.dropLast(4))
            found.append(App(id: id, name: name, path: path))
        }
    }
}

private func nonEmpty(_ value: String?) -> String? {
    value?.isEmpty == false ? value : nil
}
