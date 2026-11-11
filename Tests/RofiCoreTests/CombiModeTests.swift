import RofiCore
import Testing

/// A submode recording what combi hands it.
private final class FakeMode: Mode {
    let name: String
    let rows: [Row]
    var displayName: String?
    var answer: ModeResult = .exit
    private(set) var calls: [(action: MenuAction, alt: Bool, input: String?, selectedRow: Int?)] = []
    private(set) var completions: [(input: String?, selectedRow: Int?)] = []

    init(_ name: String, _ rows: [String]) {
        self.name = name
        self.rows = rows.map { Row(parsing: $0) }
    }

    func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        result(action, alt: false, input: &input, selectedRow: selectedRow)
    }

    func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult {
        calls.append((action, alt, input, selectedRow))
        input = "rewritten"
        return answer
    }

    func complete(input: inout String?, selectedRow: Int?) -> ModeResult? {
        completions.append((input, selectedRow))
        return .reload
    }
}

// Contract: rofi's combi mode, source/modes/combi.c (parse_switchers 62-98,
// result 153-190, match 192-205, mgrv 208-254, completion 256-270,
// preprocess_input 301-343), and its options in config/config.c:127, 162-163.
@Suite struct CombiModeTests {
    private let run = FakeMode("run", ["firefox", "vim"])
    private let ssh = FakeMode("ssh", ["a<b"])

    private func combi(format: String? = "{mode} {text}") -> CombiMode {
        CombiMode(modes: [run, ssh], displayNames: ["Run", "ssh"], displayFormat: format)
    }

    // combi.c:100-111, 208-254: rows follow the mode order; a prefixed row is
    // escaped into markup, the mode's own display name first; a hidden prefix
    // leaves the text as it is. The text matched on is never prefixed.
    @Test func rowsAreCombinedInModeOrderAndPrefixed_combi_c_208() {
        ssh.displayName = "Hosts"
        let prefixed = combi()
        #expect(prefixed.rows.map(\.display) == ["Run firefox", "Run vim", "Hosts a&lt;b"])
        #expect(prefixed.rows.map(\.text) == ["firefox", "vim", "a<b"])
        #expect(prefixed.markupRows)

        let hidden = combi(format: nil)
        #expect(hidden.rows.map(\.display) == ["firefox", "vim", "a<b"])
        #expect(!hidden.markupRows)
    }

    // combi.c:153-200, 256-270: a row's action, alt flag included, reaches its
    // mode with a local index and may rewrite the query; typed text goes to
    // the first mode; completion names the mode.
    @Test func actionsReachTheOwningModeWithALocalRow_combi_c_153() {
        var switcher = ModeSwitcher(modes: [combi()])
        ssh.answer = .reload
        switcher.selectVisibleIndex(2)
        switcher.accept(alt: true)
        #expect(ssh.calls.map(\.action) == [.ok])
        #expect(ssh.calls.map(\.alt) == [true])
        #expect(ssh.calls.map(\.selectedRow) == [0])
        #expect(switcher.query == "rewritten")

        switcher.updateQuery("zzz")
        switcher.accept()
        #expect(run.calls.map(\.action) == [.customInput])
        #expect(run.calls.map(\.input) == ["zzz"])
        #expect(run.calls.map(\.selectedRow) == [nil])
        #expect(switcher.current.completion(at: 2) == "!ssh a<b")
    }

    // combi.c:301-343, 192-205: `!prefix rest` keeps the modes whose name
    // starts with prefix and matches their rows on rest.
    @Test func bangKeepsTheModesNamedByItsPrefix_combi_c_301() {
        var switcher = ModeSwitcher(modes: [combi()])
        switcher.updateQuery("!r vi")
        #expect(switcher.matches.map(\.sourceIndex) == [1])
        switcher.updateQuery("!s")
        #expect(switcher.matches.map(\.sourceIndex) == [2])
        switcher.updateQuery("!x")
        #expect(switcher.matches.isEmpty)
    }

    // combi.c:157-190: with a `!prefix` the named mode gets a copy of the
    // rest, its rewrite dropped, for an action or a completion; without one
    // a completion only reloads.
    @Test func bangRoutesACopyOfTheRest_combi_c_157() {
        let mode = combi()
        _ = mode.rows
        var input: String? = "!ss host"
        #expect(mode.result(.customInput, input: &input, selectedRow: nil) == .exit)
        #expect(ssh.calls.map(\.input) == ["host"])
        #expect(input == "!ss host")

        input = "!ssh"
        #expect(mode.complete(input: &input, selectedRow: 2) == .reload)
        #expect(ssh.completions.map(\.input) == [nil])
        #expect(ssh.completions.map(\.selectedRow) == [0])

        input = "fire"
        #expect(mode.complete(input: &input, selectedRow: 0) == .reload)
        #expect(run.completions.isEmpty)
    }

    // combi.c:62-98, config/config.c:127, 162-163: `-combi-modes` resolves
    // built-ins and scripts with their display names; combi itself and
    // unknown names are skipped with a warning, given only when combi is used.
    @Test func combiModesResolveAndWarn_combi_c_62() throws {
        func parse(_ argv: [String]) throws -> ShowOptions {
            try ShowOptions(arguments: Arguments(["rofi"] + argv), environment: ["HOME": "/nonexistent"])
        }
        let options = try parse([
            "-modes", "combi", "-combi-modes", "a:x,combi,nope,drun", "-display-drun", "Apps",
            "-combi-display-format", "{text} ({mode})",
        ])
        guard case .combi(let modes, let displayNames, let format) = options.modes.first else {
            Issue.record("combi expected")
            return
        }
        #expect(modes.map(\.name) == ["a", "drun"])
        #expect(displayNames == ["a", "Apps"])
        #expect(format == "{text} ({mode})")
        #expect(
            options.warnings == [
                "You cannot add 'combi' to the list of combined modes.\n", "Invalid script switcher: nope\n",
            ])

        let defaults = try parse(["-show", "combi", "-combi-hide-mode-prefix"])
        guard case .combi(let modes, _, let format) = defaults.modes.last else {
            Issue.record("combi expected")
            return
        }
        #expect(modes.map(\.name) == ["run"])
        #expect(format == nil)
        #expect(defaults.warnings.last == "Invalid script switcher: window\n")
        #expect(try parse(["-show", "drun"]).warnings.isEmpty)
    }
}
