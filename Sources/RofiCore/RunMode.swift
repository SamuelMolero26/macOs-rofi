import Foundation

/// One directory entry as `readdir` reports it (source/modes/run.c:313-327).
public struct PathEntry: Equatable, Sendable {
    /// `d_type`: DT_REG, DT_LNK, DT_UNKNOWN count; everything else does not.
    public enum Kind: Equatable, Sendable {
        case regular, symlink, unknown, other
    }

    public var name: String
    public var kind: Kind
    /// `g_file_test(G_FILE_TEST_IS_EXECUTABLE)` on the entry, following links.
    public var isExecutable: Bool

    public init(name: String, kind: Kind, isExecutable: Bool) {
        self.name = name
        self.kind = kind
        self.isExecutable = isExecutable
    }
}

/// Lists one `$PATH` directory, or nil when it cannot be opened.
public typealias DirectoryLister = (_ path: String) -> [PathEntry]?

/// `get_apps` without the history and external list (source/modes/run.c:
/// 245-415): the names found in `$PATH`, sorted by bytes with duplicates
/// removed. nil when `$PATH` is unset, which leaves the mode with no rows
/// (251-253).
///
/// Upstream tests the executable bit only for directories whose name starts
/// with the home directory (309, 321-327); every other regular file or link
/// is offered. That is kept as it is.
/// A leading `~` expands to `home`; other forms go through `expandPath`.
public func discoverExecutables(path: String?, home: String, list: DirectoryLister) -> [String]? {
    guard let path else { return nil }
    var names: Set<String> = []
    // strtok skips empty components (291-292).
    for component in path.split(separator: ":") {
        let directory = String(component)
        let expanded =
            directory == "~" || directory.hasPrefix("~/")
            ? home + directory.dropFirst() : expandPath(directory)
        guard let entries = list(expanded) else { continue }
        let checksExecutable = directory.hasPrefix(home)
        for entry in entries {
            guard entry.kind != .other, !entry.name.hasPrefix(".") else { continue }
            if checksExecutable && !entry.isExecutable { continue }
            names.insert(entry.name)
        }
    }
    // sort_func is g_strcmp0, a byte comparison (166-183).
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

/// The real `DirectoryLister`: `lstat` for the type, `access(X_OK)` for the
/// executable bit.
public func listDirectoryOnDisk(_ path: String) -> [PathEntry]? {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: path) else { return nil }
    return names.map { name in
        let full = path + "/" + name
        let kind: PathEntry.Kind
        switch (try? manager.attributesOfItem(atPath: full))?[.type] as? FileAttributeType {
        case .typeRegular: kind = .regular
        case .typeSymbolicLink: kind = .symlink
        case nil: kind = .unknown
        default: kind = .other
        }
        return PathEntry(name: name, kind: kind, isExecutable: manager.isExecutableFile(atPath: full))
    }
}

/// The `run` mode (source/modes/run.c): the commands found in `$PATH`, the
/// recently run ones first.
///
/// Discovery, the process launcher and the script writer are injected, so the
/// mode owns only ordering, history and the menu actions.
///
/// Accepting a row or typed text runs `-run-command`; the terminal action
/// (MENU_CUSTOM_ACTION, run.c:456) runs `-run-shell-command` through
/// `TerminalLaunch`. Neither goes through a shell: `{cmd}` is substituted and
/// the result is split with `g_shell_parse_argv` rules (helper.c:1451-1459,
/// 102-144), so typed `ls -la` and `echo "a b"` split as a shell would while
/// pipes, `$VAR` and globs stay literal. A row is shell-quoted first
/// (run.c:355), so a name with blanks stays one argument.
///
/// ponytail: `-run-list-command` (run.c:185-240, 375-377) and the file
/// completer (MENU_COMPLETE, run.c:462-492, 515-536) are not implemented.
public final class RunMode: Mode {
    public let name = "run"
    public private(set) var rows: [Row] = []

    /// `RunEntry` (run.c:66-75): the shown text and the command it runs.
    private struct Entry {
        var entry: String
        var exec: String
    }

    private var entries: [Entry] = [] {
        didSet { rows = entries.map { Row(parsing: $0.entry) } }
    }
    private let discover: () -> [String]?
    private let history: History?
    private let terminal: String?
    private let runCommand: String
    private let runShellCommand: String
    private let launcher: CommandLauncher
    private let writeScript: ScriptWriter
    /// The last failed launch, worded as upstream's error dialog
    /// (helper.c:1426-1434, 136-137); cleared by the next action.
    private var failure: String?

    /// `runCommand` and `runShellCommand` default as config/config.c:70,74;
    /// `terminal` is `-terminal`, nil when unset.
    public init(
        discover: @escaping () -> [String]?, history: History?, terminal: String?,
        runCommand: String = "{cmd}", runShellCommand: String = "{terminal} -e {cmd}",
        launcher: @escaping CommandLauncher, writeScript: @escaping ScriptWriter
    ) {
        self.discover = discover
        self.history = history
        self.terminal = terminal
        self.runCommand = runCommand
        self.runShellCommand = runShellCommand
        self.launcher = launcher
        self.writeScript = writeScript
        load()
    }

    public var message: String? { failure }

    /// `get_apps` (run.c:245-415) without the external list: history first in
    /// file order, then the PATH names not already in it.
    private func load() {
        guard let names = discover() else {
            entries = []
            return
        }
        // Each history line is `entry US exec`; a line with no US runs itself
        // (255-272).
        let recent = (history?.list() ?? []).map { line -> Entry in
            let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            return Entry(entry: String(parts[0]), exec: parts.count > 1 ? String(parts[1]) : String(parts[0]))
        }
        let known = Set(recent.map(\.entry))
        entries = recent + names.filter { !known.contains($0) }.map { Entry(entry: $0, exec: shellQuote($0)) }
    }

    /// `run_mode_result` (run.c:451-540) for the actions without a terminal.
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        result(action, runInTerminal: false, input: &input, selectedRow: selectedRow)
    }

    /// `run_in_term` is MENU_CUSTOM_ACTION (run.c:456). ponytail: `ModeSwitcher`
    /// drops that flag today (`MenuAction` has no case for it), so only callers
    /// of this method can reach the terminal path.
    public func result(
        _ action: MenuAction, runInTerminal: Bool, input: inout String?, selectedRow: Int?
    ) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            return .switchTo(key)
        case .ok:
            // No row leaves MODE_EXIT (451-453, 493).
            guard let index = selectedRow, entries.indices.contains(index) else { return .exit }
            let entry = entries[index]
            return execute(entry.exec, inTerminal: runInTerminal, original: entry.entry) ? .exit : .reload
        case .customInput:
            guard let text = input, !text.isEmpty else { return .exit }
            return execute(text, inTerminal: runInTerminal, original: text) ? .exit : .reload
        case .deleteEntry:
            // delete_entry (143-153), then the list is rebuilt (504-512).
            if let index = selectedRow, entries.indices.contains(index) {
                history?.remove(historyLine(entries[index].entry, entries[index].exec))
                load()
            }
            return .reload
        }
    }

    /// `exec_cmd` (run.c:104-140): run, then store the history line on success
    /// or drop it on failure.
    private func execute(_ command: String, inTerminal: Bool, original: String) -> Bool {
        let line = historyLine(original, command)
        switch launch(command, inTerminal: inTerminal) {
        case .success:
            record(line)
            return true
        case .failure(let message):
            failure = message.text
            history?.remove(line)
            return false
        }
    }

    /// `helper_execute_command_env` (helper.c:1448-1460): the template
    /// is `-run-shell-command` in a terminal, else `-run-command`.
    private func launch(_ command: String, inTerminal: Bool) -> Result<Void, FailureMessage> {
        do {
            let result: Result<Void, ApplicationLaunchFailure>
            if inTerminal {
                let plan = try TerminalLaunch.plan(
                    terminal: terminal, template: runShellCommand, values: ["cmd": command])
                result = TerminalLaunch.launch(plan, launcher: launcher, writeScript: writeScript)
            } else {
                // Not `TerminalLaunch.plan`: its Terminal.app detection looks for
                // `-e` in the argv and would misread a plain `sed -e ...`.
                let argv = try parseCommandTemplate(
                    runCommand, values: ["cmd": command, "terminal": terminal ?? TerminalLaunch.defaultTerminal])
                result = launcher(argv)
            }
            if case .failure(let error) = result { return .failure(FailureMessage(error.dialogText)) }
            return .success(())
        } catch let error as CommandTemplateError {
            return .failure(FailureMessage(error.message))
        } catch {
            return .failure(FailureMessage("\(error)"))
        }
    }

    private func historyLine(_ original: String, _ command: String) -> String {
        "\(original)\u{1F}\(command)"
    }

    /// `history_set` after a launch (run.c:129); the cache folder is created
    /// first, as `DrunMode` does.
    private func record(_ line: String) {
        guard let history else { return }
        try? FileManager.default.createDirectory(
            at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        history.set(line)
    }
}

/// A launch failure as dialog text.
private struct FailureMessage: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// `g_shell_quote`: single quotes, each embedded one as `'\''`.
private func shellQuote(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
