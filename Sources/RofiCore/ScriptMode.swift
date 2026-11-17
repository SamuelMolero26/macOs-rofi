import Foundation

/// A `name:path` script mode (source/modes/script.c). The script runs once to
/// list rows, then again for each accepted row or custom input; its output is
/// rows plus `\0key\x1fvalue` header lines.
///
/// ponytail: theme is parsed and ignored until #73 (script.c:186-190).
public final class ScriptMode: Mode {
    public let name: String
    /// The `path` of the spec, split like a shell command line on every run
    /// (script.c:234).
    public let command: String
    public private(set) var rows: [Row] = []
    /// The message header; it persists until another one (script.c:158-160).
    public private(set) var message: String?
    /// The prompt header, which replaces the display name (script.c:161-164).
    public private(set) var displayName: String?
    public private(set) var selectedRowAfterResult: Int?
    /// The markup-rows header; it persists across runs (script.c:165-166).
    public private(set) var markupRows = false
    /// Why the last run could not start, worded as rofi's error dialog
    /// (script.c:242-246); nil once a run starts.
    public private(set) var error: String?

    private var data: String?
    private var noCustom = false
    private var useHotKeys = false
    /// Starts as newline and persists across runs (script.c:334, 171-172).
    private var delimiter: UInt8 = 0x0A
    /// The urgent and active headers of the current run (script.c:350-358).
    private var urgentRanges: [RowRange] = []
    private var activeRanges: [RowRange] = []
    /// keep-selection, keep-filter and new-selection of the current run
    /// (script.c:211-213).
    private var keepSelection = false
    private var keepFilter = false
    private var newSelection: Int?
    /// The enabled modes' names, which switch-mode looks up (rofi.c:161-168).
    private let modeNames: [String]
    /// The switch-mode header's mode index (script.c:137-146), dropped after
    /// the first run (341) and once used (427).
    private var switchMode: Int?

    /// `script_mode_init` runs the script with no argument (script.c:331-341).
    public init(name: String, command: String, modeNames: [String] = []) {
        self.name = name
        self.command = command
        self.modeNames = modeNames
        rows = execute(argument: nil, retv: 0, row: nil, input: nil)
        switchMode = nil
    }

    /// `script_token_match` (script.c:515-554), as `Row.matches` describes.
    public func matches(_ row: Row, at index: Int, matcher: Matcher) -> Bool {
        row.matches(matcher, markup: markupRows)
    }

    /// `\0icon` (script.c:100-101), as `Row.iconImagePath` describes.
    public func iconImagePath(at row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].iconImagePath : nil
    }

    /// `script_mode_result` (script.c:370-454).
    public func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult {
        selectedRowAfterResult = nil
        // script.c:378-379: the output acted on decides these two.
        let (keepSelection, keepFilter) = (self.keepSelection, self.keepFilter)
        let row = selectedRow.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        let newRows: [Row]
        switch action {
        case .customKey(let key):
            // script.c:396-398: without use-hot-keys the key's index is
            // returned as a mode index to switch to.
            guard useHotKeys else { return .switchTo(key) }
            if let row {
                newRows = execute(argument: row.text, retv: 10 + key, row: row, input: input)
            } else if !noCustom {
                newRows = execute(argument: input, retv: 10 + key, row: nil, input: input)
            } else {
                return .reload
            }
        case .deleteEntry:
            guard let row else { return .exit }
            newRows = execute(argument: row.text, retv: 3, row: row, input: input)
        case .ok:
            guard let row else { return .exit }
            if row.nonselectable { return .reload }
            newRows = execute(argument: row.text, retv: 1, row: row, input: input)
        case .customInput:
            guard let input else { return .exit }
            if noCustom { return .reload }
            newRows = execute(argument: input, retv: 2, row: nil, input: input)
        case .cancel:
            return .exit
        }
        // script.c:422-428: a known switch-mode drops the rows and the input.
        if let switchMode {
            self.switchMode = nil
            input = nil
            return .switchTo(switchMode)
        }
        // script.c:431-452: no rows exits; new rows reload with row 0
        // selected, or under keep-selection new-selection if it is a row,
        // else the selected one; the input is cleared unless keep-filter.
        guard !newRows.isEmpty else { return .exit }
        rows = newRows
        if !keepSelection {
            selectedRowAfterResult = 0
        } else if let newSelection, rows.indices.contains(newSelection) {
            selectedRowAfterResult = newSelection
        } else {
            selectedRowAfterResult = selectedRow ?? 0
        }
        if !keepFilter { input = nil }
        return .reload
    }

    /// MENU_COMPLETE matches no branch of `script_mode_result`, so the view
    /// exits without running the script (script.c:373, 380-420).
    public func complete(input: inout String?, selectedRow: Int?) -> ModeResult? {
        selectedRowAfterResult = nil
        return .exit
    }

    /// `execute_executor` (script.c:197-320): spawn without a shell, with
    /// `argument` appended, then read stdout to the end.
    private func execute(argument: String?, retv: Int, row: Row?, input: String?) -> [Row] {
        var environment = ProcessInfo.processInfo.environment
        environment["ROFI_RETV"] = String(retv)
        environment["ROFI_OUTSIDE"] = String(getpid())
        if let info = row?.info { environment["ROFI_INFO"] = info }
        if let data { environment["ROFI_DATA"] = data }
        if let input { environment["ROFI_INPUT"] = input }

        let output: [UInt8]
        do throws(SpawnError) {
            var argv = try shellParseArgv(command)
            if let argument { argv.append(argument) }
            output = try spawnAndRead(argv, environment: environment)
            error = nil
        } catch {
            self.error = "Failed to execute: '\(command)'\nError: '\(error.message)'"
            return []
        }
        return parse(output)
    }

    /// The read loop (script.c:258-308): records end at the current
    /// delimiter, which a delim header changes for the records after it.
    /// The urgent and active ranges then flag their rows (script.c:495-504).
    private func parse(_ output: [UInt8]) -> [Row] {
        var rows: [Row] = []
        urgentRanges = []
        activeRanges = []
        (keepSelection, keepFilter, newSelection) = (false, false, nil)
        var start = output.startIndex
        while start < output.endIndex {
            let end = output[start...].firstIndex(of: delimiter).map { $0 + 1 } ?? output.endIndex
            var record = Array(output[start..<end])
            start = end
            if record.last == delimiter { record[record.count - 1] = 0 }
            if record[0] == 0 {
                parseHeader(record.dropFirst())
            } else {
                rows.append(Row(parsing: record))
            }
        }
        for i in rows.indices {
            rows[i].urgent = rows[i].urgent || urgentRanges.contains { $0.contains(i, rowCount: rows.count) }
            rows[i].active = rows[i].active || activeRanges.contains { $0.contains(i, rowCount: rows.count) }
        }
        return rows
    }

    /// `parse_header_entry` (script.c:148-195). `line` still holds the
    /// delimiter's place, so a value needs one byte after the \x1f.
    private func parseHeader(_ line: ArraySlice<UInt8>) {
        let keyLength = line.firstIndex(of: 0x1F).map { $0 - line.startIndex } ?? line.count
        guard keyLength + 1 < line.count else { return }
        let key = forceUTF8(cString(line.prefix(keyLength))).lowercased()
        let bytes = cString(line.dropFirst(keyLength + 1))
        let value = forceUTF8(bytes)
        let isTrue = value.lowercased() == "true"
        switch key {
        case "message": message = value.isEmpty ? nil : value
        case "prompt": displayName = value
        case "markup-rows": markupRows = isTrue
        case "urgent": urgentRanges += parseRowRanges(value)
        case "active": activeRanges += parseRowRanges(value)
        case "delim": delimiter = bytes.count == 1 ? bytes[bytes.startIndex] : parseSeparator(value)
        case "no-custom": noCustom = isTrue
        case "use-hot-keys": useHotKeys = isTrue
        case "keep-selection": keepSelection = isTrue
        case "keep-filter": keepFilter = isTrue
        case "new-selection": newSelection = Int(strtoll(value, nil, 0))
        case "data": data = value
        // ponytail: rofi g_warning()s an unknown mode; it is dropped here.
        case "switch-mode": switchMode = modeNames.firstIndex(of: value) ?? switchMode
        default: break
        }
    }
}

/// Creates mode lists that do not contain `drun`. Application-mode assembly
/// must use the records-and-launcher overload so RofiCore stays platform-free.
public func makeModes(_ specs: [ModeSpec]) -> [any Mode] {
    precondition(
        !withCombined(specs).contains { if case .drun = $0 { true } else { false } },
        "drun mode requires injected application records and launcher")
    return makeModes(
        specs, applications: { [] },
        launcher: { _ in
            .failure(
                ApplicationLaunchFailure(
                    command: "launch application", reason: "application launcher is unavailable"))
        })
}

/// One mode per entry of the mode list (source/rofi.c:790-826).
///
/// Application discovery completes synchronously before any mode is returned,
/// and is skipped when the list does not contain `drun`. Multiple `drun`
/// entries share the same discovered records. ponytail: upstream reuses the
/// instance when a name is listed again bare.
public func makeModes(
    _ specs: [ModeSpec], applications: () -> [ApplicationRecord],
    launcher: @escaping ApplicationLauncher,
    executables: @escaping () -> [String]? = { nil },
    commandLauncher: @escaping CommandLauncher = unavailableCommandLauncher,
    scriptWriter: @escaping ScriptWriter = unavailableScriptWriter,
    listGenerator: @escaping ListGenerator = unavailableListGenerator,
    fileSystem: any FileBrowserFileSystem = DiskFileSystem(),
    sshFiles: SshFiles = .none
) -> [any Mode] {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let applicationRecords =
        withCombined(specs).contains { if case .drun = $0 { true } else { false } }
        ? applications() : []
    // run's file completer reads the same settings as the filebrowser mode
    // (filebrowser.c:395-405); they only reach us through its spec.
    let browserSettings = withCombined(specs).lazy.compactMap { spec -> (directory: String?, showHidden: Bool)? in
        if case .fileBrowser(let directory, let showHidden) = spec { (directory, showHidden) } else { nil }
    }.first
    // run.c:524-528: a fresh completer per completion.
    let completer = {
        FileBrowserMode(
            directory: browserSettings?.directory, showHidden: browserSettings?.showHidden ?? false, home: home,
            fileSystem: fileSystem)
    }
    func make(_ spec: ModeSpec) -> any Mode {
        switch spec {
        case .script(let name, let path): ScriptMode(name: name, command: path, modeNames: specs.map(\.name))
        case .run(let historyPath, let terminal, let runCommand, let runShellCommand, let listCommand):
            RunMode(
                discover: executables, history: historyPath.map { History(url: URL(fileURLWithPath: $0)) },
                terminal: terminal, runCommand: runCommand, runShellCommand: runShellCommand,
                launcher: commandLauncher, writeScript: scriptWriter,
                listCommand: listCommand, generate: listGenerator, completer: completer)
        case .ssh(let historyPath, let terminal, let sshCommand, let sshClient, let parseHosts, let parseKnownHosts):
            SshMode(
                home: home, files: sshFiles, history: historyPath.map { History(url: URL(fileURLWithPath: $0)) },
                terminal: terminal, sshCommand: sshCommand, sshClient: sshClient, parseHosts: parseHosts,
                parseKnownHosts: parseKnownHosts, launcher: commandLauncher, writeScript: scriptWriter)
        case .drun(let historyPath):
            DrunMode(
                applications: applicationRecords,
                history: historyPath.map { History(url: URL(fileURLWithPath: $0)) },
                launcher: launcher)
        case .fileBrowser(let directory, let showHidden):
            FileBrowserMode(directory: directory, showHidden: showHidden, home: home, fileSystem: fileSystem)
        case .combi(let modes, let displayNames, let displayFormat):
            CombiMode(modes: modes.map(make), displayNames: displayNames, displayFormat: displayFormat)
        case .keys(let keymap): KeysMode(keymap: keymap)
        }
    }
    return specs.map(make)
}

/// The specs with each combi's modes after it.
private func withCombined(_ specs: [ModeSpec]) -> [ModeSpec] {
    specs.flatMap { spec in
        if case .combi(let modes, _, _) = spec { [spec] + modes } else { [spec] }
    }
}

/// Stand-ins for callers that inject no process launcher: nothing is spawned.
public func unavailableCommandLauncher(_ argv: [String]) -> Result<Void, ApplicationLaunchFailure> {
    .failure(
        ApplicationLaunchFailure(command: argv.joined(separator: " "), reason: "command launcher is unavailable"))
}

public func unavailableScriptWriter(_ contents: String, _ mode: Int) -> Result<String, ApplicationLaunchFailure> {
    .failure(ApplicationLaunchFailure(command: "script", reason: "script writer is unavailable"))
}

public func unavailableListGenerator(_ argv: [String]) -> Result<[String], ApplicationLaunchFailure> {
    .failure(
        ApplicationLaunchFailure(command: argv.joined(separator: " "), reason: "list generator is unavailable"))
}

/// A failure worded as the GError rofi prints.
struct SpawnError: Error {
    let message: String
}

/// The bytes up to the first NUL, as C string functions see them.
private func cString(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    bytes.prefix { $0 != 0 }
}

/// `g_shell_parse_argv`: words split on blanks, with single quotes,
/// double quotes, backslash escapes and `#` comments, and no expansions.
func shellParseArgv(_ text: String) throws(SpawnError) -> [String] {
    var words: [String] = []
    var word: String?
    var chars = text[...]
    while let char = chars.popFirst() {
        switch char {
        case " ", "\t", "\n":
            if let current = word { words.append(current) }
            word = nil
        case "#" where word == nil:
            while let next = chars.first, next != "\n" { chars.removeFirst() }
        case "\\":
            // A backslash-newline is a line continuation.
            guard let next = chars.popFirst() else {
                word = (word ?? "") + "\\"
                break
            }
            if next != "\n" { word = (word ?? "") + String(next) }
        case "'", "\"":
            var quoted = ""
            var closed = false
            while let next = chars.popFirst() {
                if next == char {
                    closed = true
                    break
                }
                // In double quotes a backslash escapes only $ ` " \ and newline.
                if char == "\"", next == "\\", let escaped = chars.first, "$`\"\\\n".contains(escaped) {
                    chars.removeFirst()
                    if escaped != "\n" { quoted.append(escaped) }
                } else {
                    quoted.append(next)
                }
            }
            guard closed else {
                throw SpawnError(
                    message: "Text ended before matching quote was found for \(char). (The text was “\(text)”)")
            }
            word = (word ?? "") + quoted
        default:
            word = (word ?? "") + String(char)
        }
    }
    if let word { words.append(word) }
    guard !words.isEmpty else { throw SpawnError(message: "Text was empty (or contained only whitespace)") }
    return words
}

/// `g_spawn_async_with_pipes` with G_SPAWN_SEARCH_PATH (script.c:238-239):
/// stdin from /dev/null, stderr and the working directory inherited, other
/// descriptors closed. Blocks until stdout ends, like the read loop.
private func spawnAndRead(_ argv: [String], environment: [String: String]) throws(SpawnError) -> [UInt8] {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw SpawnError(message: String(cString: strerror(errno))) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
    posix_spawn_file_actions_addinherit_np(&actions, 2)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let cArgv = argv.map { strdup($0) } + [nil]
    let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for pointer in cArgv + cEnvironment { free(pointer) }
    }

    var pid: pid_t = 0
    let status = posix_spawnp(&pid, argv[0], &actions, &attributes, cArgv, cEnvironment)
    close(fds[1])
    guard status == 0 else {
        close(fds[0])
        throw SpawnError(message: "Failed to execute child process “\(argv[0])” (\(String(cString: strerror(status))))")
    }

    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fds[0], &buffer, buffer.count)
        if count > 0 {
            output += buffer[..<count]
        } else if count == 0 || errno != EINTR {
            break
        }
    }
    close(fds[0])
    // Upstream never waits; reaping here only avoids a zombie.
    while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
    return output
}
