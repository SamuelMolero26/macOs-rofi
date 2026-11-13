import Foundation

/// Spawns one argv directly (no shell). Injected so tests never start a process.
public typealias CommandLauncher = (_ argv: [String]) -> Result<Void, ApplicationLaunchFailure>

/// Writes an executable script with the given POSIX permission bits and returns
/// its path. Injected so tests never touch the real temp directory.
public typealias ScriptWriter = (_ contents: String, _ mode: Int) -> Result<String, ApplicationLaunchFailure>

/// How a rendered terminal command is started.
public enum LaunchPlan: Equatable, Sendable {
    /// Spawn this argv unchanged (every terminal that understands `-e`).
    case argv([String])
    /// Terminal.app and friends have no `-e`: run `innerArgv` from a temporary
    /// `.command` script opened with `open -a <appName>`.
    case terminalScript(appName: String, innerArgv: [String])
}

/// Terminal launch seam shared by `run` and `ssh`.
///
/// Upstream renders `{terminal} -e {cmd}` / `{terminal} -e {ssh-client} {host}
/// [-p {port}]` (config/config.c:68,74) and spawns the argv (source/helper.c:1409-1450).
/// That works for every terminal with `-e` (Ghostty, kitty, Alacritty, xterm, ...).
/// Only terminals in `adapterApps` lack it and go through a `.command` script.
public enum TerminalLaunch {
    /// Used when `-terminal` is unset (user decision: default to Terminal.app).
    public static let defaultTerminal = "Terminal"
    /// POSIX mode of the temporary script: owner only.
    public static let scriptMode = 0o700

    /// ponytail: a tiny explicit table, matched on the whole name (case-insensitive,
    /// optional `.app`), never on a substring.
    private static let adapterApps: [String: String] = [
        "terminal": "Terminal", "iterm": "iTerm", "iterm2": "iTerm",
    ]

    /// `values` carries `cmd`, `ssh-client`, `host`, `port`; `terminal` is added here.
    public static func plan(terminal: String?, template: String, values: [String: String]) throws
        -> LaunchPlan
    {
        let name = terminal ?? defaultTerminal
        var all = values
        all["terminal"] = name
        let argv = try parseCommandTemplate(template, values: all)
        guard let app = adapterApp(for: name),
            let flag = argv.dropFirst().firstIndex(of: "-e"),
            flag + 1 < argv.count
        else { return .argv(argv) }
        return .terminalScript(appName: app, innerArgv: Array(argv[(flag + 1)...]))
    }

    /// Script that deletes itself, then replaces the shell with the command.
    /// Every element is single-quoted, so spaces, `$`, `;` and quotes stay literal.
    public static func scriptText(innerArgv: [String]) -> String {
        let quoted = innerArgv.map(shellQuote).joined(separator: " ")
        return "#!/bin/sh\nrm -f -- \"$0\"\nexec \(quoted)\n"
    }

    public static func launch(
        _ plan: LaunchPlan, launcher: CommandLauncher, writeScript: ScriptWriter
    ) -> Result<Void, ApplicationLaunchFailure> {
        switch plan {
        case .argv(let argv):
            return launcher(argv)
        case .terminalScript(let appName, let innerArgv):
            switch writeScript(scriptText(innerArgv: innerArgv), scriptMode) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let path):
                return launcher(["/usr/bin/open", "-a", appName, path])
            }
        }
    }

    private static func adapterApp(for terminal: String) -> String? {
        var key = terminal.lowercased()
        if key.hasSuffix(".app") { key.removeLast(4) }
        return adapterApps[key]
    }
}
