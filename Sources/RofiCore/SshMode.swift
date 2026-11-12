import Foundation

/// `SshEntry` (source/modes/ssh.c:62-68): a host, the other names of its
/// config `Host` line, and a port, 0 for none.
public struct SshHost: Equatable, Sendable {
    public var hostname: String
    public var aliases: [String]
    public var port: Int

    public init(_ hostname: String, aliases: [String] = [], port: Int = 0) {
        self.hostname = hostname
        self.aliases = aliases
        self.port = port
    }
}

/// The files ssh discovery reads, injected so tests never touch the disk.
public struct SshFiles {
    /// A file's text, or nil when it cannot be opened.
    public var read: (_ path: String) -> String?
    /// `glob(pattern, 0, ...)`: the existing paths matching a pattern, sorted.
    public var glob: (_ pattern: String) -> [String]

    public init(read: @escaping (_ path: String) -> String?, glob: @escaping (_ pattern: String) -> [String]) {
        self.read = read
        self.glob = glob
    }

    /// Reads nothing.
    public static var none: SshFiles { SshFiles(read: { _ in nil }, glob: { _ in [] }) }

    /// The real files. ponytail: invalid UTF-8 decodes to U+FFFD.
    public static var disk: SshFiles {
        SshFiles(
            read: { FileManager.default.contents(atPath: $0).map { String(decoding: $0, as: UTF8.self) } },
            glob: globOnDisk)
    }
}

/// The `ssh` mode (source/modes/ssh.c): the hosts of the ssh history, the
/// user's ssh config and known hosts, the recently used ones first.
///
/// A host always opens in a terminal: `-ssh-command` (config/config.c:68)
/// is filled with `{host}`, `{ssh-client}` and, only when the host has one,
/// `{port}`, so `[-p {port}]` is dropped without a port (helper.c:1756-1757),
/// and goes through `TerminalLaunch`. A set `-terminal` runs the template
/// unchanged; none means Terminal.app through its `.command` adapter.
///
/// ponytail: upstream exits after a failed launch's error dialog (ssh.c:628,
/// 631); the message is shown and the view stays here, as `RunMode` does.
public final class SshMode: Mode {
    public let name = "ssh"
    public private(set) var rows: [Row] = []
    private var hosts: [SshHost] = [] {
        didSet {
            rows = hosts.map { Row(parsing: displayText($0)) }
            hostsByText = Dictionary(hosts.map { (displayText($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    private var hostsByText: [String: SshHost] = [:]
    /// The history lines the first hosts were read from, for deletion.
    private var historyLines: [String] = []
    private let home: String
    private let files: SshFiles
    private let history: History?
    private let terminal: String?
    private let sshCommand: String
    private let sshClient: String
    private let parseHosts: Bool
    private let parseKnownHosts: Bool
    private let launcher: CommandLauncher
    private let writeScript: ScriptWriter
    /// The last failed launch, worded as upstream's error dialog
    /// (helper.c:1426-1434); cleared by the next action.
    private var failure: String?

    /// `terminal` is `-terminal`, nil when unset; the rest default as
    /// config/config.c:66-68, 123-125.
    public init(
        home: String, files: SshFiles, history: History?, terminal: String?,
        sshCommand: String = "{terminal} -e {ssh-client} {host} [-p {port}]", sshClient: String = "ssh",
        parseHosts: Bool = false, parseKnownHosts: Bool = true,
        launcher: @escaping CommandLauncher, writeScript: @escaping ScriptWriter
    ) {
        self.home = home
        self.files = files
        self.history = history
        self.terminal = terminal
        self.sshCommand = sshCommand
        self.sshClient = sshClient
        self.parseHosts = parseHosts
        self.parseKnownHosts = parseKnownHosts
        self.launcher = launcher
        self.writeScript = writeScript
        load()
    }

    public var message: String? { failure }

    /// `ssh_token_match` (ssh.c:698-708): the host or any one alias.
    public func matches(_ row: Row, matcher: Matcher) -> Bool {
        guard let host = hostsByText[row.text] else { return matcher.matches(row.text) }
        return ([host.hostname] + host.aliases).contains { matcher.matches($0) }
    }

    /// `ssh_mode_init` (ssh.c:575-582).
    private func load() {
        historyLines = history?.list() ?? []
        hosts = discoverSshHosts(
            history: historyLines, home: home, files: files, parseKnownHosts: parseKnownHosts,
            parseHosts: parseHosts)
    }

    /// `ssh_mode_result` (ssh.c:626-647).
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            return .switchTo(key)
        case .ok:
            guard let index = selectedRow, hosts.indices.contains(index) else { return .exit }
            return connect(hosts[index]) ? .exit : .reload
        case .customInput:
            // 632-635: the typed text is the host, with no port.
            guard let text = input, !text.isEmpty else { return .exit }
            return connect(SshHost(text)) ? .exit : .reload
        case .deleteEntry:
            // 636-642. ponytail: upstream removes the bare host name
            // (155-162), which never equals a stored `host US port` line; a
            // history host's own line is removed here.
            guard let index = selectedRow, hosts.indices.contains(index) else { return .exit }
            history?.remove(index < historyLines.count ? historyLines[index] : hosts[index].hostname)
            load()
            return .reload
        }
    }

    /// `exec_ssh` and `execshssh` (ssh.c:98-148): launch, then store
    /// `host US port [US alias]...` on success. An empty host runs nothing.
    private func connect(_ host: SshHost) -> Bool {
        guard !host.hostname.isEmpty else { return true }
        var values = ["host": host.hostname, "ssh-client": sshClient]
        if host.port > 0 { values["port"] = String(host.port) }
        do {
            let plan = try TerminalLaunch.plan(terminal: terminal, template: sshCommand, values: values)
            if case .failure(let error) = TerminalLaunch.launch(plan, launcher: launcher, writeScript: writeScript) {
                // helper_execute's error_precmd and error_cmd (ssh.c:119).
                failure = ApplicationLaunchFailure(command: "ssh " + host.hostname, reason: error.reason).dialogText
                return false
            }
        } catch {
            failure = (error as? CommandTemplateError)?.message ?? "\(error)"
            return false
        }
        record(([host.hostname, String(host.port)] + host.aliases).joined(separator: "\u{1F}"))
        return true
    }

    /// `history_set` after a launch (ssh.c:138-147); the cache folder is
    /// created first, as `RunMode` does.
    private func record(_ line: String) {
        guard let history else { return }
        try? FileManager.default.createDirectory(
            at: history.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        history.set(line)
    }
}

/// `_get_display_value` (ssh.c:661-687): `host ( alias1, alias2 )`.
private func displayText(_ host: SshHost) -> String {
    host.aliases.isEmpty
        ? host.hostname : host.hostname + " (" + host.aliases.map { " " + $0 }.joined(separator: ",") + " )"
}

/// `get_ssh` (source/modes/ssh.c:493-567): the history entries first, in
/// file order with their ports and aliases, then the `Host` names of
/// `~/.ssh/config`, then `~/.ssh/known_hosts` and every
/// `UserKnownHostsFile` when `parseKnownHosts` (config/config.c:125), then
/// `/etc/hosts` when `parseHosts` (config/config.c:123). Nothing is sorted.
///
/// Duplicates are dropped as upstream does: a config name equal to a history
/// host or alias (426-447), and a known_hosts or /etc/hosts name equal to
/// any listed host name (232-240, 300-308), both ignoring ASCII case.
/// Config hosts are not checked against each other. No system-wide file
/// (`/etc/ssh/ssh_config`, `/etc/ssh/ssh_known_hosts`) is read, as upstream.
public func discoverSshHosts(
    history: [String], home: String, files: SshFiles, parseKnownHosts: Bool, parseHosts: Bool
) -> [SshHost] {
    var hosts = history.map(sshHost(historyLine:))
    var knownHostsFiles: [String] = []
    var including: Set<String> = []
    parseSshConfig(
        home + "/.ssh/config", home: home, files: files, favorites: hosts.count, hosts: &hosts,
        knownHostsFiles: &knownHostsFiles, including: &including)
    if parseKnownHosts {
        // 547-559: rofi_expand_path on each extra file, no directory join.
        for path in [home + "/.ssh/known_hosts"] + knownHostsFiles.map({ expandHome($0, home: home) }) {
            if let text = files.read(path) { RofiCore.parseKnownHosts(text, into: &hosts) }
        }
    }
    if parseHosts, let text = files.read("/etc/hosts") { parseEtcHosts(text, into: &hosts) }
    return hosts
}

/// `read_known_hosts_file` (source/modes/ssh.c:173-267): per stripped line,
/// comments, `@` markers and hashed `|` names are skipped; the names before
/// the first space are split on `,`, and `[host]:port` carries its port.
/// A name already listed, ignoring ASCII case, is skipped.
///
/// ponytail: upstream adds an empty host for an empty name (`a,,b`) and
/// keeps the `]` of a `[host]` with no port; both are dropped here.
public func parseKnownHosts(_ text: String, into hosts: inout [SshHost]) {
    for raw in split(text, omittingEmpty: false, where: { $0 == "\n" }) {
        let line = String(String.UnicodeScalarView(strip(raw)))
        guard let first = line.unicodeScalars.first, first != "#", first != "@", first != "|",
            let space = line.unicodeScalars.firstIndex(of: " ")
        else { continue }
        for token in split(line.unicodeScalars[..<space], where: { $0 == "," || $0 == " " }) {
            var name = token
            var port = 0
            if name.hasPrefix("[") {
                name.removeFirst()
                // 205-212: no `]` is a malformed name.
                guard let close = name.firstIndex(of: "]") else { continue }
                let rest = name[name.index(after: close)...]
                if rest.hasPrefix(":") { port = parsePort(rest.dropFirst()) }
                name = String(name[..<close])
            }
            if !hosts.contains(where: { equalsIgnoringASCIICase($0.hostname, name) }) {
                hosts.append(SshHost(name, port: port))
            }
        }
    }
}

/// `read_hosts_file` (source/modes/ssh.c:277-342): each name after a line's
/// address, up to a `#`, separated by spaces or tabs; a name already listed,
/// ignoring ASCII case, is skipped.
///
/// ponytail: upstream loses a name directly followed by `#` or ending a
/// file with no final newline (331); both are kept here.
public func parseEtcHosts(_ text: String, into hosts: inout [SshHost]) {
    for line in split(text, where: { $0 == "\n" }) {
        let content = line.unicodeScalars.prefix { $0 != "#" }
        for name in split(content, where: { $0 == " " || $0 == "\t" }).dropFirst()
        where !hosts.contains(where: { equalsIgnoringASCIICase($0.hostname, name) }) {
            hosts.append(SshHost(name))
        }
    }
}

/// One history line, `host US port [US alias]...` (ssh.c:506-537).
func sshHost(historyLine line: String) -> SshHost {
    let fields = split(line, omittingEmpty: false, where: { $0 == "\u{1F}" })
    return SshHost(fields[0], aliases: Array(fields.dropFirst(2)), port: fields.count > 1 ? parsePort(fields[1]) : 0)
}

/// `parse_ssh_config_file` (source/modes/ssh.c:355-483). Each line is split
/// on `=`, blanks and line ends (`SSH_TOKEN_DELIM`, 89); the keyword is
/// matched ignoring ASCII case.
///
/// `Include` globs its first argument, `~` expanded and relative to the
/// including file's directory (378-401), and reads each match in place.
/// Upstream recurses with no guard (394-395); a file already being read is
/// skipped here, so a cycle ends instead of overflowing the stack.
/// `UserKnownHostsFile` adds every argument once (402-406, 344-353).
/// A `Host` name is skipped when negated or wildcarded (415-419) or equal to
/// a history host or alias (426-447); a `#` word ends the line (421-424).
/// The first name kept starts a host and the rest become its aliases.
/// Upstream reads no `Port` here, so config hosts have none.
private func parseSshConfig(
    _ path: String, home: String, files: SshFiles, favorites: Int, hosts: inout [SshHost],
    knownHostsFiles: inout [String], including: inout Set<String>
) {
    guard !including.contains(path), let text = files.read(path) else { return }
    including.insert(path)
    defer { including.remove(path) }
    for line in split(text, where: { $0 == "\n" }) {
        let tokens = split(line, where: { "= \t\r\n".unicodeScalars.contains($0) })
        guard let keyword = tokens.first, !keyword.hasPrefix("#") else { continue }
        let arguments = tokens.dropFirst()
        switch asciiLowercased(keyword) {
        case "include":
            guard let argument = arguments.first else { continue }
            let expanded = expandHome(argument, home: home)
            let pattern = expanded.hasPrefix("/") ? expanded : directoryName(path) + "/" + expanded
            for match in files.glob(pattern) {
                parseSshConfig(
                    match, home: home, files: files, favorites: favorites, hosts: &hosts,
                    knownHostsFiles: &knownHostsFiles, including: &including)
            }
        case "userknownhostsfile":
            for argument in arguments where !knownHostsFiles.contains(argument) {
                knownHostsFiles.append(argument)
            }
        case "host":
            var started = false
            for name in arguments {
                if name.hasPrefix("!") || name.contains("*") || name.contains("?") { continue }
                if name.hasPrefix("#") { break }
                let isFavorite = hosts.prefix(favorites).contains { host in
                    equalsIgnoringASCIICase(host.hostname, name)
                        || host.aliases.contains { equalsIgnoringASCIICase($0, name) }
                }
                if isFavorite { continue }
                if started {
                    hosts[hosts.count - 1].aliases.append(name)
                } else {
                    hosts.append(SshHost(name))
                    started = true
                }
            }
        default:
            continue
        }
    }
}

/// `g_ascii_strtoll(text, &end, 10)` accepted only in 0-65535 (ssh.c:216-229,
/// 511-524): leading blanks and a sign are allowed, trailing text is
/// ignored; no digits, overflow or out of range is 0.
private func parsePort(_ text: some StringProtocol) -> Int {
    var scalars = text.unicodeScalars.drop(while: isCSpace)
    var negative = false
    if let sign = scalars.first, sign == "+" || sign == "-" {
        negative = sign == "-"
        scalars = scalars.dropFirst()
    }
    let digits = scalars.prefix { (48...57).contains($0.value) }
    guard let value = Int(String(String.UnicodeScalarView(digits))) else { return 0 }
    let number = negative ? -value : value
    return (0...65535).contains(number) ? number : 0
}

/// `rofi_expand_path` with `~` taken from `home`, as `RunMode` does.
private func expandHome(_ path: String, home: String) -> String {
    path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : expandPath(path)
}

/// `g_path_get_dirname`.
private func directoryName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "." }
    return slash == path.startIndex ? "/" : String(path[..<slash])
}

/// `g_ascii_strcasecmp(a, b) == 0`.
private func equalsIgnoringASCIICase(_ a: String, _ b: String) -> Bool {
    asciiLowercased(a) == asciiLowercased(b)
}

/// `isspace` in the C locale, as `g_strstrip` and `strtoll` use it.
private func isCSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || (9...13).contains(scalar.value)
}

/// Splits on single Unicode scalars, so `\r\n` is never one separator.
private func split<S: StringProtocol>(
    _ text: S, omittingEmpty: Bool = true, where isSeparator: (Unicode.Scalar) -> Bool
) -> [String] {
    split(text.unicodeScalars, omittingEmpty: omittingEmpty, where: isSeparator)
}

private func split<C: Collection<Unicode.Scalar>>(
    _ scalars: C, omittingEmpty: Bool = true, where isSeparator: (Unicode.Scalar) -> Bool
) -> [String] {
    scalars.split(omittingEmptySubsequences: omittingEmpty, whereSeparator: isSeparator).map {
        String(String.UnicodeScalarView($0))
    }
}

/// `g_strstrip`.
private func strip(_ text: String) -> Substring.UnicodeScalarView {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isCSpace($0) }),
        let last = scalars.lastIndex(where: { !isCSpace($0) })
    else { return scalars[scalars.startIndex..<scalars.startIndex] }
    return scalars[first...last]
}

/// The real `SshFiles.glob`.
private func globOnDisk(_ pattern: String) -> [String] {
    var result = glob_t()
    defer { globfree(&result) }
    guard glob(pattern, 0, nil, &result) == 0 else { return [] }
    return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
}
