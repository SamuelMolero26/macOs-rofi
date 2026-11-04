import Foundation

/// One entry of the mode list. Only script modes exist so far.
public enum ModeSpec: Equatable, Sendable {
    /// `name:path`, split once on ':' with the path tilde-expanded
    /// (source/modes/script.c:695-703).
    case script(name: String, path: String)

    public var name: String {
        switch self {
        case .script(let name, _): name
        }
    }

    /// `script_mode_is_valid` and `script_mode_parse_setup`
    /// (source/modes/script.c:675-732).
    /// ponytail: no ~/.config/rofi/scripts lookup for bare names.
    init?(scriptSpec token: String) {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        self = .script(name: String(token[..<colon]), path: expandPath(String(token[token.index(after: colon)...])))
    }
}

/// The mode list failed to set up. rofi collects one message per bad mode and
/// shows them in its startup error dialog (source/rofi.c:546-562, 840-857).
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
    /// Printed on stderr only when stdout is a terminal (source/rofi.c:533-545).
    public var warnings: [String] = []
    public var match = MatchOptions()

    public init(arguments args: Arguments) throws {
        // xrmoptions.c:75-86 parses switchers, modi, then modes; the last one
        // present wins.
        // ponytail: upstream defaults to `window,drun,run,ssh`
        // (config/config.c:36-42); none of those exist yet.
        let list = args.string("-modes") ?? args.string("-modi") ?? args.string("-switchers") ?? ""
        // rofi's available modes: each name resolves to the first spec seen.
        var known: [ModeSpec] = []
        func resolve(_ token: String) -> ModeSpec? {
            if let spec = known.first(where: { $0.name == token }) { return spec }
            guard let spec = ModeSpec(scriptSpec: token) else { return nil }
            if !known.contains(where: { $0.name == spec.name }) { known.append(spec) }
            return spec
        }
        func notFound(_ name: String) -> String {
            "Mode \(name) is not found.\nThe following modes are known:\n"
                + known.map { "        * +\($0.name)\n" }.joined()
        }

        // setup_modes (source/rofi.c:812-826): strtok skips empty tokens.
        var errors: [String] = []
        for token in list.split(whereSeparator: { $0 == "," || $0 == "#" }).map(String.init) {
            if let spec = resolve(token) {
                modes.append(spec)
            } else {
                errors.append(notFound(token))
            }
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
    }
}

extension ShowOptions {
    /// `help_print_no_arguments` with its markup rendered away
    /// (source/rofi.c:564-595). Every known mode is a listed script mode, so
    /// none can be enabled.
    public var unsureWhatToShow: String {
        "Rofi is unsure what to show.\n\n"
            + "Please specify the mode you want to show.\n\n"
            + "    rofi -show {mode}\n\n"
            + "The following modes are enabled:\n"
            + modes.map { "    • \($0.name)\n" }.joined()
            + "\nThe following modes can be enabled:\n"
            + "\nTo activate a mode, add it to the list in the modes setting.\n"
    }
}

/// `help_print_disabled_mode`, colors included (source/rofi.c:533-545,
/// include/rofi.h:123-131).
private func disabledModeWarning(_ mode: String, list: String) -> String {
    let red = "\u{1B}[0;31m", green = "\u{1B}[0;32m", reset = "\u{1B}[0m"
    return "Mode \(red)\(mode)\(reset) is not enabled. I have enabled it for now.\n"
        + "Please consider adding \(red)\(mode)\(reset) to the list of enabled modes: "
        + "\(green)modes: [\(list)\(reset)\(red),\(mode)]\(reset).\n"
}

/// `rofi_expand_path` (source/helper.c:784-813): `~` and `~user` expand in any
/// component, then g_build_filenamev joins the components, dropping empty
/// ones and the separators around inner ones.
private func expandPath(_ path: String) -> String {
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
