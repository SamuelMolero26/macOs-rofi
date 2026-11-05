import Darwin
import RofiCore
import Testing

/// Executable `/bin/sh` fixtures in a fresh temporary directory, removed when
/// the suite instance goes away.
private final class Fixtures {
    let directory: String
    private var files: [String] = []

    init() {
        let base = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp/"
        var template = Array(((base.hasSuffix("/") ? base : base + "/") + "rofi-script-XXXXXX").utf8CString)
        directory = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }

    deinit {
        for file in files { unlink(file) }
        rmdir(directory)
    }

    /// Writes `body` after a `#!/bin/sh` line and returns the script's path.
    func script(_ name: String, _ body: String) -> String {
        let path = directory + "/" + name
        let file = fopen(path, "w")!
        fputs("#!/bin/sh\n" + body + "\n", file)
        fclose(file)
        chmod(path, 0o755)
        files.append(path)
        return path
    }
}

/// Rows printed on every run after the first, describing how it was run.
private let reportRun = """
    if [ "$ROFI_RETV" != 0 ]; then
      echo "retv=$ROFI_RETV"
      echo "argc=$#"
      echo "arg=$1"
      echo "info=${ROFI_INFO-unset}"
      echo "data=${ROFI_DATA-unset}"
      echo "input=${ROFI_INPUT-unset}"
      exit
    fi
    """

// Contract: rofi's script mode, source/modes/script.c (execute_executor
// 197-320, parse_header_entry 148-195, script_mode_result 370-454,
// script_token_match 515-554).
@Suite struct ScriptModeTests {
    private let fixtures = Fixtures()

    private func texts(_ mode: ScriptMode) -> [String] {
        mode.rows.map(\.text)
    }

    /// Runs `action` and returns the result with the rewritten input.
    private func perform(
        _ mode: ScriptMode, _ action: MenuAction, input: String? = "query", row: Int? = nil
    ) -> (result: ModeResult, input: String?) {
        var input = input
        let result = mode.result(action, input: &input, selectedRow: row)
        return (result, input)
    }

    // script.c:215-232, 337: the first run gets no argument, ROFI_RETV=0,
    // ROFI_OUTSIDE=rofi's pid and no ROFI_INPUT.
    @Test func initialRunHasNoArgument_script_c_337() {
        let path = fixtures.script(
            "s", #"echo "retv=$ROFI_RETV argc=$# input=${ROFI_INPUT-unset} outside=$ROFI_OUTSIDE""#)
        let mode = ScriptMode(name: "s", command: path)
        #expect(mode.name == "s")
        #expect(texts(mode) == ["retv=0 argc=0 input=unset outside=\(getpid())"])
        #expect(mode.error == nil)
    }

    // script.c:299-303: extras after the first NUL use the dmenu row parser.
    @Test func rowsCarryExtras_script_c_299() {
        let path = fixtures.script("s", #"printf 'one\000info\037i1\037meta\037m1\037display\037One\nplain\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        #expect(texts(mode) == ["one", "plain"])
        #expect(mode.rows[0].info == "i1")
        #expect(mode.rows[0].meta == "m1")
        #expect(mode.rows[0].display == "One")
        #expect(mode.rows[1].info == nil)
    }

    // script.c:258-265: a trailing delimiter is stripped, an empty record is
    // read as an empty header and dropped, and a last unterminated row counts.
    @Test func emptyRecordsAreDropped_script_c_264() {
        let path = fixtures.script("s", #"printf 'a\n\nb\n\nc'"#)
        #expect(texts(ScriptMode(name: "s", command: path)) == ["a", "b", "c"])
    }

    @Test func rowTextIsForcedToUTF8() {
        let path = fixtures.script("s", #"printf '\377x\n'"#)
        #expect(texts(ScriptMode(name: "s", command: path)) == ["\u{FFFD}x"])
    }

    // script.c:158-164, 183-185: prompt, message and data headers.
    @Test func promptMessageAndDataHeaders_script_c_158() {
        let path = fixtures.script("s", #"printf '\000prompt\037Pick\n\000MESSAGE\037Hello\n\000data\037d1\nrow\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        #expect(mode.displayName == "Pick")
        #expect(mode.message == "Hello", "header keys are case-insensitive")
        #expect(texts(mode) == ["row"])
    }

    // script.c:160: an empty message clears it.
    @Test func emptyMessageIsNil_script_c_160() {
        let path = fixtures.script("s", #"printf '\000message\037\nrow\n'"#)
        #expect(ScriptMode(name: "s", command: path).message == nil)
    }

    // script.c:155: a header needs a byte after its \x1f, where the stripped
    // delimiter counts. Without a \x1f, or with nothing after it at the end
    // of the output, it is ignored.
    @Test func headerNeedsRoomForAValue_script_c_155() {
        let cut = ScriptMode(name: "c", command: fixtures.script("c", #"printf 'row\n\000message\n\000prompt\037'"#))
        #expect(cut.displayName == nil)
        #expect(cut.message == nil)
        #expect(texts(cut) == ["row"])

        let empty = ScriptMode(name: "e", command: fixtures.script("e", #"printf '\000prompt\037\n\000data\037EOF'"#))
        #expect(empty.displayName == "", "an empty prompt still replaces the name")
        #expect(texts(empty).isEmpty)
    }

    // script.c:171-172, 258: delim takes effect for the next record and
    // persists into later runs.
    @Test func delimHeaderSplitsLaterRecords_script_c_171() {
        let path = fixtures.script(
            "s",
            """
            if [ "$ROFI_RETV" = 0 ]; then printf '\\000delim\\037|\\na|b\\nc|'; else printf 'x|y|'; fi
            """)
        let mode = ScriptMode(name: "s", command: path)
        #expect(texts(mode) == ["a", "b\nc"])
        _ = perform(mode, .ok, row: 0)
        #expect(texts(mode) == ["x", "y"])
    }

    // Headers that are parsed but not implemented never become rows.
    @Test func otherHeadersAreNotRows() {
        let path = fixtures.script(
            "s", #"printf '\000markup-rows\037true\n\000urgent\0370\n\000keep-filter\037true\nrow\n'"#)
        #expect(texts(ScriptMode(name: "s", command: path)) == ["row"])
    }

    // script.c:405-412, 223-232, 431-451: accepting a row re-runs the script
    // with its text, ROFI_RETV=1, its info, the data header and the input;
    // the new rows reload, the input is cleared and row 0 selected.
    @Test func acceptReRunsWithTheRow_script_c_405() {
        let path = fixtures.script("s", reportRun + #"\#nprintf '\000data\037d1\nfirst\nsecond\000info\037i2\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        let (result, input) = perform(mode, .ok, input: "sec", row: 1)
        #expect(result == .reload)
        #expect(input == nil)
        #expect(mode.selectedRowAfterResult == 0)
        #expect(texts(mode) == ["retv=1", "argc=1", "arg=second", "info=i2", "data=d1", "input=sec"])
    }

    // script.c:413-416: custom input runs with the typed text, ROFI_RETV=2
    // and no row info.
    @Test func customInputReRunsWithTheText_script_c_413() {
        let path = fixtures.script("s", reportRun + "\necho row")
        let mode = ScriptMode(name: "s", command: path)
        let (result, input) = perform(mode, .customInput, input: "typed text")
        #expect(result == .reload)
        #expect(input == nil)
        #expect(texts(mode) == ["retv=2", "argc=1", "arg=typed text", "info=unset", "data=unset", "input=typed text"])
    }

    // script.c:173-174, 417-418: no-custom refuses custom input with a reload
    // that keeps the input and rows.
    @Test func noCustomRefusesCustomInput_script_c_417() {
        let path = fixtures.script("s", reportRun + #"\#nprintf '\000no-custom\037true\nrow\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        let (result, input) = perform(mode, .customInput, input: "typed")
        #expect(result == .reload)
        #expect(input == "typed")
        #expect(mode.selectedRowAfterResult == nil)
        #expect(texts(mode) == ["row"])
    }

    // script.c:406-408: a nonselectable row reloads without running.
    @Test func nonselectableRowReloads_script_c_406() {
        let path = fixtures.script("s", reportRun + #"\#nprintf 'title\000nonselectable\037true\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        let (result, input) = perform(mode, .ok, row: 0)
        #expect(result == .reload)
        #expect(input == "query")
        #expect(texts(mode) == ["title"])
    }

    // script.c:373, 431: a run that prints no rows exits, headers or not.
    @Test func noRowsExit_script_c_431() {
        let path = fixtures.script("s", #"[ "$ROFI_RETV" = 0 ] && echo row || printf '\000message\037bye\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        let (result, _) = perform(mode, .ok, row: 0)
        #expect(result == .exit)
    }

    // script.c:373: cancel matches no branch and exits without running.
    @Test func cancelExits() {
        let path = fixtures.script("s", reportRun + "\necho row")
        let mode = ScriptMode(name: "s", command: path)
        #expect(perform(mode, .cancel).result == .exit)
        #expect(texts(mode) == ["row"])
    }

    // script.c:400-404: deleting a row runs with ROFI_RETV=3.
    @Test func deleteEntryRunsWithRetv3_script_c_400() {
        let path = fixtures.script("s", reportRun + "\necho row")
        let mode = ScriptMode(name: "s", command: path)
        #expect(perform(mode, .deleteEntry, row: 0).result == .reload)
        #expect(texts(mode).prefix(3) == ["retv=3", "argc=1", "arg=row"])
    }

    // script.c:380-399: a custom key without use-hot-keys answers its index,
    // a mode to switch to; with use-hot-keys it runs with ROFI_RETV=10+index.
    @Test func customKeys_script_c_380() {
        let plain = ScriptMode(name: "p", command: fixtures.script("p", reportRun + "\necho row"))
        #expect(perform(plain, .customKey(2), row: 0).result == .switchTo(2))
        #expect(texts(plain) == ["row"])

        let hot = ScriptMode(
            name: "h", command: fixtures.script("h", reportRun + #"\#nprintf '\000use-hot-keys\037true\nrow\n'"#))
        #expect(perform(hot, .customKey(2), row: 0).result == .reload)
        #expect(texts(hot).prefix(3) == ["retv=12", "argc=1", "arg=row"])
    }

    // script.c:234-237: the command is split like a shell would, without a
    // shell, and the argument is appended.
    @Test func commandIsShellParsed_script_c_234() {
        let path = fixtures.script("s", #"echo "argc=$#"; for a in "$@"; do echo "[$a]"; done"#)
        let mode = ScriptMode(name: "s", command: "'\(path)' \"two words\" x\\ y # comment")
        #expect(texts(mode) == ["argc=2", "[two words]", "[x y]"])
        _ = perform(mode, .ok, row: 1)
        #expect(texts(mode) == ["argc=3", "[two words]", "[x y]", "[[two words]]"])
    }

    // script.c:238: stdin is /dev/null, the working directory is rofi's.
    @Test func stdinIsEmptyAndCwdIsInherited() {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let cwd = String(cString: getcwd(&buffer, buffer.count))
        let path = fixtures.script("s", #"echo "in=$(cat | wc -c | tr -d ' ')"; pwd -P"#)
        let mode = ScriptMode(name: "s", command: path)
        #expect(texts(mode).first == "in=0")
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(texts(mode).last == String(cString: realpath(cwd, &resolved)))
    }

    // script.c:242-250: a script that cannot run yields no rows and an error
    // for rofi's error dialog.
    @Test func unrunnableScriptReportsAnError_script_c_242() {
        let path = fixtures.directory + "/missing"
        let mode = ScriptMode(name: "m", command: path)
        #expect(mode.rows.isEmpty)
        #expect(
            mode.error == """
                Failed to execute: '\(path)'
                Error: 'Failed to execute child process “\(path)” (No such file or directory)'
                """)

        let quoted = ScriptMode(name: "q", command: "'open")
        #expect(quoted.rows.isEmpty)
        #expect(
            quoted.error == """
                Failed to execute: ''open'
                Error: 'Text ended before matching quote was found for '. (The text was “'open”)'
                """)
    }

    // script.c:521-541: permanent rows always match; a token the text misses
    // is retried on meta.
    @Test func matchingUsesMetaAndPermanent_script_c_521() {
        let path = fixtures.script("s", #"printf 'firefox\000meta\037browser web\nnotes\nhelp\000permanent\037true\n'"#)
        let mode = ScriptMode(name: "s", command: path)
        let matcher = Matcher(query: "fox web", options: MatchOptions())
        #expect(mode.rows.map { mode.matches($0, matcher: matcher) } == [true, false, true])
    }

    @Test func modesAreMadeFromTheModeList() {
        let path = fixtures.script("s", "echo row")
        let modes = makeModes([.script(name: "a", path: path), .script(name: "b", path: path)])
        #expect(modes.map(\.name) == ["a", "b"])
        #expect(modes.allSatisfy { $0 is ScriptMode && $0.rows.map(\.text) == ["row"] })
    }

    @Test func drunAssemblyReceivesApplicationRecordsAndPropagatesItsLauncherFailure() throws {
        let application = ApplicationRecord(
            identifier: "com.example.discovered", localizedDisplayName: "Discovered",
            bundleName: nil, bundlePath: "/Applications/Discovered.app",
            iconPath: "/icons/Discovered.icns")
        let failure = ApplicationLaunchFailure(
            command: "open application '/Applications/Discovered.app'", reason: "refused")
        var loadCount = 0
        var launched: [ApplicationRecord] = []

        let modes = makeModes(
            [.drun(historyPath: nil)],
            applications: {
                loadCount += 1
                return [application]
            },
            launcher: { record in
                launched.append(record)
                return .failure(failure)
            })
        let mode = try #require(modes.first as? DrunMode)

        #expect(loadCount == 1)
        #expect(mode.rows.map(\.text) == ["Discovered"])
        #expect(mode.iconPath(at: 0) == "/icons/Discovered.icns")
        var input: String?
        #expect(mode.result(.ok, input: &input, selectedRow: 0) == .reload)
        #expect(launched == [application])
        #expect(mode.message == failure.dialogText)
    }

    @Test func modeSelectionKeepsFileBrowserIndependentFromNativeApplications() throws {
        let browserEntry = fixtures.script("browser-entry", "echo row")
        let options = try ShowOptions(
            arguments: Arguments([
                "rofi", "-modes", "filebrowser", "-show", "drun",
                "-filebrowser-directory", fixtures.directory,
            ]))
        var loadCount = 0
        let application = ApplicationRecord(
            identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")

        let modes = makeModes(
            options.modes,
            applications: {
                loadCount += 1
                return [application]
            },
            launcher: { _ in .success(()) })

        #expect(options.startIndex == 1)
        #expect(modes.map(\.name) == ["filebrowser", "drun"])
        #expect(loadCount == 1)
        let fileBrowser = try #require(modes[0] as? FileBrowserMode)
        let drun = try #require(modes[1] as? DrunMode)
        let browserRow = try #require(fileBrowser.rows.firstIndex { $0.text == "browser-entry" })
        #expect(fileBrowser.iconPath(at: browserRow) == browserEntry)
        #expect(drun.iconPath(at: 0) == "/Applications/Example.app")

        loadCount = 0
        _ = makeModes(
            [.fileBrowser(directory: fixtures.directory, showHidden: false)],
            applications: {
                loadCount += 1
                return [application]
            },
            launcher: { _ in .success(()) })
        #expect(loadCount == 0)

        let defaults = try ShowOptions(arguments: Arguments(["rofi", "-show", "drun"]))
        #expect(defaults.modes.map(\.name) == ["drun"])
        #expect(defaults.startIndex == 0)
    }

    // The proof mode: two scripts in one switcher, with prompts from their
    // headers, switching and accepting.
    @Test func switcherMovesBetweenTwoScripts() {
        let a = fixtures.script("a", #"printf '\000prompt\037Fruit\napple\nbanana\n'"#)
        let b = fixtures.script("b", reportRun + #"\#nprintf 'band\nbee\nbeetle\n'"#)
        var s = ModeSwitcher(modes: makeModes([.script(name: "a", path: a), .script(name: "b", path: b)]))
        #expect(s.prompt == "Fruit")
        #expect(s.matches.map(\.row.text) == ["apple", "banana"])

        s.updateQuery("bee")
        s.next()
        #expect(s.prompt == "b")
        #expect(s.matches.map(\.row.text) == ["bee", "beetle"])

        s.selectVisibleIndex(1)
        let open = s.accept()
        #expect(open)
        #expect(s.query == "")
        #expect(s.selectedVisibleIndex == 0)
        #expect(
            s.matches.map(\.row.text) == ["retv=1", "argc=1", "arg=beetle", "info=unset", "data=unset", "input=bee"])

        s.previous()
        #expect(s.prompt == "Fruit")
        let stillOpen = s.cancel()
        #expect(!stillOpen)
    }
}
