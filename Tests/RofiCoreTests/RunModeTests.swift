// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

/// An in-memory tree for the file completer.
private final class CompleterTree: FileBrowserFileSystem {
    let contents: [String: [FileBrowserEntry]] = [
        "/home/u": [
            FileBrowserEntry(name: "Docs", kind: .directory, isLink: false),
            FileBrowserEntry(name: "my file's.txt", kind: .file, isLink: false),
            FileBrowserEntry(name: ".hidden", kind: .file, isLink: false),
        ],
        "/home/u/Docs": [FileBrowserEntry(name: "a.txt", kind: .file, isLink: false)],
    ]

    func entries(in path: String) -> [FileBrowserEntry]? { contents[path] }
    func isDirectory(_ path: String) -> Bool { contents[path] != nil }
    func exists(_ path: String) -> Bool { isDirectory(path) || path == "/home/u/my file's.txt" }
}

// Contract: rofi's run mode, source/modes/run.c (cache file 64, exec_cmd
// 104-140, get_apps 245-415, run_mode_result 451-540), with PATH discovery,
// the process launcher and the script writer injected.
@Suite final class RunModeTests {
    // MARK: PATH discovery (run.c:245-415)

    private func file(_ name: String, executable: Bool = true) -> PathEntry {
        PathEntry(name: name, kind: .regular, isExecutable: executable)
    }

    private func discover(
        _ path: String?, home: String = "/home/u", _ directories: [String: [PathEntry]]
    ) -> [String]? {
        discoverExecutables(path: path, home: home, list: { directories[$0] })
    }

    // run.c:251-253: no PATH, no rows at all.
    @Test func missingPathYieldsNothing_run_c_251() {
        #expect(discover(nil, [:]) == nil)
    }

    // run.c:313-319: regular files, symlinks and unknown types count;
    // directories and dot files do not.
    @Test func skipsDirectoriesAndDotFiles_run_c_313() {
        let entries = [
            file("ls"),
            PathEntry(name: "link", kind: .symlink, isExecutable: true),
            PathEntry(name: "odd", kind: .unknown, isExecutable: true),
            PathEntry(name: "folder", kind: .other, isExecutable: true),
            file(".hidden"),
        ]
        #expect(discover("/bin", ["/bin": entries]) == ["link", "ls", "odd"])
    }

    // run.c:309, 321-327: only directories under the home directory test the
    // executable bit.
    @Test func executableBitIsCheckedOnlyUnderHome_run_c_321() {
        let entries = [file("tool"), file("data", executable: false)]
        #expect(discover("/home/u/bin", ["/home/u/bin": entries]) == ["tool"])
        #expect(discover("/usr/bin", ["/usr/bin": entries]) == ["data", "tool"])
    }

    // run.c:291-292, 273: strtok skips empty components; an unreadable one is
    // skipped (run.c:297-298, 305).
    @Test func skipsEmptyAndUnreadableComponents_run_c_291() {
        #expect(discover("::/missing:/bin:", ["/bin": [file("ls")]]) == ["ls"])
    }

    // run.c:376-396: byte-wise sort, adjacent duplicates removed.
    @Test func sortsByBytesAndDropsDuplicates_run_c_376() {
        let result = discover(
            "/a:/b", ["/a": [file("zed"), file("Alpha"), file("beta")], "/b": [file("beta"), file("alpha")]])
        #expect(result == ["Alpha", "alpha", "beta", "zed"])
    }

    // run.c:291: a leading `~` in a component is expanded before it is opened
    // (rofi_expand_path).
    @Test func expandsTildeComponents_run_c_294() {
        #expect(discover("~/bin", home: "/home/u", ["/home/u/bin": [file("mine")]]) == ["mine"])
    }

    // MARK: the mode (run.c:104-140, 451-540)

    private var launched: [[String]] = []
    private var scripts: [String] = []
    private var launchResult: Result<Void, ApplicationLaunchFailure> = .success(())
    private var scriptResult: Result<String, ApplicationLaunchFailure> = .success("/tmp/rofi-x.command")
    private var discovered: [String]? = ["ls", "my tool", "zip"]
    private var generated: [[String]] = []
    private var generatorResult: Result<[String], ApplicationLaunchFailure> = .success([])

    private func make(
        history: History? = nil, terminal: String? = nil, runCommand: String = "{cmd}",
        runShellCommand: String = "{terminal} -e {cmd}", listCommand: String? = nil
    ) -> RunMode {
        RunMode(
            discover: { [unowned self] in discovered }, history: history, terminal: terminal,
            runCommand: runCommand, runShellCommand: runShellCommand,
            launcher: { [unowned self] argv in
                launched.append(argv)
                return launchResult
            },
            writeScript: { [unowned self] contents, _ in
                scripts.append(contents)
                return scriptResult
            },
            listCommand: listCommand,
            generate: { [unowned self] argv in
                generated.append(argv)
                return generatorResult
            },
            completer: { [unowned self] in makeCompleter() })
    }

    // MARK: the file completer's tree (filebrowser.c:672-724), never the disk

    private let tree = CompleterTree()
    private var opened: [String] = []
    private var completersMade = 0

    private func makeCompleter() -> FileBrowserMode {
        completersMade += 1
        return FileBrowserMode(
            directory: "/home/u", showHidden: false, home: "/home/u", fileSystem: tree,
            opener: { [unowned self] path, _ in
                opened.append(path)
                return .success(())
            })
    }

    private func act(
        _ mode: RunMode, _ action: MenuAction, input: String? = nil, row: Int? = nil,
        inTerminal: Bool = false
    ) -> ModeResult {
        var input = input
        return mode.result(action, runInTerminal: inTerminal, input: &input, selectedRow: row)
    }

    /// A history file in a fresh directory, seeded with `contents`.
    private func withHistory(_ contents: String? = nil, _ body: (History) throws -> Void) throws {
        let name = "rofi-run-\(UInt64.random(in: .min ... .max))/rofi-4.runcache"
        let history = History(url: .temporaryDirectory.appending(path: name))
        let directory = history.url.deletingLastPathComponent().path(percentEncoded: false)
        let file = history.url.path(percentEncoded: false)
        try #require(mkdir(directory, 0o700) == 0)
        defer {
            unlink(file)
            rmdir(directory)
        }
        if let contents {
            let handle = try #require(fopen(file, "w"))
            fputs(contents, handle)
            fclose(handle)
        }
        try body(history)
    }

    @Test func nameIsRun_run_c_599() {
        #expect(make().name == "run")
    }

    // run.c:376-396: the discovered names are the rows.
    @Test func rowsAreTheDiscoveredNames_run_c_376() {
        #expect(make().rows.map(\.text) == ["ls", "my tool", "zip"])
    }

    // run.c:251-253.
    @Test func noPathMeansNoRows_run_c_251() {
        discovered = nil
        #expect(make().rows.isEmpty)
    }

    // run.c:255-272, 376-396: history entries come first in file order, and
    // are not repeated among the PATH names (333-347).
    @Test func historyComesFirstAndIsNotRepeated_run_c_255() throws {
        try withHistory("1 zip\u{1F}'zip'\n0 ghost\u{1F}ghost -v\n") { history in
            let mode = make(history: history)
            #expect(mode.rows.map(\.text) == ["zip", "ghost", "ls", "my tool"])
        }
    }

    // run.c:260-263: an entry with no separator is its own command.
    @Test func historyEntryWithoutSeparatorRunsItself_run_c_260() throws {
        try withHistory("0 htop -d 5\n") { history in
            let mode = make(history: history)
            #expect(act(mode, .ok, row: 0) == .exit)
            #expect(launched == [["htop", "-d", "5"]])
        }
    }

    // run.c:493-498, 355: a row runs its shell-quoted name through `{cmd}`.
    @Test func acceptingARowLaunchesItsQuotedName_run_c_493() {
        let mode = make()
        #expect(act(mode, .ok, row: 1) == .exit)
        #expect(launched == [["my tool"]])
    }

    // run.c:493: no row to accept, nothing happens and the view closes.
    @Test func acceptingWithoutARowExits_run_c_493() {
        let mode = make()
        #expect(act(mode, .ok, row: 99) == .exit)
        #expect(launched.isEmpty)
    }

    // helper.c:1451-1459 substitutes then splits; typed text is split
    // shell-style with no shell, so quoting works and nothing expands.
    @Test func typedInputIsSplitShellStyleWithoutAShell_helper_c_1451() {
        let mode = make()
        #expect(act(mode, .customInput, input: "ls -la") == .exit)
        #expect(act(mode, .customInput, input: "echo \"a b\" $HOME") == .exit)
        #expect(launched == [["ls", "-la"], ["echo", "a b", "$HOME"]])
    }

    // run.c:499-503.
    @Test func emptyCustomInputExits_run_c_499() {
        let mode = make()
        #expect(act(mode, .customInput, input: "") == .exit)
        #expect(act(mode, .customInput, input: nil) == .exit)
        #expect(launched.isEmpty)
    }

    // run.c:118-129: success stores `entry US exec`; a row keeps its name as
    // the entry, typed text is both.
    @Test func runningRecordsHistory_run_c_126() throws {
        try withHistory { history in
            let mode = make(history: history)
            _ = act(mode, .ok, row: 1)
            _ = act(mode, .customInput, input: "ls -la")
            // The newer entry has the higher count after rebasing (history.c:58-77).
            #expect(history.list() == ["ls -la\u{1F}ls -la", "my tool\u{1F}'my tool'"])
        }
    }

    // run.c:135: a failed spawn removes the entry again.
    @Test func aFailedRunIsRemovedFromHistory_run_c_135() throws {
        try withHistory("0 ls\u{1F}'ls'\n") { history in
            launchResult = .failure(ApplicationLaunchFailure(command: "ls", reason: "nope"))
            _ = act(make(history: history), .ok, row: 0)
            #expect(history.list().isEmpty)
        }
    }

    // config/config.c:103: `-disable-history` neither reads nor writes.
    @Test func disabledHistoryIsNeitherReadNorWritten_config_c_103() throws {
        try withHistory("0 zip\u{1F}'zip'\n") { seeded in
            var history = seeded
            history.disabled = true
            let mode = make(history: history)
            #expect(mode.rows.map(\.text) == ["ls", "my tool", "zip"])
            _ = act(mode, .ok, row: 0)
            #expect(seeded.list() == ["zip\u{1F}'zip'"])
        }
    }

    // run.c:504-512: delete drops the history entry and reloads the list.
    @Test func deleteRemovesTheHistoryEntryAndReloads_run_c_504() throws {
        try withHistory("1 zip\u{1F}'zip'\n") { history in
            let mode = make(history: history)
            #expect(act(mode, .deleteEntry, row: 0) == .reload)
            #expect(history.list().isEmpty)
            #expect(mode.rows.map(\.text) == ["ls", "my tool", "zip"])
        }
    }

    // run.c:513-514.
    @Test func customKeysSwitchMode_run_c_513() {
        #expect(act(make(), .customKey(3)) == .switchTo(3))
    }

    @Test func cancelExits_run_c_452() {
        #expect(act(make(), .cancel) == .exit)
    }

    // MARK: terminal (run.c:456, helper.c:1451-1453, config.c:74)

    @Test func theTerminalActionUsesTheShellTemplateWithASetTerminal_run_c_456() {
        let mode = make(terminal: "ghostty")
        #expect(act(mode, .customInput, input: "ls -la", inTerminal: true) == .exit)
        #expect(act(mode, .ok, row: 1, inTerminal: true) == .exit)
        #expect(launched == [["ghostty", "-e", "ls", "-la"], ["ghostty", "-e", "my tool"]])
        #expect(scripts.isEmpty)
    }

    @Test func theTerminalActionDefaultsToTerminalApp_run_c_456() {
        let mode = make()
        #expect(act(mode, .customInput, input: "ls -la", inTerminal: true) == .exit)
        #expect(scripts.count == 1)
        #expect(scripts[0].hasSuffix("exec 'ls' '-la'\n"))
        #expect(launched == [["/usr/bin/open", "-a", "Terminal", "/tmp/rofi-x.command"]])
    }

    // The alt-aware requirement is what `ModeSwitcher` calls through `any Mode`.
    @Test func altThroughTheModeRequirementRunsInTheTerminal_run_c_456() {
        let mode: any Mode = make(terminal: "ghostty")
        var input: String? = "top"
        #expect(mode.result(.customInput, alt: true, input: &input, selectedRow: nil) == .exit)
        #expect(mode.result(.ok, alt: true, input: &input, selectedRow: 0) == .exit)
        #expect(launched == [["ghostty", "-e", "top"], ["ghostty", "-e", "ls"]])
    }

    @Test func nonAltThroughTheModeRequirementRunsPlainly_run_c_456() {
        let mode: any Mode = make(terminal: "ghostty")
        var input: String? = "top"
        #expect(mode.result(.customInput, alt: false, input: &input, selectedRow: nil) == .exit)
        #expect(launched == [["top"]])
    }

    @Test func shiftReturnInTheSwitcherRunsTheRowInTheTerminal_run_c_456() {
        var s = ModeSwitcher(modes: [make(terminal: "ghostty")])
        s.selectVisibleIndex(0)
        s.perform(key: .acceptAlt)
        #expect(launched == [["ghostty", "-e", "ls"]])
    }

    @Test func aCustomShellTemplateIsHonored_config_c_74() {
        let mode = make(terminal: "kitty", runShellCommand: "{terminal} --hold {cmd}")
        _ = act(mode, .customInput, input: "top", inTerminal: true)
        #expect(launched == [["kitty", "--hold", "top"]])
    }

    // The plain path never goes through the Terminal.app adapter, even when
    // the command itself contains `-e`.
    @Test func plainRunsNeverUseTheScriptAdapter_helper_c_1457() {
        let mode = make()
        _ = act(mode, .customInput, input: "sed -e s/a/b/")
        #expect(launched == [["sed", "-e", "s/a/b/"]])
        #expect(scripts.isEmpty)
    }

    // config/config.c:70: `-run-command` wraps the command, and `{terminal}`
    // is available there too (helper.c:107).
    @Test func aCustomRunCommandIsHonored_config_c_70() {
        let mode = make(terminal: "kitty", runCommand: "env X=1 {cmd}")
        _ = act(mode, .customInput, input: "ls")
        let other = make(terminal: "kitty", runCommand: "{terminal} {cmd}")
        _ = act(other, .customInput, input: "ls")
        #expect(launched == [["env", "X=1", "ls"], ["kitty", "ls"]])
    }

    // MARK: failures (run.c:493-503, helper.c:1426-1434)

    @Test func aFailedSpawnKeepsTheViewOpenWithAMessage_run_c_495() {
        launchResult = .failure(ApplicationLaunchFailure(command: "ls", reason: "no such file"))
        let mode = make()
        #expect(act(mode, .ok, row: 0) == .reload)
        #expect(mode.message == "Failed to execute: 'ls'\nError: 'no such file'")
        launchResult = .success(())
        #expect(act(mode, .ok, row: 0) == .exit)
        #expect(mode.message == nil)
    }

    @Test func aFailedTypedRunKeepsTheViewOpen_run_c_500() {
        launchResult = .failure(ApplicationLaunchFailure(command: "nope", reason: "x"))
        #expect(act(make(), .customInput, input: "nope") == .reload)
    }

    // helper.c:136-137: a template that does not split is an error dialog.
    @Test func anUnparsableCommandKeepsTheViewOpen_helper_c_136() {
        let mode = make()
        #expect(act(mode, .customInput, input: "echo \"open") == .reload)
        #expect(mode.message?.hasPrefix("Failed to parse: '{cmd}'") == true)
        #expect(launched.isEmpty)
    }

    @Test func aScriptWriteFailureKeepsTheViewOpen_run_c_495() {
        scriptResult = .failure(ApplicationLaunchFailure(command: "/tmp/x", reason: "disk full"))
        let mode = make()
        #expect(act(mode, .customInput, input: "ls", inTerminal: true) == .reload)
        #expect(mode.message == "Failed to execute: '/tmp/x'\nError: 'disk full'")
        #expect(launched.isEmpty)
    }

    // MARK: -run-list-command (run.c:185-240, 375-396, helper.c:562-583)

    // run.c:375: no list command, or an empty one, runs nothing.
    @Test func withoutAListCommandTheGeneratorIsNeverCalled_run_c_375() {
        _ = make()
        _ = make(listCommand: "")
        #expect(generated.isEmpty)
    }

    // run.c:251-253 returns before the list command is reached.
    @Test func withoutPathTheListCommandDoesNotRun_run_c_251() {
        discovered = nil
        #expect(make(listCommand: "lister").rows.isEmpty)
        #expect(generated.isEmpty)
    }

    // helper.c:564: the list command goes through `-run-command` as `{cmd}`,
    // with `{terminal}` available (helper.c:107).
    @Test func theGeneratorArgvComesFromTheRunCommandTemplate_helper_c_564() {
        _ = make(runCommand: "env X=1 {cmd}", listCommand: "list-tools --all")
        _ = make(terminal: "kitty", runCommand: "{terminal} {cmd}", listCommand: "lister")
        #expect(generated == [["env", "X=1", "list-tools", "--all"], ["kitty", "lister"]])
    }

    // run.c:375-396: list lines join the PATH names, then everything after
    // the history is sorted by bytes with exact duplicates removed.
    @Test func listLinesMergeWithPathSortedAndDeduplicated_run_c_376() throws {
        generatorResult = .success(["zed", "alpha", "ls", "Beta", "alpha"])
        #expect(make(listCommand: "lister").rows.map(\.text) == ["Beta", "alpha", "ls", "my tool", "zed", "zip"])
        try withHistory("1 zip\u{1F}'zip'\n") { history in
            let mode = make(history: history, listCommand: "lister")
            #expect(mode.rows.map(\.text) == ["zip", "Beta", "alpha", "ls", "my tool", "zed"])
        }
    }

    // run.c:203-211: a list line equal to a history entry, ignoring case, is
    // skipped; PATH names compare exactly (run.c:343), so `zip` stays.
    @Test func listLinesMatchingHistoryAreSkippedIgnoringCase_run_c_204() throws {
        generatorResult = .success(["ZIP", "Ghost", "new"])
        try withHistory("1 Zip\u{1F}'zip'\n0 ghost\u{1F}ghost -v\n") { history in
            let mode = make(history: history, listCommand: "lister")
            #expect(mode.rows.map(\.text) == ["Zip", "ghost", "ls", "my tool", "new", "zip"])
        }
    }

    // run.c:216: a list entry runs its shell-quoted line, so blanks and
    // quotes stay inside one argument.
    @Test func listEntriesRunTheirShellQuotedLine_run_c_216() {
        discovered = []
        generatorResult = .success(["two words", "it's"])
        let mode = make(listCommand: "lister")
        #expect(mode.rows.map(\.text) == ["it's", "two words"])
        _ = act(mode, .ok, row: 0)
        _ = act(mode, .ok, row: 1)
        #expect(launched == [["it's"], ["two words"]])
    }

    // run.c:194 keeps an empty line as an empty row; here it is dropped.
    @Test func emptyListLinesAreDropped_run_c_194() {
        generatorResult = .success(["", "tool", ""])
        #expect(make(listCommand: "lister").rows.map(\.text) == ["ls", "my tool", "tool", "zip"])
    }

    // helper.c:572-578: a spawn failure is an error dialog worded with the
    // list command, and the list built so far is kept.
    @Test func aGeneratorFailureSetsTheMessageAndKeepsTheRows_helper_c_572() throws {
        generatorResult = .failure(ApplicationLaunchFailure(command: "lister -a", reason: "No such file"))
        try withHistory("1 zip\u{1F}'zip'\n") { history in
            let mode = make(history: history, listCommand: "lister  -a")
            #expect(mode.rows.map(\.text) == ["zip", "ls", "my tool"])
            #expect(mode.message == "Failed to execute: 'lister  -a'\nError: 'No such file'")
            #expect(act(mode, .customKey(1)) == .switchTo(1))
            #expect(mode.message == nil)
        }
    }

    // helper.c:136-137: a list command that does not split is an error dialog.
    @Test func anUnparsableListCommandSetsTheMessage_helper_c_136() {
        let mode = make(listCommand: "echo \"open")
        #expect(mode.message?.hasPrefix("Failed to parse: '{cmd}'") == true)
        #expect(mode.rows.map(\.text) == ["ls", "my tool", "zip"])
        #expect(generated.isEmpty)
    }

    // run.c:504-512: delete rebuilds the list, list command included.
    @Test func deleteRerunsTheListCommand_run_c_509() throws {
        generatorResult = .success(["tool"])
        try withHistory("1 zip\u{1F}'zip'\n") { history in
            let mode = make(history: history, listCommand: "lister")
            #expect(act(mode, .deleteEntry, row: 0) == .reload)
            #expect(generated == [["lister"], ["lister"]])
            #expect(mode.rows.map(\.text) == ["ls", "my tool", "tool", "zip"])
        }
    }

    // MARK: the file completer, MENU_COMPLETE (run.c:459-491, 514-531)

    /// Presses kb-mode-complete on `row` and returns the result and input.
    private func complete(_ mode: RunMode, row: Int?, input: String? = nil) -> (ModeResult?, String?) {
        var input = input
        let result = mode.complete(input: &input, selectedRow: row)
        return (result, input)
    }

    private let completerRows = ["..", "Docs", "my file's.txt"]

    // run.c:514-531: the row is kept, the input saved and replaced by the
    // completer's last input (none yet), and the completer's rows are shown.
    @Test func firstPressOnARowStartsCompletion_run_c_514() {
        let mode = make()
        let (result, input) = complete(mode, row: 1, input: "my")
        #expect(result == .reload)
        #expect(input == nil)
        #expect(mode.rows.map(\.text) == completerRows)
        #expect(completersMade == 1)
        // run.c:556-572.
        #expect(mode.message == "File complete for: my tool\nCurrent directory: /home/u")
    }

    // run.c:514-516: no source row reloads and changes nothing.
    @Test func pressWithoutARowChangesNothing_run_c_516() {
        let mode = make()
        #expect(complete(mode, row: nil, input: "x") == (.reload, "x"))
        #expect(complete(mode, row: 99, input: "x") == (.reload, "x"))
        #expect(mode.rows.map(\.text) == ["ls", "my tool", "zip"])
        #expect(completersMade == 0)
        #expect(mode.message == nil)
    }

    // Without a completer the key is ignored.
    @Test func noCompleterIgnoresTheKey() {
        let mode = RunMode(
            discover: { ["ls"] }, history: nil, terminal: nil,
            launcher: { _ in .success(()) }, writeScript: { _, _ in .success("") })
        #expect(complete(mode, row: 0, input: "x") == (nil, "x"))
        #expect(mode.rows.map(\.text) == ["ls"])
    }

    // run.c:463-471: a second press keeps the completer's input for next
    // time, restores the run input and the run rows.
    @Test func secondPressRestoresTheInputAndRows_run_c_463() {
        let mode = make()
        _ = complete(mode, row: 1, input: "my")
        #expect(complete(mode, row: 0, input: "Do") == (.reload, "my"))
        #expect(mode.rows.map(\.text) == ["ls", "my tool", "zip"])
        #expect(mode.message == nil)
        // run.c:522: the next completion starts from the saved input.
        #expect(complete(mode, row: 0, input: "my") == (.reload, "Do"))
        #expect(completersMade == 2)
    }

    // run.c:551-553, 578-579: matching and icons come from the completer.
    @Test func matchingAndIconsComeFromTheCompleter_run_c_551() {
        let mode = make()
        _ = complete(mode, row: 0)
        let matcher = Matcher(query: "docs", options: MatchOptions())
        #expect(mode.matches(mode.rows[1], matcher: matcher))
        #expect(!mode.matches(mode.rows[2], matcher: matcher))
        #expect(mode.completion(at: 2) == "my file's.txt")
        #expect(mode.iconPath(at: 1) == "/home/u/Docs")
    }

    // filebrowser.c:679-694: a directory is entered with a reset.
    @Test func okOnADirectoryEntersIt_filebrowser_c_688() {
        let mode = make()
        _ = complete(mode, row: 1)
        #expect(act(mode, .ok, row: 1) == .reset)
        #expect(mode.rows.map(\.text) == ["..", "a.txt"])
        #expect(launched.isEmpty)
    }

    // run.c:480-486: a file runs `<exec> <g_shell_quote(path)>`, recorded in
    // the history under that command, and the view exits; the file is never
    // opened.
    @Test func okOnAFileRunsTheRowWithTheQuotedPath_run_c_480() throws {
        try withHistory { history in
            let mode = make(history: history)
            _ = complete(mode, row: 1)
            #expect(act(mode, .ok, row: 2) == .exit)
            #expect(launched == [["my tool", "/home/u/my file's.txt"]])
            let command = "'my tool' '/home/u/my file'\\''s.txt'"
            #expect(history.list() == ["\(command)\u{1F}\(command)"])
            #expect(opened.isEmpty)
        }
    }

    // run.c:456, 485: MENU_CUSTOM_ACTION runs it in the terminal.
    @Test func altOnAFileRunsItInTheTerminal_run_c_456() {
        let mode: any Mode = make(terminal: "ghostty")
        var input: String? = nil
        _ = mode.complete(input: &input, selectedRow: 0)
        #expect(mode.result(.ok, alt: true, input: &input, selectedRow: 2) == .exit)
        #expect(launched == [["ghostty", "-e", "ls", "/home/u/my file's.txt"]])
    }

    // The whole path through the switcher: Control+l on `ls`, pick the file.
    @Test func completionThroughTheSwitcher_view_c_1128() {
        var s = ModeSwitcher(modes: [make()], query: "ls")
        #expect(s.matches.map(\.row.text) == ["ls"])
        s.perform(key: .modeComplete)
        #expect(s.query == "")
        #expect(s.matches.map(\.row.text) == completerRows)
        s.selectVisibleIndex(2)
        let open = s.accept()
        #expect(!open)
        #expect(launched == [["ls", "/home/u/my file's.txt"]])
    }

    // run.c:472-473: cancel exits.
    @Test func cancelExitsWhileCompleting_run_c_472() {
        let mode = make()
        _ = complete(mode, row: 1)
        #expect(act(mode, .cancel) == .exit)
        #expect(launched.isEmpty)
    }

    // filebrowser.c:701-716: typed text naming a directory enters it.
    @Test func customInputDirectoryIsEntered_filebrowser_c_701() {
        let mode = make()
        _ = complete(mode, row: 1)
        #expect(act(mode, .customInput, input: "/missing") == .reload)
        #expect(act(mode, .customInput, input: "/home/u/Docs") == .reset)
        #expect(mode.rows.map(\.text) == ["..", "a.txt"])
        #expect(launched.isEmpty)
    }

    // filebrowser.c:717-721: delete toggles hidden files, not the history.
    @Test func deleteTogglesHiddenWhileCompleting_filebrowser_c_717() throws {
        try withHistory("1 zip\u{1F}'zip'\n") { history in
            let mode = make(history: history)
            _ = complete(mode, row: 0)
            #expect(act(mode, .deleteEntry, row: 0) == .reload)
            #expect(mode.rows.map(\.text).contains(".hidden"))
            #expect(history.list() == ["zip\u{1F}'zip'"])
        }
    }

    // run.c:476-479, filebrowser.c:674: an exit without a path runs the row
    // as it is.
    @Test func customKeyRunsTheRowUnchanged_run_c_477() {
        let mode = make()
        _ = complete(mode, row: 1)
        #expect(act(mode, .customKey(0), row: 0) == .exit)
        #expect(launched == [["my tool"]])
        #expect(opened.isEmpty)
    }

    // ponytail: upstream exits even when the launch fails (run.c:485); as in
    // the run path, the failure is the message and the view stays.
    @Test func aFailedLaunchStaysInCompletionWithTheMessage() {
        launchResult = .failure(ApplicationLaunchFailure(command: "ls", reason: "nope"))
        let mode = make()
        _ = complete(mode, row: 0)
        #expect(act(mode, .ok, row: 2) == .reload)
        #expect(mode.message == "Failed to execute: 'ls'\nError: 'nope'")
        #expect(mode.rows.map(\.text) == completerRows)
    }
}
