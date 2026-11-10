import Testing

@testable import RofiCore

// Contract: default templates, config/config.c:68,74; helper_execute*, source/helper.c:1409-1450.
// The `.command` adapter exists because Terminal.app has no `-e` flag.
@Suite struct TerminalLaunchTests {
    static let runTemplate = "{terminal} -e {cmd}"
    static let sshTemplate = "{terminal} -e {ssh-client} {host} [-p {port}]"

    /// Records every launch and script write; never touches a process or the disk.
    final class Recorder {
        var launched: [[String]] = []
        var scripts: [(contents: String, mode: Int)] = []
        var launchResult: Result<Void, ApplicationLaunchFailure> = .success(())

        var launcher: CommandLauncher {
            { argv in
                self.launched.append(argv)
                return self.launchResult
            }
        }

        var writer: ScriptWriter {
            { contents, mode in
                self.scripts.append((contents, mode))
                return .success("/tmp/rofi-fixed.command")
            }
        }
    }

    static func failure(_ result: Result<Void, ApplicationLaunchFailure>) -> ApplicationLaunchFailure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    // MARK: plan

    @Test func aSetTerminalPassesThroughUnchanged() throws {
        let plan = try TerminalLaunch.plan(
            terminal: "ghostty", template: Self.runTemplate, values: ["cmd": "htop"])
        #expect(plan == .argv(["ghostty", "-e", "htop"]))
    }

    @Test func aTerminalPathPassesThroughUnchanged() throws {
        let plan = try TerminalLaunch.plan(
            terminal: "/opt/homebrew/bin/kitty", template: Self.runTemplate, values: ["cmd": "htop"])
        #expect(plan == .argv(["/opt/homebrew/bin/kitty", "-e", "htop"]))
    }

    @Test func anUnsetTerminalDefaultsToTheTerminalAppAdapter() throws {
        let values = ["ssh-client": "ssh", "host": "example.org", "port": "2222"]
        let plan = try TerminalLaunch.plan(terminal: nil, template: Self.sshTemplate, values: values)
        #expect(
            plan
                == .terminalScript(
                    appName: "Terminal", innerArgv: ["ssh", "example.org", "-p", "2222"]))
    }

    @Test(arguments: [
        ("Terminal", "Terminal"), ("terminal.app", "Terminal"), ("Terminal.APP", "Terminal"),
        ("iTerm", "iTerm"), ("iTerm2", "iTerm"), ("iterm.app", "iTerm"),
    ])
    func knownTerminalsHitTheAdapterTable(terminal: String, appName: String) throws {
        let plan = try TerminalLaunch.plan(
            terminal: terminal, template: Self.runTemplate, values: ["cmd": "htop"])
        #expect(plan == .terminalScript(appName: appName, innerArgv: ["htop"]))
    }

    @Test(arguments: ["terminalizer", "xterm", "myTerminal", "Terminal2", "/usr/bin/Terminal"])
    func nearMissesDoNotHitTheAdapter(terminal: String) throws {
        let plan = try TerminalLaunch.plan(
            terminal: terminal, template: Self.runTemplate, values: ["cmd": "htop"])
        #expect(plan == .argv([terminal, "-e", "htop"]))
    }

    @Test func aCustomTemplateWithoutDashERunsAsIsEvenForTerminal() throws {
        let plan = try TerminalLaunch.plan(
            terminal: "Terminal", template: "{terminal} --exec {cmd}", values: ["cmd": "htop"])
        #expect(plan == .argv(["Terminal", "--exec", "htop"]))
    }

    @Test func anUnquotedBlankValueSplitsLikeUpstream() throws {
        let plan = try TerminalLaunch.plan(
            terminal: "Terminal", template: Self.runTemplate, values: ["cmd": "top -o cpu"])
        #expect(plan == .terminalScript(appName: "Terminal", innerArgv: ["top", "-o", "cpu"]))
    }

    @Test func aQuotedPlaceholderKeepsOneInnerArgument() throws {
        let plan = try TerminalLaunch.plan(
            terminal: "Terminal", template: "{terminal} -e \"{cmd}\"", values: ["cmd": "top -o cpu"])
        #expect(plan == .terminalScript(appName: "Terminal", innerArgv: ["top -o cpu"]))
    }

    @Test func aTemplateErrorIsThrown() {
        #expect(throws: CommandTemplateError.self) {
            try TerminalLaunch.plan(terminal: "xterm", template: "{terminal} -e 'oops", values: [:])
        }
    }

    // MARK: script text

    @Test func scriptRemovesItselfThenExecsTheQuotedArgv() {
        let text = TerminalLaunch.scriptText(innerArgv: ["ssh", "example.org", "-p", "2222"])
        #expect(text == "#!/bin/sh\nrm -f -- \"$0\"\nexec 'ssh' 'example.org' '-p' '2222'\n")
    }

    @Test func scriptQuotesSpacesQuotesDollarsAndSemicolons() {
        let text = TerminalLaunch.scriptText(innerArgv: ["echo", "a b", "it's", "$HOME", "x;y"])
        #expect(
            text
                == "#!/bin/sh\nrm -f -- \"$0\"\nexec 'echo' 'a b' 'it'\\''s' '$HOME' 'x;y'\n")
    }

    // MARK: launch

    @Test func anArgvPlanSpawnsTheArgvUnchangedWithoutWritingAScript() {
        let recorder = Recorder()
        let result = TerminalLaunch.launch(
            .argv(["ghostty", "-e", "htop"]), launcher: recorder.launcher, writeScript: recorder.writer)
        #expect(Self.failure(result) == nil)
        #expect(recorder.launched == [["ghostty", "-e", "htop"]])
        #expect(recorder.scripts.isEmpty)
    }

    @Test func aScriptPlanWritesA0700ScriptAndOpensItWithTheApp() {
        let recorder = Recorder()
        let plan = LaunchPlan.terminalScript(appName: "Terminal", innerArgv: ["ssh", "example.org"])
        let result = TerminalLaunch.launch(plan, launcher: recorder.launcher, writeScript: recorder.writer)
        #expect(Self.failure(result) == nil)
        #expect(recorder.scripts.count == 1)
        #expect(recorder.scripts.first?.contents == "#!/bin/sh\nrm -f -- \"$0\"\nexec 'ssh' 'example.org'\n")
        #expect(recorder.scripts.first?.mode == 0o700)
        #expect(
            recorder.launched
                == [["/usr/bin/open", "-a", "Terminal", "/tmp/rofi-fixed.command"]])
    }

    @Test func aLauncherFailureIsSurfaced() {
        let recorder = Recorder()
        let failure = ApplicationLaunchFailure(command: "ghostty -e htop", reason: "No such file")
        recorder.launchResult = .failure(failure)
        let result = TerminalLaunch.launch(
            .argv(["ghostty", "-e", "htop"]), launcher: recorder.launcher, writeScript: recorder.writer)
        #expect(Self.failure(result) == failure)
    }

    @Test func aScriptWriteFailureIsSurfacedAndNothingIsLaunched() {
        let recorder = Recorder()
        let failure = ApplicationLaunchFailure(command: "write script", reason: "disk full")
        let result = TerminalLaunch.launch(
            .terminalScript(appName: "Terminal", innerArgv: ["htop"]),
            launcher: recorder.launcher,
            writeScript: { _, _ in .failure(failure) })
        #expect(Self.failure(result) == failure)
        #expect(recorder.launched.isEmpty)
    }
}
