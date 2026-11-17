// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

/// Empty files in `relative` under a fresh temporary directory, removed when
/// the instance goes away.
private final class ConfigFixture {
    let root: String
    let directory: String
    private let made: [String]

    init(_ relative: String, files: [String]) {
        let base = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp/"
        var template = Array(((base.hasSuffix("/") ? base : base + "/") + "rofi-config-XXXXXX").utf8CString)
        root = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        var current = root
        var made: [String] = []
        for component in relative.split(separator: "/") {
            current += "/" + component
            mkdir(current, 0o755)
            made.append(current)
        }
        for file in files {
            fclose(fopen(current + "/" + file, "w"))
            made.append(current + "/" + file)
        }
        directory = current
        self.made = made
    }

    deinit {
        for path in made.reversed() { remove(path) }
        rmdir(root)
    }
}

// Contract: mode list setup in rofi source/rofi.c:795-857, `-show` dispatch in
// source/rofi.c:935-958 and script specs in source/modes/script.c:675-732.
@Suite struct ShowOptionsTests {
    /// No user scripts unless a test gives its own environment.
    private func parse(_ argv: [String], environment: [String: String] = ["HOME": "/nonexistent"]) throws
        -> ShowOptions
    {
        try ShowOptions(arguments: Arguments(["rofi"] + argv), environment: environment)
    }

    private func errors(_ argv: [String]) -> [String] {
        do {
            _ = try parse(argv)
            return []
        } catch {
            return (error as? InvalidModeConfiguration)?.errors ?? ["unexpected \(error)"]
        }
    }

    private func names(_ options: ShowOptions) -> [String] {
        options.modes.map(\.name)
    }

    private let home = String(cString: getenv("HOME"))

    /// g_get_user_cache_dir: `$XDG_CACHE_HOME`, else `~/.cache`.
    private var defaultHistory: String {
        if let xdg = getenv("XDG_CACHE_HOME"), xdg.pointee != 0 { return String(cString: xdg) + "/rofi3.druncache" }
        return home + "/.cache/rofi3.druncache"
    }

    // source/xrmoptions.c:75-86 parses switchers, modi, then modes, so the
    // last of those present wins.
    @Test func modesWinsOverModiWhichWinsOverSwitchers_xrmoptions_c_75() throws {
        #expect(try names(parse(["-switchers", "s:x"])) == ["s"])
        #expect(try names(parse(["-switchers", "s:x", "-modi", "m:x"])) == ["m"])
        #expect(try names(parse(["-modes", "n:x", "-switchers", "s:x", "-modi", "m:x"])) == ["n"])
    }

    // source/rofi.c:812-826: strtok on "," and "#" skips empty tokens and
    // keeps duplicates.
    @Test func listSplitsOnCommaOrHashKeepingDuplicates_rofi_c_812() throws {
        let options = try parse(["-modes", ",a:x#b:y,,a:z,"])
        #expect(
            options.modes == [
                .script(name: "a", path: "x"), .script(name: "b", path: "y"), .script(name: "a", path: "z"),
            ])
    }

    // source/rofi.c:800-807, 648-655: a token naming an already known mode
    // reuses it.
    @Test func bareNameReusesAKnownScriptMode_rofi_c_800() throws {
        let options = try parse(["-modes", "a:./s1,a"])
        #expect(options.modes == [.script(name: "a", path: "./s1"), .script(name: "a", path: "./s1")])
    }

    // source/modes/script.c:695-703: split once on ':'.
    @Test func scriptSpecSplitsOnceOnColon_script_c_695() throws {
        #expect(try parse(["-modes", "a:b:c"]).modes == [.script(name: "a", path: "b:c")])
        #expect(try parse(["-modes", ":p,n:"]).modes == [.script(name: "", path: "p"), .script(name: "n", path: "")])
    }

    // source/helper.c:784-813: `~` and `~user` expand in any path component,
    // and g_build_filenamev drops empty components.
    @Test(arguments: [
        ("~/bin/s", "HOME/bin/s"),
        ("~", "HOME"),
        ("a/~/b", "aHOME/b"),
        ("/usr//bin/", "/usr/bin"),
        ("./s1", "./s1"),
        ("~no-such-user-rofi/s", "~no-such-user-rofi/s"),
        ("~root/s", "/var/root/s"),
    ])
    func scriptPathIsTildeExpanded_helper_c_784(path: String, expected: String) throws {
        let options = try parse(["-modes", "a:" + path])
        // A non-first element's leading separator is dropped, so `a/~/b`
        // joins as `a` + HOME + `/b`.
        let want = expected.split(separator: "HOME", omittingEmptySubsequences: false).joined(separator: home)
        #expect(options.modes == [.script(name: "a", path: want)])
    }

    // source/modes/script.c:636-665, 675-693, 727-731: a bare name runs the
    // user script with that name less its last extension; `name:path` still
    // works, and the built-ins come first (source/rofi.c:795-799).
    @Test func bareNameRunsAUserScript_script_c_677() throws {
        let config = ConfigFixture("rofi/scripts", files: ["foo", "bar.sh", "x.tar.gz", "drun"])
        let environment = ["HOME": "/nonexistent", "XDG_CONFIG_HOME": config.root]
        let options = try parse(["-modes", "foo,bar,x.tar,drun,b:./s", "-show", "foo"], environment: environment)
        #expect(
            options.modes == [
                .script(name: "foo", path: config.directory + "/foo"),
                .script(name: "bar", path: config.directory + "/bar.sh"),
                .script(name: "x.tar", path: config.directory + "/x.tar.gz"),
                .drun(historyPath: defaultHistory),
                .script(name: "b", path: "./s"),
            ])
        #expect(options.startIndex == 0)
        #expect(throws: InvalidModeConfiguration.self) { try parse(["-modes", "bar.sh"], environment: environment) }
    }

    // g_get_user_config_dir: `$XDG_CONFIG_HOME`, else (unset or empty)
    // `$HOME/.config`.
    @Test func userScriptsLiveInTheHomeConfigWithoutXdgConfigHome() throws {
        let home = ConfigFixture(".config/rofi/scripts", files: ["foo"])
        let want: [ModeSpec] = [.script(name: "foo", path: home.directory + "/foo")]
        #expect(try parse(["-modes", "foo"], environment: ["HOME": home.root]).modes == want)
        #expect(
            try parse(["-modes", "foo"], environment: ["HOME": home.root, "XDG_CONFIG_HOME": ""]).modes == want)
        #expect(throws: InvalidModeConfiguration.self) {
            try parse(["-modes", "foo"], environment: ["HOME": home.root, "XDG_CONFIG_HOME": "/nonexistent"])
        }
    }

    // source/rofi.c:547-562, 832-835: a name with no built-in or script spec
    // is an error, listing the built-ins, then the scripts known so far, with
    // `+` on the enabled ones.
    @Test func unknownOrBuiltinNameIsNotFound_rofi_c_546() {
        #expect(
            errors(["-modes", "a:x,windowcd"]) == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * filebrowser\n        * +a\n"
            ])
    }

    // source/rofi.c:832-835, 885-888: every bad token is collected, and setup
    // errors win over `-show`.
    @Test func everyBadTokenIsCollected_rofi_c_885() throws {
        let errors = errors(["-modes", "windowcd,drun,nope", "-show", "a:x"])
        #expect(
            errors == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * filebrowser\n",
                "Mode nope is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * +drun\n        * combi\n        * keys\n        * filebrowser\n",
            ])
    }

    // source/rofi.c:1243-1250, 869-888: config_sanity_check adds its error
    // after setup_modes' and both share one dialog before `-show` is read.
    @Test func matchingErrorFollowsSetupErrorsBeforeShow_rofi_c_885() throws {
        let matching = try #require(errors(["-matching", "bogus"]).first)
        #expect(matching.hasPrefix("The configuration failed to validate:\n\tconfig.matching=bogus"))
        #expect(
            errors(["-modes", "windowcd", "-matching", "bogus", "-show", "nope"]) == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * filebrowser\n",
                matching,
            ])
        #expect(errors(["-modes", "a:x", "-matching", "bogus", "-show", "nope"]) == [matching])
        #expect(try parse(["-matching", "fuzzy"]).match.method == .fuzzy)
    }

    // source/rofi.c:1243-1250, 1271, 869-888: parse_keys_abe's errors come
    // between setup_modes' and config_sanity_check's.
    @Test func bindingErrorsSitBetweenModeAndMatchingErrors_rofi_c_1271() throws {
        let matching = try #require(errors(["-matching", "bogus"]).first)
        let binding = try #require(errors(["-kb-custom-2", "Alt+bogus"]).first)
        #expect(binding.hasPrefix("Failed to set binding Alt+bogus for: Custom keybinding 2 (kb-custom-2)"))
        #expect(
            errors(["-modes", "windowcd", "-matching", "bogus", "-kb-custom-2", "Alt+bogus"]) == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * filebrowser\n",
                binding,
                matching,
            ])
    }

    @Test func bindingOptionsReachTheKeymap() throws {
        let options = try parse(["-kb-custom-1", "Control+1"])

        #expect(options.keymap.action(for: KeyChord(key: "1", modifiers: .control)) == .customKey(1))
    }

    // source/rofi.c:564-595: with no `-show` rofi says so, lists the enabled
    // modes, then the built-ins that are not enabled. Its markup is rendered
    // away.
    @Test func unsureWhatToShowListsTheEnabledModes_rofi_c_564() throws {
        #expect(
            try parse(["-modes", "a:x,b:y,a:z"]).unsureWhatToShow == """
                Rofi is unsure what to show.

                Please specify the mode you want to show.

                    rofi -show {mode}

                The following modes are enabled:
                    • a
                    • b
                    • a

                The following modes can be enabled:
                    • window
                    • run
                    • ssh
                    • drun
                    • combi
                    • keys
                    • filebrowser

                To activate a mode, add it to the list in the modes setting.

                """)
    }

    // source/rofi.c:840-857: the dialog shows two errors, and its count of the
    // rest is off by one.
    @Test func descriptionFollowsTheStartupErrorDialog_rofi_c_840() throws {
        let one = InvalidModeConfiguration(errors: ["E1\n"])
        #expect(one.description == "The following errors were detected when starting rofi:\n\n\nE1\n")
        #expect(one.exitStatus == 65)
        let three = InvalidModeConfiguration(errors: ["E1\n", "E2\n", "E3\n"])
        #expect(three.description == "The following errors were detected when starting rofi:\n\n\nE1\n\n\nE2\n")
        let five = InvalidModeConfiguration(errors: ["E1\n", "E2\n", "E3\n", "E4\n", "E5\n"])
        #expect(five.description.hasSuffix("E2\n\nThere are 2 more errors."))
    }

    // config/config.c:39: upstream's default mode list.
    @Test func defaultModeListIsWindowDrunRunSsh_config_c_39() throws {
        #expect(try parse([]).modes.map(\.name) == ["window", "drun", "run", "ssh"])
        // xrmoptions.c:260-272, 520-521: the window settings.
        let window = try parse([
            "-window-format", "{t}", "-window-match-fields", "title", "-window-command", "yabai {window}",
            "-terminal", "kitty",
        ]).modes.first
        #expect(
            window
                == .window(
                    format: "{t}", matchFields: "title", command: "yabai {window}", terminal: "kitty",
                    runCommand: "{cmd}", runShellCommand: "{terminal} -e {cmd}"))
    }

    // source/rofi.c:935-937, 161-168: `-show` picks the first mode with that
    // exact, case-sensitive name.
    @Test func showPicksTheListedMode_rofi_c_935() throws {
        let options = try parse(["-modes", "a:x,b:y,b:z", "-show", "b"])
        #expect(options.startIndex == 1)
        #expect(options.warnings.isEmpty)
    }

    // source/rofi.c:937-945, 533-545: an unlisted script spec is appended with
    // a warning (printed only when stdout is a terminal).
    @Test func showAppendsAnUnlistedScriptSpecWithAWarning_rofi_c_937() throws {
        let options = try parse(["-modes", "a:x", "-show", "c:./s"])
        #expect(options.modes == [.script(name: "a", path: "x"), .script(name: "c", path: "./s")])
        #expect(options.startIndex == 1)
        #expect(
            options.warnings == [
                "Mode \u{1B}[0;31mc:./s\u{1B}[0m is not enabled. I have enabled it for now.\n"
                    + "Please consider adding \u{1B}[0;31mc:./s\u{1B}[0m to the list of enabled modes: "
                    + "\u{1B}[0;32mmodes: [a:x\u{1B}[0m\u{1B}[0;31m,c:./s]\u{1B}[0m.\n"
            ])
    }

    // source/rofi.c:161-168: lookup is by mode name, so a full spec that is
    // already listed is appended again.
    @Test func showWithAListedFullSpecAppendsItAgain_rofi_c_161() throws {
        let options = try parse(["-modes", "a:x", "-show", "a:x"])
        #expect(names(options) == ["a", "a"])
        #expect(options.startIndex == 1)
        #expect(options.warnings.count == 1)
    }

    // source/rofi.c:946-950: an unknown `-show` name is an error.
    @Test func showUnknownNameIsAnError_rofi_c_946() {
        #expect(
            errors(["-modes", "a:x", "-show", "windowcd"]) == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * filebrowser\n        * +a\n"
            ])
    }

    // source/helper.c:325-342: find_arg_str takes the next argument even when
    // it looks like an option.
    @Test func showTakesTheNextArgumentVerbatim() {
        #expect(errors(["-show", "-modes", "a:x"]).first?.hasPrefix("Mode -modes is not found.") == true)
    }

    // source/rofi.c:952-953: a bare trailing `-show` runs the first mode.
    @Test func bareShowRunsTheFirstMode_rofi_c_952() throws {
        #expect(try parse(["-modes", "a:x,b:y", "-show"]).startIndex == 0)
        #expect(try parse(["-show"]).startIndex == 0)
    }

    // source/rofi.c:952-958, 564-595: no `-show`, or a bare one with no modes,
    // leaves rofi unsure what to show.
    @Test func noShowLeavesTheStartUnset_rofi_c_954() throws {
        #expect(try parse(["-modes", "a:x"]).startIndex == nil)
        #expect(try parse(["-modes", "", "-show"]).startIndex == nil)
    }

    // source/mode.c:189-208: `-display-<name>` replaces the name in the chrome.
    @Test func displayNamesComeFromDisplayOptions_mode_c_189() throws {
        let options = try parse(["-modes", "a:x,b:y,a:z", "-DISPLAY-a", "Apps", "-display-a", "Other"])
        #expect(options.displayNames == ["Apps", "b", "Apps"])
    }

    // source/xrmoptions.c:385-395, config/config.c:119.
    @Test func sidebarModeIsABooleanOffByDefault_xrmoptions_c_391() throws {
        #expect(try !parse([]).sidebarMode)
        #expect(try parse(["-sidebar-mode"]).sidebarMode)
        #expect(try !parse(["-no-sidebar-mode"]).sidebarMode)
    }

    // source/xrmoptions.c:145; on by default, unlike config/config.c:47.
    @Test func showIconsIsABooleanOnByDefault_xrmoptions_c_145() throws {
        #expect(try parse([]).showIcons)
        #expect(try parse(["-show-icons"]).showIcons)
        #expect(try !parse(["-no-show-icons"]).showIcons)
    }

    // config/config.c:111 and source/xrmoptions.c:364-370: `-show` matching
    // is case-insensitive unless `-case-sensitive`; dmenu alone forces it on
    // without `-i` (source/modes/dmenu.c:605-608).
    @Test func showMatchingHonorsCaseSensitive_config_c_111() throws {
        #expect(try !MatchOptions(arguments: Arguments(["rofi"])).caseSensitive)
        #expect(try MatchOptions(arguments: Arguments(["rofi", "-case-sensitive"])).caseSensitive)
        let options = try MatchOptions(arguments: Arguments(["rofi", "-matching", "fuzzy", "-no-tokenize"]))
        #expect(options.method == .fuzzy)
        #expect(!options.tokenize)
        #expect(try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"])).match.caseSensitive)
        #expect(
            try !DmenuPipeline(arguments: Arguments(["rofi", "-dmenu", "-case-sensitive", "-i"])).match.caseSensitive)
    }

    @Test func showSortingOptionsAreParsedAndValidated() throws {
        let options = try parse(["-sort", "-sorting-method", "fzf"])

        #expect(options.sort)
        #expect(options.sortingMethod == .fzf)
        #expect(try !parse(["-no-sort"]).sort)
        #expect(try parse([]).cycle)
        #expect(try !parse(["-no-cycle"]).cycle)
        #expect(errors(["-sorting-method", "fzf-v2"]).first?.contains("fzf-v2") == true)
    }

    // source/modes/filebrowser.c:729: `filebrowser` is a built-in mode name,
    // so `-show` enables an unlisted one with the usual warning.
    @Test func showResolvesTheFilebrowserBuiltin_filebrowser_c_729() throws {
        let options = try parse(["-modes", "drun", "-show", "filebrowser"])
        #expect(options.modes.last == .fileBrowser(directory: nil, showHidden: false))
        #expect(options.modes.map(\.name) == ["drun", "filebrowser"])
        #expect(options.startIndex == 1)
        #expect(options.warnings.count == 1)
    }

    // source/rofi.c:795-826: the mode list resolves built-ins and scripts
    // side by side, and a listed built-in raises no warning.
    @Test func modesListMixesFilebrowserAndScripts_rofi_c_795() throws {
        let options = try parse(["-modes", "a:x,filebrowser", "-show", "filebrowser"])
        #expect(options.modes == [.script(name: "a", path: "x"), .fileBrowser(directory: nil, showHidden: false)])
        #expect(options.startIndex == 1)
        #expect(options.warnings.isEmpty)
    }

    // source/modes/filebrowser.c:395-405: `directory` and `show-hidden`.
    // ponytail: upstream reads them from the theme; here they are flags.
    @Test func filebrowserOptionsAreRead_filebrowser_c_395() throws {
        let options = try parse([
            "-modes", "filebrowser", "-filebrowser-directory", "/tmp", "-filebrowser-show-hidden",
        ])
        #expect(options.modes == [.fileBrowser(directory: "/tmp", showHidden: true)])
        #expect(
            try parse(["-modes", "filebrowser", "-no-filebrowser-show-hidden"]).modes
                == [.fileBrowser(directory: nil, showHidden: false)])
    }

    // source/mode.c:189-208: `-display-filebrowser` renames the chrome.
    @Test func filebrowserHonorsDisplayOption_mode_c_189() throws {
        let options = try parse(["-modes", "filebrowser", "-display-filebrowser", "Files"])
        #expect(options.displayNames == ["Files"])
    }

    // source/rofi.c:795-826: one mode is made per list entry.
    @Test func makeModesBuildsTheFilebrowser_rofi_c_795() {
        let modes = makeModes([.fileBrowser(directory: "/", showHidden: false)])
        #expect(modes.count == 1)
        #expect((modes[0] as? FileBrowserMode)?.currentDirectory == "/")
    }

    // source/rofi.c:547-562, 564-595, 718-739: an enabled filebrowser gets
    // its `+` and is no longer offered as one that can be enabled.
    @Test func enabledFilebrowserIsMarkedAndNotOffered_rofi_c_547() throws {
        #expect(
            errors(["-modes", "filebrowser,windowcd"]) == [
                "Mode windowcd is not found.\nThe following modes are known:\n        * window\n        * run\n        * ssh\n        * drun\n        * combi\n        * keys\n        * +filebrowser\n"
            ])
        let unsure = try parse(["-modes", "filebrowser"]).unsureWhatToShow
        #expect(
            unsure.contains(
                "enabled:\n    • filebrowser\n\nThe following modes can be enabled:\n    • window\n    • run\n    • ssh\n    • drun\n    • combi\n    • keys\n\nTo activate"
            ))
    }

    // source/rofi.c:732-739: drun is a built-in, registered after ssh;
    // listed by default it starts with no warning.
    @Test func showResolvesTheDrunBuiltin_rofi_c_735() throws {
        let options = try parse(["-show", "drun"])
        #expect(options.modes[1] == .drun(historyPath: defaultHistory))
        #expect(options.startIndex == 1)
        #expect(options.warnings.isEmpty)
        #expect(options.availableModes.map(\.name) == ["window", "run", "ssh", "drun", "combi", "keys", "filebrowser"])
    }

    // source/modes/drun.c:883-893, source/rofi.c:1227-1231: the history
    // lives in `-cache-dir`, tilde-expanded; `-disable-history` drops it
    // (config/config.c:103).
    @Test func drunHistoryFollowsCacheDirAndDisableHistory_drun_c_883() throws {
        #expect(
            try parse(["-modes", "drun", "-cache-dir", "/tmp/c"]).modes == [
                .drun(historyPath: "/tmp/c/rofi3.druncache")
            ])
        #expect(
            try parse(["-modes", "drun", "-cache-dir", "~/c"]).modes == [
                .drun(historyPath: home + "/c/rofi3.druncache")
            ])
        #expect(try parse(["-modes", "drun", "-disable-history"]).modes == [.drun(historyPath: nil)])
    }

    // MARK: run (source/modes/run.c:64, config/config.c:65-74)

    private var runHistory: String {
        if let xdg = getenv("XDG_CACHE_HOME"), xdg.pointee != 0 { return String(cString: xdg) + "/rofi-4.runcache" }
        return home + "/.cache/rofi-4.runcache"
    }

    private let defaultRun = ModeSpec.run(
        historyPath: nil, terminal: nil, runCommand: "{cmd}", runShellCommand: "{terminal} -e {cmd}")

    // source/rofi.c:732-739: run is a built-in, registered before drun, and
    // keeps its own cache file next to drun's.
    @Test func runIsABuiltinWithItsOwnHistoryFile_run_c_64() throws {
        let options = try parse(["-modes", "run,drun"])
        #expect(
            options.modes == [
                .run(
                    historyPath: runHistory, terminal: nil, runCommand: "{cmd}",
                    runShellCommand: "{terminal} -e {cmd}"),
                .drun(historyPath: defaultHistory),
            ])
        #expect(options.modes.map(\.name) == ["run", "drun"])
    }

    // source/rofi.c:935-937: run and ssh are in the default list, so `-show`
    // starts on them with no warning.
    @Test func showRunOrSshStartsInTheDefaultList_rofi_c_935() throws {
        let run = try parse(["-show", "run"])
        let ssh = try parse(["-show", "ssh"])
        #expect(run.modes.map(\.name) == ["window", "drun", "run", "ssh"])
        #expect(run.startIndex == 2)
        #expect(ssh.startIndex == 3)
        #expect(run.warnings.isEmpty && ssh.warnings.isEmpty)
    }

    // config/config.c:65-74, source/xrmoptions.c: the three command options.
    @Test func runReadsItsCommandOptions_config_c_65() throws {
        let options = try parse([
            "-modes", "run", "-terminal", "ghostty", "-run-command", "env {cmd}", "-run-shell-command",
            "{terminal} --hold {cmd}", "-cache-dir", "/tmp/c",
        ])
        #expect(
            options.modes == [
                .run(
                    historyPath: "/tmp/c/rofi-4.runcache", terminal: "ghostty", runCommand: "env {cmd}",
                    runShellCommand: "{terminal} --hold {cmd}")
            ])
    }

    // source/xrmoptions.c:244, config/config.c:72: `-run-list-command`; nil
    // when absent.
    @Test func runReadsItsListCommand_xrmoptions_c_244() throws {
        let options = try parse(["-modes", "run", "-run-list-command", "ls ~/bin", "-cache-dir", "/tmp/c"])
        #expect(
            options.modes == [
                .run(
                    historyPath: "/tmp/c/rofi-4.runcache", terminal: nil, runCommand: "{cmd}",
                    runShellCommand: "{terminal} -e {cmd}", listCommand: "ls ~/bin")
            ])
        let absent = try parse(["-modes", "run", "-cache-dir", "/tmp/c"])
        guard case .run(_, _, _, _, let listCommand) = absent.modes[0] else {
            Issue.record("not a run spec")
            return
        }
        #expect(listCommand == nil)
    }

    // config/config.c:103: no history path at all.
    @Test func disableHistoryDropsTheRunHistory_config_c_103() throws {
        #expect(try parse(["-modes", "run", "-disable-history"]).modes == [defaultRun])
    }

    // MARK: ssh (source/modes/ssh.c:83, config/config.c:64-68, 122-125)

    private var sshHistory: String {
        if let xdg = getenv("XDG_CACHE_HOME"), xdg.pointee != 0 { return String(cString: xdg) + "/rofi-2.sshcache" }
        return home + "/.cache/rofi-2.sshcache"
    }

    // source/rofi.c:732-739: ssh is a built-in between run and drun, with its
    // own cache file and upstream's defaults.
    @Test func sshIsABuiltinWithItsOwnHistoryFile_ssh_c_83() throws {
        let options = try parse(["-modes", "ssh,drun"])
        #expect(
            options.modes == [
                .ssh(
                    historyPath: sshHistory, terminal: nil, sshCommand: "{terminal} -e {ssh-client} {host} [-p {port}]",
                    sshClient: "ssh", parseHosts: false, parseKnownHosts: true),
                .drun(historyPath: defaultHistory),
            ])
        #expect(options.availableModes.map(\.name) == ["window", "run", "ssh", "drun", "combi", "keys", "filebrowser"])
    }

    // source/xrmoptions.c:212-234, 335, 423-436, 595: the ssh options.
    @Test func sshReadsItsOptions_xrmoptions_c_228() throws {
        let options = try parse([
            "-modes", "ssh", "-terminal", "ghostty", "-ssh-command", "{terminal} -e {ssh-client} -A {host}",
            "-ssh-client", "mosh", "-parse-hosts", "-no-parse-known-hosts", "-cache-dir", "/tmp/c",
        ])
        #expect(
            options.modes == [
                .ssh(
                    historyPath: "/tmp/c/rofi-2.sshcache", terminal: "ghostty",
                    sshCommand: "{terminal} -e {ssh-client} -A {host}", sshClient: "mosh", parseHosts: true,
                    parseKnownHosts: false)
            ])
        guard case .ssh(let historyPath, _, _, _, _, _) = try parse(["-modes", "ssh", "-disable-history"]).modes[0]
        else {
            Issue.record("not an ssh spec")
            return
        }
        #expect(historyPath == nil)
    }
}
