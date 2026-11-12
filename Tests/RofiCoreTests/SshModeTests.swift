// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

// Contract: rofi's ssh mode, source/modes/ssh.c (cache file 83, execshssh
// 98-120, exec_ssh 127-148, read_known_hosts_file 173-267, read_hosts_file
// 277-342, parse_ssh_config_file 355-483, get_ssh 493-567, ssh_mode_result
// 626-647), with the files, the process launcher and the script writer
// injected.
@Suite final class SshModeTests {
    // MARK: discovery (ssh.c:355-567), never the disk

    private let home = "/home/u"

    /// Each path reads its text; a glob matches the listed paths, or the
    /// pattern itself when it is a file.
    private func files(_ contents: [String: String], globs: [String: [String]] = [:]) -> SshFiles {
        SshFiles(
            read: { contents[$0] },
            glob: { pattern in globs[pattern] ?? (contents[pattern] == nil ? [] : [pattern]) })
    }

    private func discover(
        _ contents: [String: String], history: [String] = [], globs: [String: [String]] = [:],
        parseKnownHosts: Bool = true, parseHosts: Bool = false
    ) -> [SshHost] {
        discoverSshHosts(
            history: history, home: home, files: files(contents, globs: globs), parseKnownHosts: parseKnownHosts,
            parseHosts: parseHosts)
    }

    private func config(_ text: String) -> [String: String] { ["/home/u/.ssh/config": text] }

    // ssh.c:365-377, 407-470: the keyword is case-insensitive and may be
    // joined by `=`; the first name of a Host line is the host, the rest its
    // aliases; comment lines and other keywords are skipped.
    @Test func configHostLinesNameHostsAndAliases_ssh_c_407() {
        let hosts = discover(
            config("Host alpha beta\n  HostName 10.0.0.1\nhost=gamma\n# Host hidden\n\tHOST delta\r\nPort 22\n"))
        #expect(
            hosts == [SshHost("alpha", aliases: ["beta"]), SshHost("gamma"), SshHost("delta")])
    }

    // ssh.c:415-419: wildcard and negated patterns cannot be connected to.
    @Test func configSkipsWildcardsAndNegations_ssh_c_415() {
        #expect(discover(config("Host * !bad web? good *.corp\n")) == [SshHost("good")])
    }

    // ssh.c:421-424: a `#` word ends the Host line.
    @Test func configCommentEndsAHostLine_ssh_c_422() {
        #expect(discover(config("Host a b #c d\n")) == [SshHost("a", aliases: ["b"])])
    }

    // ssh.c:378-401: Include is globbed relative to the including file's
    // directory, `~` expanded, and its hosts come where the line is.
    @Test func configFollowsIncludeInPlace_ssh_c_378() {
        let hosts = discover(
            [
                "/home/u/.ssh/config": "Include conf.d/*\nHost main\nInclude ~/extra\n",
                "/home/u/.ssh/conf.d/one": "Host inner\n",
                "/home/u/.ssh/conf.d/two": "Host second\n",
                "/home/u/extra": "Host last\n",
            ],
            globs: ["/home/u/.ssh/conf.d/*": ["/home/u/.ssh/conf.d/one", "/home/u/.ssh/conf.d/two"]])
        #expect(hosts.map(\.hostname) == ["inner", "second", "main", "last"])
    }

    // ssh.c:394-395 recurses with no guard; a file that includes itself is
    // read once here instead of overflowing the stack.
    @Test func configIncludeCycleIsReadOnce_ssh_c_394() {
        let hosts = discover(
            [
                "/home/u/.ssh/config": "Host top\nInclude other\n",
                "/home/u/.ssh/other": "Host nested\nInclude /home/u/.ssh/config\n",
            ])
        #expect(hosts.map(\.hostname) == ["top", "nested"])
    }

    // ssh.c:402-406, 547-559: UserKnownHostsFile names extra files, read
    // after ~/.ssh/known_hosts and only when known hosts are parsed.
    @Test func configAddsUserKnownHostsFiles_ssh_c_402() {
        let contents = [
            "/home/u/.ssh/config": "UserKnownHostsFile ~/.ssh/work /etc/other\nUserKnownHostsFile ~/.ssh/work\n",
            "/home/u/.ssh/known_hosts": "main ssh-ed25519 AAAA\n",
            "/home/u/.ssh/work": "work ssh-ed25519 AAAA\n",
            "/etc/other": "other ssh-ed25519 AAAA\n",
        ]
        #expect(discover(contents).map(\.hostname) == ["main", "work", "other"])
        #expect(discover(contents, parseKnownHosts: false).isEmpty)
    }

    // ssh.c:173-267: plain names, comma lists and `[host]:port` count;
    // comments, markers and hashed names do not; a name already listed
    // (ignoring ASCII case) is skipped.
    @Test func knownHostsParsing_ssh_c_173() {
        var hosts: [SshHost] = []
        parseKnownHosts(
            """
              plain ssh-ed25519 AAAA
            a.example,10.0.0.1 ssh-rsa AAAA
            [jump.example]:2222 ssh-ed25519 AAAA
            |1|abc=|def= ssh-ed25519 AAAA
            @cert-authority *.example ssh-rsa AAAA
            @revoked bad ssh-rsa AAAA
            # comment
            PLAIN ssh-rsa again
            nokey
            [broken ssh-rsa AAAA
            [big]:99999 ssh-rsa AAAA

            """, into: &hosts)
        #expect(
            hosts == [
                SshHost("plain"), SshHost("a.example"), SshHost("10.0.0.1"), SshHost("jump.example", port: 2222),
                SshHost("big"),
            ])
    }

    // ssh.c:203-231: `[host]` without a port. ponytail: upstream keeps the
    // `]` in the name; it is dropped here.
    @Test func knownHostsBracketWithoutPort_ssh_c_213() {
        var hosts: [SshHost] = []
        parseKnownHosts("[bare] ssh-rsa AAAA\n", into: &hosts)
        #expect(hosts == [SshHost("bare")])
    }

    // ssh.c:277-342: every name after the address, up to a `#`.
    @Test func etcHostsParsing_ssh_c_277() {
        var hosts = [SshHost("db")]
        parseEtcHosts(
            "127.0.0.1 localhost\n::1 localhost ip6-localhost # loop back\n10.0.0.2\tdb DB.local#x\n# 1.1.1.1 no\n",
            into: &hosts)
        #expect(hosts.map(\.hostname) == ["db", "localhost", "ip6-localhost", "DB.local"])
    }

    // ssh.c:560-562, config/config.c:123: /etc/hosts is read last, only with
    // -parse-hosts.
    @Test func etcHostsNeedsParseHosts_ssh_c_560() {
        let contents = [
            "/etc/hosts": "10.0.0.9 lan\n",
            "/home/u/.ssh/known_hosts": "known ssh-rsa AAAA\n",
            "/home/u/.ssh/config": "Host conf\n",
        ]
        #expect(discover(contents).map(\.hostname) == ["conf", "known"])
        #expect(discover(contents, parseHosts: true).map(\.hostname) == ["conf", "known", "lan"])
    }

    // ssh.c:502-541, 426-447, 232-240: history first in file order with its
    // port and aliases; a config name equal to a history host or alias is
    // skipped (and the next name on that line starts a new host); known
    // hosts skip any listed host name.
    @Test func historyComesFirstAndIsNotRepeated_ssh_c_502() {
        let hosts = discover(
            [
                "/home/u/.ssh/config": "Host ALPHA other\nHost al\nHost fresh\n",
                "/home/u/.ssh/known_hosts": "alpha ssh-rsa x\nFresh ssh-rsa x\nnew ssh-rsa x\n",
            ],
            history: ["alpha\u{1F}22\u{1F}al", "old"])
        #expect(
            hosts == [
                SshHost("alpha", aliases: ["al"], port: 22), SshHost("old"), SshHost("other"), SshHost("fresh"),
                SshHost("new"),
            ])
    }

    // ssh.c:507-525: the port field is a g_ascii_strtoll number in 0-65535,
    // else 0.
    @Test func historyPortParsing_ssh_c_511() {
        let history = ["a\u{1F}0", "b\u{1F}x", "c\u{1F}70000", "d\u{1F}-1", "e\u{1F} 2022"]
        #expect(discover([:], history: history).map(\.port) == [0, 0, 0, 0, 2022])
    }

    // MARK: the mode (ssh.c:98-148, 626-708), launcher and script writer injected

    private var launched: [[String]] = []
    private var scripts: [String] = []
    private var launchResult: Result<Void, ApplicationLaunchFailure> = .success(())
    private var contents: [String: String] = [
        "/home/u/.ssh/config": "Host alpha beta gamma\n",
        "/home/u/.ssh/known_hosts": "plain ssh-ed25519 AAAA\n[jump]:2222 ssh-ed25519 AAAA\n",
    ]

    private func make(
        history: History? = nil, terminal: String? = "ghostty",
        sshCommand: String = "{terminal} -e {ssh-client} {host} [-p {port}]", sshClient: String = "ssh",
        parseHosts: Bool = false, parseKnownHosts: Bool = true
    ) -> SshMode {
        SshMode(
            home: home, files: files(contents), history: history, terminal: terminal, sshCommand: sshCommand,
            sshClient: sshClient, parseHosts: parseHosts, parseKnownHosts: parseKnownHosts,
            launcher: { [unowned self] argv in
                launched.append(argv)
                return launchResult
            },
            writeScript: { [unowned self] text, _ in
                scripts.append(text)
                return .success("/tmp/rofi-x.command")
            })
    }

    private func act(_ mode: SshMode, _ action: MenuAction, input: String? = nil, row: Int? = nil) -> ModeResult {
        var input = input
        return mode.result(action, input: &input, selectedRow: row)
    }

    /// A history file in a fresh directory, seeded with `contents`.
    private func withHistory(_ contents: String? = nil, _ body: (History) throws -> Void) throws {
        let name = "rofi-ssh-\(UInt64.random(in: .min ... .max))/rofi-2.sshcache"
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

    private func read(_ history: History) -> String? {
        guard let handle = fopen(history.url.path(percentEncoded: false), "r") else { return nil }
        defer { fclose(handle) }
        var bytes: [UInt8] = []
        while case let c = fgetc(handle), c != EOF { bytes.append(UInt8(c)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func nameIsSsh_ssh_c_710() {
        #expect(make().name == "ssh")
    }

    // ssh.c:661-687: a host with aliases shows them in parentheses.
    @Test func rowsShowAliases_ssh_c_661() {
        #expect(make().rows.map(\.text) == ["alpha ( beta, gamma )", "plain", "jump"])
    }

    // ssh.c:698-708: the host and each alias are matched on their own.
    @Test func matchesTheHostOrOneAlias_ssh_c_698() {
        let mode = make()
        let row = mode.rows[0]
        #expect(mode.matches(row, matcher: Matcher(query: "gam", options: MatchOptions())))
        #expect(!mode.matches(row, matcher: Matcher(query: "alpha beta", options: MatchOptions())))
        #expect(!mode.matches(row, matcher: Matcher(query: "(", options: MatchOptions())))
    }

    // ssh.c:98-120, config/config.c:68: a set terminal runs the template
    // unchanged; a port fills `[-p {port}]`, no port drops the group.
    @Test func setTerminalRunsTheTemplateArgv_ssh_c_105() {
        let mode = make()
        #expect(act(mode, .ok, row: 2) == .exit)
        #expect(act(mode, .ok, row: 1) == .exit)
        #expect(launched == [["ghostty", "-e", "ssh", "jump", "-p", "2222"], ["ghostty", "-e", "ssh", "plain"]])
        #expect(scripts.isEmpty)
    }

    // config/config.c:66-68: -ssh-client and -ssh-command reach the argv.
    @Test func sshClientAndCommandAreUsed_config_c_66() {
        let mode = make(terminal: "kitty", sshCommand: "{terminal} --hold -e {ssh-client} -v {host}", sshClient: "mosh")
        _ = act(mode, .ok, row: 1)
        #expect(launched == [["kitty", "--hold", "-e", "mosh", "-v", "plain"]])
    }

    // No -terminal: Terminal.app through the `.command` adapter.
    @Test func unsetTerminalOpensTerminalApp_ssh_c_105() {
        let mode = make(terminal: nil)
        #expect(act(mode, .ok, row: 2) == .exit)
        #expect(launched == [["/usr/bin/open", "-a", "Terminal", "/tmp/rofi-x.command"]])
        #expect(scripts == [TerminalLaunch.scriptText(innerArgv: ["ssh", "jump", "-p", "2222"])])
    }

    // ssh.c:632-635: typed text is the host as it is, with no port; ssh
    // itself reads `user@host`, and `host:port` is not split.
    @Test func customInputIsTheHostAsTyped_ssh_c_632() {
        let mode = make()
        #expect(act(mode, .customInput, input: "me@box") == .exit)
        #expect(act(mode, .customInput, input: "box:2222") == .exit)
        #expect(launched == [["ghostty", "-e", "ssh", "me@box"], ["ghostty", "-e", "ssh", "box:2222"]])
    }

    // ssh.c:128-130, 632-633: no host, nothing runs.
    @Test func emptyInputRunsNothing_ssh_c_632() {
        #expect(act(make(), .customInput, input: "") == .exit)
        #expect(act(make(), .customInput, input: nil) == .exit)
        #expect(act(make(), .ok, row: nil) == .exit)
        #expect(launched.isEmpty)
    }

    // ssh.c:138-147: a launch stores `host US port [US alias]...`.
    @Test func launchRecordsHistory_ssh_c_138() throws {
        try withHistory { history in
            let mode = make(history: history)
            _ = act(mode, .ok, row: 0)
            _ = act(mode, .ok, row: 2)
            // history.c:58-77: counts are rebased after each write.
            #expect(read(history) == "1 jump\u{1F}2222\n0 alpha\u{1F}0\u{1F}beta\u{1F}gamma\n")
        }
    }

    // ssh.c:502-541: history hosts come first with their port.
    @Test func historyHostsComeFirst_ssh_c_502() throws {
        try withHistory("3 old\u{1F}2200\n0 plain\u{1F}0\n") { history in
            let mode = make(history: history)
            #expect(mode.rows.map(\.text) == ["old", "plain", "alpha ( beta, gamma )", "jump"])
            _ = act(mode, .ok, row: 0)
            #expect(launched == [["ghostty", "-e", "ssh", "old", "-p", "2200"]])
        }
    }

    // ssh.c:132-134, helper.c:1426-1434: a failed launch records nothing.
    // ponytail: upstream exits after its error dialog; the message is shown
    // and the view stays here, as RunMode does.
    @Test func failedLaunchKeepsTheViewOpen_ssh_c_132() throws {
        try withHistory { history in
            launchResult = .failure(ApplicationLaunchFailure(command: "ghostty", reason: "boom"))
            let mode = make(history: history)
            #expect(act(mode, .ok, row: 1) == .reload)
            #expect(mode.message == "Failed to execute: 'ssh plain'\nError: 'boom'")
            #expect(read(history) == nil)
            launchResult = .success(())
            #expect(act(mode, .ok, row: 1) == .exit)
            #expect(mode.message == nil)
        }
    }

    // A template that cannot be split is reported the same way.
    @Test func badTemplateIsReported_helper_c_136() {
        let mode = make(sshCommand: "{terminal} -e '{host}")
        #expect(act(mode, .ok, row: 1) == .reload)
        #expect(mode.message?.hasPrefix("Failed to parse: '{terminal} -e '{host}'") == true)
        #expect(launched.isEmpty)
    }

    // ssh.c:636-642, 155-162: delete drops the history entry and reloads.
    // ponytail: upstream removes the bare host name, which never equals a
    // stored `host US port` line; the stored line is removed here.
    @Test func deleteRemovesTheHistoryEntry_ssh_c_636() throws {
        try withHistory("1 old\u{1F}2200\n0 plain\u{1F}0\n") { history in
            let mode = make(history: history)
            #expect(act(mode, .deleteEntry, row: 0) == .reload)
            #expect(read(history) == "0 plain\u{1F}0\n")
            #expect(mode.rows.map(\.text) == ["plain", "alpha ( beta, gamma )", "jump"])
            // A discovered host has no history line; nothing changes.
            #expect(act(mode, .deleteEntry, row: 2) == .reload)
            #expect(read(history) == "0 plain\u{1F}0\n")
        }
    }

    // ssh.c:628, 643-645: cancel exits and a custom key switches.
    @Test func cancelAndCustomKeys_ssh_c_643() {
        #expect(act(make(), .cancel) == .exit)
        #expect(act(make(), .customKey(3)) == .switchTo(3))
    }

    // config/config.c:103: no history at all is read or written.
    @Test func noHistoryRecordsNothing_config_c_103() {
        let mode = make(history: nil)
        #expect(act(mode, .ok, row: 1) == .exit)
        #expect(mode.rows.count == 3)
    }
}
