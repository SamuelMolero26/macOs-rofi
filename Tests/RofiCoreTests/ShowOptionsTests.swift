// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

// Contract: mode list setup in rofi source/rofi.c:795-857, `-show` dispatch in
// source/rofi.c:935-958 and script specs in source/modes/script.c:675-732.
@Suite struct ShowOptionsTests {
    private func parse(_ argv: [String]) throws -> ShowOptions {
        try ShowOptions(arguments: Arguments(["rofi"] + argv))
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

    // source/rofi.c:547-562, 832-835: a name with no built-in or script spec
    // is an error, listing the built-ins, then the scripts known so far, with
    // `+` on the enabled ones.
    @Test func unknownOrBuiltinNameIsNotFound_rofi_c_546() {
        #expect(
            errors(["-modes", "a:x,run"]) == [
                "Mode run is not found.\nThe following modes are known:\n        * filebrowser\n        * +a\n"
            ])
    }

    // source/rofi.c:832-835, 885-888: every bad token is collected, and setup
    // errors win over `-show`.
    @Test func everyBadTokenIsCollected_rofi_c_885() throws {
        let errors = errors(["-modes", "run,drun", "-show", "a:x"])
        #expect(
            errors == [
                "Mode run is not found.\nThe following modes are known:\n        * filebrowser\n",
                "Mode drun is not found.\nThe following modes are known:\n        * filebrowser\n",
            ])
    }

    // source/rofi.c:1243-1250, 869-888: config_sanity_check adds its error
    // after setup_modes' and both share one dialog before `-show` is read.
    @Test func matchingErrorFollowsSetupErrorsBeforeShow_rofi_c_885() throws {
        let matching = try #require(errors(["-matching", "bogus"]).first)
        #expect(matching.hasPrefix("The configuration failed to validate:\n\tconfig.matching=bogus"))
        #expect(
            errors(["-modes", "run", "-matching", "bogus", "-show", "nope"]) == [
                "Mode run is not found.\nThe following modes are known:\n        * filebrowser\n",
                matching,
            ])
        #expect(errors(["-modes", "a:x", "-matching", "bogus", "-show", "nope"]) == [matching])
        #expect(try parse(["-matching", "fuzzy"]).match.method == .fuzzy)
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

    // ponytail: upstream's default `window,drun,run,ssh` (config/config.c:36-42)
    // filtered to implemented modes is empty for now.
    @Test func defaultModeListIsEmpty() throws {
        #expect(try parse([]).modes.isEmpty)
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
            errors(["-modes", "a:x", "-show", "run"]) == [
                "Mode run is not found.\nThe following modes are known:\n        * filebrowser\n        * +a\n"
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
    }

    // source/rofi.c:952-958, 564-595: no `-show`, or a bare one with no modes,
    // leaves rofi unsure what to show.
    @Test func noShowLeavesTheStartUnset_rofi_c_954() throws {
        #expect(try parse(["-modes", "a:x"]).startIndex == nil)
        #expect(try parse(["-modes", "", "-show"]).startIndex == nil)
        #expect(try parse(["-show"]).startIndex == nil)
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

    // source/modes/filebrowser.c:729: `filebrowser` is a built-in mode name,
    // so `-show` enables it with the usual warning.
    @Test func showResolvesTheFilebrowserBuiltin_filebrowser_c_729() throws {
        let options = try parse(["-show", "filebrowser"])
        #expect(options.modes == [.fileBrowser(directory: nil, showHidden: false)])
        #expect(options.modes.map(\.name) == ["filebrowser"])
        #expect(options.startIndex == 0)
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
            errors(["-modes", "filebrowser,run"]) == [
                "Mode run is not found.\nThe following modes are known:\n        * +filebrowser\n"
            ])
        let unsure = try parse(["-modes", "filebrowser"]).unsureWhatToShow
        #expect(unsure.contains("enabled:\n    • filebrowser\n\nThe following modes can be enabled:\n\nTo activate"))
    }
}
