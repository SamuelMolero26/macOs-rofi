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

/// Runs `argv` and returns its stdout lines (`execute_generator`,
/// source/helper.c:562-583), or why it could not.
public typealias ListGenerator = (_ argv: [String]) -> Result<[String], ApplicationLaunchFailure>

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
/// Discovery, the list generator, the process launcher and the script writer
/// are injected, so the mode owns only ordering, history and the menu actions.
///
/// Accepting a row or typed text runs `-run-command`; the terminal action
/// (MENU_CUSTOM_ACTION, run.c:456) runs `-run-shell-command` through
/// `TerminalLaunch`. Neither goes through a shell: `{cmd}` is substituted and
/// the result is split with `g_shell_parse_argv` rules (helper.c:1451-1459,
/// 102-144), so typed `ls -la` and `echo "a b"` split as a shell would while
/// pipes, `$VAR` and globs stay literal. A row is shell-quoted first
/// (run.c:355), so a name with blanks stays one argument.
///
/// `-run-list-command` (run.c:185-240, 375-377) adds the lines its command
/// prints. ponytail: an empty line is dropped, where upstream keeps an empty
/// row (run.c:194).
///
/// kb-mode-complete on a row starts the file completer (MENU_COMPLETE,
/// run.c:459-491, 514-531): the rows, matching, icons and message come from
/// a file browser until the key is pressed again, and a chosen file runs
/// `<exec> <g_shell_quote(path)>` like any other command.
/// ponytail: the completer is always the file browser; upstream picks it with
/// `-completer-mode` (rofi.c:1413-1421, xrmoptions.c:670-673).
public final class RunMode: Mode {
    public let name = "run"
    /// The completer's rows while completing (run.c:445-447), else the commands.
    public var rows: [Row] { completer?.rows ?? entryRows }
    private var entryRows: [Row] = []

    /// `RunEntry` (run.c:66-75): the shown text and the command it runs.
    private struct Entry {
        var entry: String
        var exec: String
    }

    private var entries: [Entry] = [] {
        didSet { entryRows = entries.map { Row(parsing: $0.entry) } }
    }
    /// `file_complete` and `completer` (run.c:87-92): non-nil while completing.
    private var completer: FileBrowserMode?
    /// The row being completed and the inputs swapped in and out
    /// (`selected_line`, `old_input`, `old_completer_input`).
    private var completedRow = 0
    private var oldInput: String?
    private var oldCompleterInput: String?
    private let discover: () -> [String]?
    private let history: History?
    private let terminal: String?
    private let runCommand: String
    private let runShellCommand: String
    private let launcher: CommandLauncher
    private let writeScript: ScriptWriter
    private let listCommand: String?
    private let generate: ListGenerator
    private let makeCompleter: (() -> FileBrowserMode)?
    /// The last failed launch or list command, worded as upstream's error dialog
    /// (helper.c:1426-1434, 136-137); cleared by the next action.
    private var failure: String?

    /// `runCommand` and `runShellCommand` default as config/config.c:70,74;
    /// `terminal` is `-terminal`, nil when unset; `listCommand` is
    /// `-run-list-command`, nil or empty when unset (config.c:72).
    public init(
        discover: @escaping () -> [String]?, history: History?, terminal: String?,
        runCommand: String = "{cmd}", runShellCommand: String = "{terminal} -e {cmd}",
        launcher: @escaping CommandLauncher, writeScript: @escaping ScriptWriter,
        listCommand: String? = nil, generate: @escaping ListGenerator = unavailableListGenerator,
        completer: (() -> FileBrowserMode)? = nil
    ) {
        makeCompleter = completer
        self.discover = discover
        self.history = history
        self.terminal = terminal
        self.runCommand = runCommand
        self.runShellCommand = runShellCommand
        self.launcher = launcher
        self.writeScript = writeScript
        self.listCommand = listCommand
        self.generate = generate
        load()
    }

    /// A failure first; while completing, `run_get_message` (run.c:556-572).
    public var message: String? {
        if let failure { return failure }
        guard let completer else { return nil }
        let header = "File complete for: " + entries[completedRow].entry
        return completer.message.map { header + "\n" + $0 } ?? header
    }

    /// `run_token_match` (run.c:548-554).
    public func matches(_ row: Row, matcher: Matcher) -> Bool {
        completer?.matches(row, matcher: matcher) ?? matcher.matches(row.text)
    }

    /// `_get_completion` is NULL (run.c:613), so the display value is scored,
    /// the completer's while completing (run.c:541-543).
    public func completion(at row: Int) -> String {
        completer?.completion(at: row) ?? entryRows[row].text
    }

    /// `_get_icon` while completing (run.c:578-579). ponytail: no icon for a
    /// command row, where upstream looks up its first word (run.c:589-596).
    public func iconPath(at row: Int) -> String? { completer?.iconPath(at: row) }
    public func iconImagePath(at row: Int) -> String? { completer?.iconImagePath(at: row) }

    /// MENU_COMPLETE. A first press on a row saves the input, restores the
    /// completer's last input and starts a fresh completer (run.c:514-531);
    /// a press while completing does the reverse (run.c:463-471). Without a
    /// row it only reloads. nil without a completer.
    public func complete(input: inout String?, selectedRow: Int?) -> ModeResult? {
        guard let makeCompleter else { return nil }
        failure = nil
        if completer != nil {
            oldCompleterInput = input
            input = oldInput
            completer = nil
            return .reload
        }
        guard let row = selectedRow, entries.indices.contains(row) else { return .reload }
        completedRow = row
        oldInput = input
        input = oldCompleterInput
        completer = makeCompleter()
        return .reload
    }

    /// `get_apps` (run.c:245-415): history first in file order, then the PATH
    /// names and list lines not already in it, sorted by bytes with
    /// duplicates removed (376-396).
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
        let others = Set(names.filter { !known.contains($0) } + listLines(skipping: recent.map(\.entry)))
        // sort_func is g_strcmp0, a byte comparison (166-183).
        let sorted = others.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        entries = recent + sorted.map { Entry(entry: $0, exec: shellQuote($0)) }
    }

    /// `get_apps_external` (run.c:185-240): the list command's lines, minus
    /// those equal to a history entry ignoring ASCII case (`strcasecmp`,
    /// 203-211). A failure becomes the message and adds nothing
    /// (helper.c:572-578).
    private func listLines(skipping favorites: [String]) -> [String] {
        // 375: unset and empty both mean no list command.
        guard let listCommand, !listCommand.isEmpty else { return [] }
        let argv: [String]
        do {
            // execute_generator passes the command as `{cmd}` (helper.c:564).
            argv = try parseCommandTemplate(
                runCommand, values: ["cmd": listCommand, "terminal": terminal ?? TerminalLaunch.defaultTerminal])
        } catch {
            failure = (error as? CommandTemplateError)?.message ?? "\(error)"
            return []
        }
        switch generate(argv) {
        case .success(let lines):
            let skipped = Set(favorites.map(asciiLowercased))
            return lines.filter { !$0.isEmpty && !skipped.contains(asciiLowercased($0)) }
        case .failure(let error):
            failure = ApplicationLaunchFailure(command: listCommand, reason: error.reason).dialogText
            return []
        }
    }

    /// `run_mode_result` (run.c:451-540) for the actions without a terminal.
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        result(action, runInTerminal: false, input: &input, selectedRow: selectedRow)
    }

    /// `run_in_term` is MENU_CUSTOM_ACTION (run.c:456), which the switcher
    /// passes as `alt` for Shift+Return.
    public func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult {
        result(action, runInTerminal: alt, input: &input, selectedRow: selectedRow)
    }

    public func result(
        _ action: MenuAction, runInTerminal: Bool, input: inout String?, selectedRow: Int?
    ) -> ModeResult {
        failure = nil
        if let completer {
            return completerResult(
                completer, action, runInTerminal: runInTerminal, input: &input, selectedRow: selectedRow)
        }
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

    /// `run_mode_result` while completing (run.c:459-491): cancel exits,
    /// everything else goes to the completer. Its exit with a path runs
    /// `<exec> <g_shell_quote(path)>` under that same text (480-486); without
    /// a path it runs the row as it is (476-479).
    /// ponytail: upstream exits even when that launch fails (485); as on the
    /// plain path (499-503), the failure is shown and the view stays.
    private func completerResult(
        _ completer: FileBrowserMode, _ action: MenuAction, runInTerminal: Bool, input: inout String?,
        selectedRow: Int?
    ) -> ModeResult {
        if action == .cancel { return .exit }
        let answer = completer.completerResult(action, input: &input, selectedRow: selectedRow)
        guard answer.result == .exit else { return answer.result }
        let entry = entries[completedRow]
        guard let path = answer.path else {
            return execute(entry.exec, inTerminal: runInTerminal, original: entry.entry) ? .exit : .reload
        }
        let command = entry.exec + " " + shellQuote(path)
        return execute(command, inTerminal: runInTerminal, original: command) ? .exit : .reload
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
