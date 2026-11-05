import Foundation

/// One entry of the mode list: a script mode or a built-in.
public enum ModeSpec: Equatable, Sendable {
    /// `drun` (source/modes/drun.c:1693) with its history file, nil when
    /// `-disable-history` is set (drun.c:883-893, config/config.c:103).
    case drun(historyPath: String?)
    /// `filebrowser` (source/modes/filebrowser.c:729) with its `directory` and
    /// `show-hidden` settings (395-405, 422-453); nil directory means home.
    case fileBrowser(directory: String?, showHidden: Bool)
    /// `name:path`, split once on ':' with the path tilde-expanded
    /// (source/modes/script.c:695-703).
    case script(name: String, path: String)

    public var name: String {
        switch self {
        case .script(let name, _): name
        case .drun: "drun"
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
    /// Upstream's key bindings with the `-kb-*` options applied.
    public var keymap = Keymap()
    /// rofi's available modes: the built-ins (source/rofi.c:718-739), then
    /// each script spec as it is first resolved (source/rofi.c:795-807).
    public var availableModes: [ModeSpec] = []

    /// `environment` locates the user scripts directory.
    public init(arguments args: Arguments, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // xrmoptions.c:75-86 parses switchers, modi, then modes; the last one
        // present wins.
        // Upstream defaults to `window,drun,run,ssh` (`drun,run,ssh` on
        // Wayland, config/config.c:36-42); of those only drun exists here, so
        // the default enables both built-ins instead.
        let list =
            args.string("-modes") ?? args.string("-modi") ?? args.string("-switchers") ?? "drun,filebrowser"
        // Each name resolves to the first available mode with it, built-ins
        // in upstream's order (source/rofi.c:732-740).
        // ponytail: only `drun` and `filebrowser` are built in; window, run,
        // ssh, combi, keys and recursivebrowser stay "not found".
        // ponytail: upstream reads the filebrowser's settings from the theme
        // (source/modes/filebrowser.c:395-405), not from flags.
        var known: [ModeSpec] = [
            .drun(historyPath: args.bool("disable-history", default: false) ? nil : drunHistoryPath(args)),
            .fileBrowser(
                directory: args.string("-filebrowser-directory"),
                showHidden: args.bool("filebrowser-show-hidden", default: false)),
        ]
        // Gathered once before the mode list is built (source/rofi.c:756).
        let scripts = userScripts(environment)
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
            keymap = try Keymap(arguments: args)
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

/// `cache_dir/rofi3.druncache` (source/modes/drun.c:65, 883-893): `-cache-dir`
/// tilde-expanded, else g_get_user_cache_dir, which is `$XDG_CACHE_HOME`
/// or `~/.cache` (source/rofi.c:1227-1231).
private func drunHistoryPath(_ args: Arguments) -> String {
    let environment = ProcessInfo.processInfo.environment
    let directory =
        args.string("-cache-dir").map(expandPath)
        ?? environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.cache"
    return directory + "/rofi3.druncache"
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
