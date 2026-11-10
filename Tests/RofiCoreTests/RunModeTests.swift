// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

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

    private func make(
        history: History? = nil, terminal: String? = nil, runCommand: String = "{cmd}",
        runShellCommand: String = "{terminal} -e {cmd}"
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
}
