import Foundation

/// One entry of the mode list: a script mode or a built-in.
public enum ModeSpec: Equatable, Sendable {
    /// `window` (source/modes/window.c:1149) with `-window-format`,
    /// `-window-match-fields` and `-window-command` (config/config.c:76, 147,
    /// 155), plus the `-terminal`, `-run-command` and `-run-shell-command`
    /// its typed commands use (window.c:838-857).
    case window(
        format: String, matchFields: String, command: String, terminal: String?, runCommand: String,
        runShellCommand: String)
    /// `run` (source/modes/run.c:599) with its history file, nil when
    /// `-disable-history` is set, and the `-terminal`, `-run-command` and
    /// `-run-shell-command` settings (config/config.c:65-74); a nil terminal
    /// means Terminal.app. `listCommand` is `-run-list-command`
    /// (source/xrmoptions.c:244), nil when absent.
    case run(
        historyPath: String?, terminal: String?, runCommand: String, runShellCommand: String,
        listCommand: String? = nil)
    /// `ssh` (source/modes/ssh.c:710) with its history file, nil when
    /// `-disable-history` is set, `-terminal` (nil means Terminal.app),
    /// `-ssh-command`, `-ssh-client`, `-parse-hosts` and `-parse-known-hosts`
    /// (config/config.c:64-68, 122-125).
    case ssh(
        historyPath: String?, terminal: String?, sshCommand: String, sshClient: String, parseHosts: Bool,
        parseKnownHosts: Bool)
    /// `drun` (source/modes/drun.c:1693) with its history file, nil when
    /// `-disable-history` is set (drun.c:883-893, config/config.c:103).
    case drun(historyPath: String?)
    /// `combi` (source/modes/combi.c:345) with the modes of `-combi-modes`,
    /// each one's `-display-<name>` or name, and `-combi-display-format`, nil
    /// under `-combi-hide-mode-prefix` (config/config.c:127, 162-163).
    case combi(modes: [ModeSpec], displayNames: [String], displayFormat: String?)
    /// `keys` (source/modes/help-keys.c:113) listing the effective bindings.
    case keys(keymap: Keymap)
    /// `filebrowser` (source/modes/filebrowser.c:729) with its `directory` and
    /// `show-hidden` settings (395-405, 422-453); nil directory means home.
    case fileBrowser(directory: String?, showHidden: Bool)
    /// `name:path`, split once on ':' with the path tilde-expanded
    /// (source/modes/script.c:695-703).
    case script(name: String, path: String)

    public var name: String {
        switch self {
        case .script(let name, _): name
        case .window: "window"
        case .run: "run"
        case .ssh: "ssh"
        case .drun: "drun"
        case .combi: "combi"
        case .keys: "keys"
        case .fileBrowser: "filebrowser"
        }
    }

    /// `script_mode_is_valid` and `script_mode_parse_setup`
    /// (source/modes/script.c:675-732): a user script's name, else `name:path`.
    init?(scriptSpec token: String, userScripts: [String: String]) {
        if let path = userScripts[token] {
            self = .script(name: token, path: path)
            return
        }
        guard let colon = token.firstIndex(of: ":") else { return nil }
        self = .script(name: String(token[..<colon]), path: expandPath(String(token[token.index(after: colon)...])))
    }
}

/// Startup failed: the mode list or a key binding. rofi collects one message
/// per bad mode or binding and shows them in its startup error dialog
/// (source/rofi.c:546-562, 840-857, source/keyb.c:450-491).
public struct InvalidModeConfiguration: Error, Equatable, CustomStringConvertible {
    public let errors: [String]

    public init(errors: [String]) {
        self.errors = errors
    }

    /// The error dialog sets `EX_DATAERR` (source/rofi.c:856).
    public var exitStatus: Int32 { EX_DATAERR }

    /// Two errors at most; the count of the rest is upstream's, off by one
    /// (source/rofi.c:840-854). Its Pango markup is rendered away.
    public var description: String {
        var text = "The following errors were detected when starting rofi:\n"
        for error in errors.prefix(2) {
            text += "\n\n" + error
        }
        if errors.count - 2 > 1 {
            text += "\nThere are \(errors.count - 3) more errors."
        }
        return text
    }
}

/// The `-show` command line: the mode list, which mode starts, and the chrome
/// options read per mode.
public struct ShowOptions: Sendable {
    public var modes: [ModeSpec] = []
    /// Per mode, `-display-<name>` or the name (source/mode.c:189-208).
    public var displayNames: [String] = []
    /// The mode `-show` starts on, or nil when rofi is unsure what to show
    /// (source/rofi.c:952-958).
    public var startIndex: Int?
    /// `-sidebar-mode` (source/xrmoptions.c:388-395, config/config.c:119).
    public var sidebarMode = false
    /// `-show-icons` (source/xrmoptions.c:145). Upstream defaults it off
    /// (config/config.c:47); a macOS launcher shows icons unless
    /// `-no-show-icons` is given.
    public var showIcons = true
    /// Printed on stderr only when stdout is a terminal (source/rofi.c:533-545).
    public var warnings: [String] = []
    public var match = MatchOptions()
    public var sort = false
    public var sortingMethod = SortingMethod.levenshtein
    public var cycle = true
    /// Upstream's key bindings with the `-kb-*` options applied.
    public var keymap = Keymap()
    /// rofi's available modes: the built-ins (source/rofi.c:718-739), then
    /// each script spec as it is first resolved (source/rofi.c:795-807).
    public var availableModes: [ModeSpec] = []

    /// `environment` locates the user scripts directory.
    public init(arguments args: Arguments, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // xrmoptions.c:75-86 parses switchers, modi, then modes; the last one
        // present wins.
        // config/config.c:39.
        let list =
            args.string("-modes") ?? args.string("-modi") ?? args.string("-switchers") ?? "window,drun,run,ssh"
        // Each name resolves to the first available mode with it, built-ins
        // in upstream's order (source/rofi.c:719-739): window, run, ssh, drun,
        // combi, keys, filebrowser.
        // ponytail: windowcd and recursivebrowser are not built in; they stay
        // "not found".
        // ponytail: upstream reads the filebrowser's settings from the theme
        // (source/modes/filebrowser.c:395-405), not from flags.
        let disableHistory = args.bool("disable-history", default: false)
        // Gathered once before the mode list is built (source/rofi.c:756).
        let scripts = userScripts(environment)
        // parse_keys_abe runs after setup_modes (source/rofi.c:1271), but
        // `keys` needs the bindings; its errors are added in that order below.
        let parsedKeymap = Result { try Keymap(arguments: args) }
        let builtins: [ModeSpec] = [
            .window(
                format: args.string("-window-format") ?? "{c}   {t}",
                matchFields: args.string("-window-match-fields") ?? "all",
                command: args.string("-window-command") ?? "wmctrl -i -R {window}",
                terminal: args.string("-terminal"),
                runCommand: args.string("-run-command") ?? "{cmd}",
                runShellCommand: args.string("-run-shell-command") ?? "{terminal} -e {cmd}"),
            .run(
                historyPath: disableHistory ? nil : cacheDirectory(args) + "/rofi-4.runcache",
                terminal: args.string("-terminal"),
                runCommand: args.string("-run-command") ?? "{cmd}",
                runShellCommand: args.string("-run-shell-command") ?? "{terminal} -e {cmd}",
                listCommand: args.string("-run-list-command")),
            .ssh(
                historyPath: disableHistory ? nil : cacheDirectory(args) + "/rofi-2.sshcache",
                terminal: args.string("-terminal"),
                sshCommand: args.string("-ssh-command") ?? "{terminal} -e {ssh-client} {host} [-p {port}]",
                sshClient: args.string("-ssh-client") ?? "ssh",
                parseHosts: args.bool("parse-hosts", default: false),
                parseKnownHosts: args.bool("parse-known-hosts", default: true)),
            .drun(historyPath: disableHistory ? nil : cacheDirectory(args) + "/rofi3.druncache"),
            .keys(keymap: (try? parsedKeymap.get()) ?? Keymap()),
            .fileBrowser(
                directory: args.string("-filebrowser-directory"),
                showHidden: args.bool("filebrowser-show-hidden", default: false)),
        ]
        // combi_mode_parse_switchers (source/modes/combi.c:62-98): a built-in,
        // else a script spec; combi itself and unknown names are skipped with
        // a warning, shown only when combi is used. xrmoptions.c:439-450 parses
        // combi-modi, then combi-modes.
        var combined: [ModeSpec] = []
        var combiWarnings: [String] = []
        let combiList = args.string("-combi-modes") ?? args.string("-combi-modi") ?? "window,run"
        for token in combiList.split(whereSeparator: { $0 == "," || $0 == "#" }).map(String.init) {
            if token == "combi" {
                combiWarnings.append("You cannot add 'combi' to the list of combined modes.\n")
            } else if let spec = builtins.first(where: { $0.name == token })
                ?? ModeSpec(scriptSpec: token, userScripts: scripts)
            {
                combined.append(spec)
            } else {
                combiWarnings.append("Invalid script switcher: \(token)\n")
            }
        }
        let combi = ModeSpec.combi(
            modes: combined, displayNames: combined.map { args.string("-display-" + $0.name) ?? $0.name },
            displayFormat: args.bool("combi-hide-mode-prefix", default: false)
                ? nil : args.string("-combi-display-format") ?? "{mode} {text}")
        // source/rofi.c:719-739: combi sits after drun.
        var known = builtins
        known.insert(combi, at: 4)
        func resolve(_ token: String) -> ModeSpec? {
            if let spec = known.first(where: { $0.name == token }) { return spec }
            guard let spec = ModeSpec(scriptSpec: token, userScripts: scripts) else { return nil }
            if !known.contains(where: { $0.name == spec.name }) { known.append(spec) }
            return spec
        }
        // help_print_mode_not_found (source/rofi.c:547-562): every available
        // mode, `+` on the enabled ones.
        func notFound(_ name: String) -> String {
            "Mode \(name) is not found.\nThe following modes are known:\n"
                + known.map { "        * \(modes.contains($0) ? "+" : "")\($0.name)\n" }.joined()
        }
        defer { availableModes = known }

        // setup_modes (source/rofi.c:812-826): strtok skips empty tokens.
        var errors: [String] = []
        for token in list.split(whereSeparator: { $0 == "," || $0 == "#" }).map(String.init) {
            if let spec = resolve(token) {
                modes.append(spec)
            } else {
                errors.append(notFound(token))
            }
        }
        // parse_keys_abe's errors follow (source/rofi.c:1271).
        do {
            keymap = try parsedKeymap.get()
        } catch let error as InvalidModeConfiguration {
            errors += error.errors
        }
        // config_sanity_check adds its error after setup_modes' (source/rofi.c:
        // 1243-1250, 869-875); together they are shown before `-show` is read
        // (source/rofi.c:885-888).
        do {
            match = try MatchOptions(arguments: args)
        } catch {
            errors.append("\(error)")
        }
        sort = args.bool("sort", default: sort)
        cycle = args.bool("cycle", default: cycle)
        do {
            sortingMethod = try SortingMethod(arguments: args)
        } catch {
            errors.append("\(error)")
        }
        if !errors.isEmpty { throw InvalidModeConfiguration(errors: errors) }

        // source/rofi.c:935-958; mode_lookup compares names exactly (161-168).
        if let name = args.string("-show") {
            if let index = modes.firstIndex(where: { $0.name == name }) {
                startIndex = index
            } else if let spec = resolve(name) {
                modes.append(spec)
                startIndex = modes.count - 1
                warnings.append(disabledModeWarning(name, list: list))
            } else {
                throw InvalidModeConfiguration(errors: [notFound(name)])
            }
        } else if args.has("-show") && !modes.isEmpty {
            startIndex = 0
        }

        // ponytail: theme `display-name` is not read. Upstream registers a
        // script mode's `display-<name>` after parsing the command line
        // (source/rofi.c:1217, 1242, 819-821), so the flag only works for
        // built-ins there; here it works for every mode, as find_arg_str.
        displayNames = modes.map { args.string("-display-" + $0.name) ?? $0.name }
        if modes.contains(combi) { warnings += combiWarnings }
        sidebarMode = args.bool("sidebar-mode", default: sidebarMode)
        showIcons = args.bool("show-icons", default: showIcons)
    }
}

extension ShowOptions {
    /// `help_print_no_arguments` with its markup rendered away
    /// (source/rofi.c:564-595): the enabled modes, then the available ones
    /// that are not enabled.
    public var unsureWhatToShow: String {
        "Rofi is unsure what to show.\n\n"
            + "Please specify the mode you want to show.\n\n"
            + "    rofi -show {mode}\n\n"
            + "The following modes are enabled:\n"
            + modes.map { "    • \($0.name)\n" }.joined()
            + "\nThe following modes can be enabled:\n"
            + availableModes.filter { !modes.contains($0) }.map { "    • \($0.name)\n" }.joined()
            + "\nTo activate a mode, add it to the list in the modes setting.\n"
    }
}

/// `help_print_disabled_mode`, colors included (source/rofi.c:533-545,
/// include/rofi.h:123-131).
private func disabledModeWarning(_ mode: String, list: String) -> String {
    let red = "\u{1B}[0;31m"
    let green = "\u{1B}[0;32m"
    let reset = "\u{1B}[0m"
    return "Mode \(red)\(mode)\(reset) is not enabled. I have enabled it for now.\n"
        + "Please consider adding \(red)\(mode)\(reset) to the list of enabled modes: "
        + "\(green)modes: [\(list)\(reset)\(red),\(mode)]\(reset).\n"
}

/// `cache_dir` (source/rofi.c:1227-1231): `-cache-dir` tilde-expanded, else
/// g_get_user_cache_dir, which is `$XDG_CACHE_HOME` or `~/.cache`. It holds
/// the history files: run's `rofi-4.runcache` (source/modes/run.c:64), ssh's
/// `rofi-2.sshcache` (source/modes/ssh.c:83) and drun's `rofi3.druncache`
/// (source/modes/drun.c:65, 883-893).
private func cacheDirectory(_ args: Arguments) -> String {
    let environment = ProcessInfo.processInfo.environment
    return args.string("-cache-dir").map(expandPath)
        ?? environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.cache"
}

/// `script_mode_gather_user_scripts` (source/modes/script.c:636-665): each
/// file in g_get_user_config_dir's `rofi/scripts`, `$XDG_CONFIG_HOME` or
/// `~/.config`, named without its last extension; the first of a name wins.
private func userScripts(_ environment: [String: String]) -> [String: String] {
    let directory =
        (environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.config") + "/rofi/scripts"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return Dictionary(
        files.map { (String($0[..<($0.lastIndex(of: ".") ?? $0.endIndex)]), directory + "/" + $0) },
        uniquingKeysWith: { first, _ in first })
}

/// `rofi_expand_path` (source/helper.c:784-813): `~` and `~user` expand in any
/// component, then g_build_filenamev joins the components, dropping empty
/// ones and the separators around inner ones.
func expandPath(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map { component -> String in
        guard component.first == "~" else { return String(component) }
        if component == "~" {
            // g_get_home_dir prefers $HOME.
            return ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        }
        guard let entry = getpwnam(String(component.dropFirst())) else { return String(component) }
        return String(cString: entry.pointee.pw_dir)
    }
    let absolute = path.hasPrefix("/") || components.first?.hasPrefix("/") == true
    return (absolute ? "/" : "") + components.flatMap { $0.split(separator: "/") }.joined(separator: "/")
}
