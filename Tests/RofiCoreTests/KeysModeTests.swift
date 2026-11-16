import RofiCore
import Testing

// Contract: rofi's keys mode, source/modes/help-keys.c (rows from
// config_parser_return_display_help, source/xrmoptions.c:1240-1330; result
// 68-76; markup 93; match 99-104), registered after combi (source/rofi.c:
// 732-739).
@Suite struct KeysModeTests {
    private func keysMode(_ argv: [String]) throws -> any Mode {
        let options = try ShowOptions(arguments: Arguments(["rofi", "-modes", "keys"] + argv), environment: [:])
        return try #require(makeModes(options.modes).first)
    }

    // xrmoptions.c:1252-1257, keyb.c order: `<b>name</b> (binding) <span>
    // comment</span>`, escaped, names padded alike; `-kb-*` values show as
    // given; the markup itself is matched on.
    @Test func rowsListBindingsInUpstreamOrderWithOverrides_xrmoptions_c_1252() throws {
        let mode = try keysMode(["-kb-accept-custom", "Control+<,Alt+x"])
        #expect(mode.name == "keys")
        #expect(mode.markupRows)
        #expect(mode.rows.count == KeyAction.allCases.count)
        #expect(
            mode.rows[0].text
                == "<b>kb-accept-custom    </b> (Control+&lt;,Alt+x) "
                + "<span style='italic' size='small'>Use entered text as command (in ssh/run modes)</span>")
        #expect(mode.rows[4].text.hasPrefix("<b>kb-mode-complete    </b> (Control+l) "))
        #expect(mode.rows[6].text.hasPrefix("<b>kb-page-prev        </b> (Page_Up) "))
        #expect(mode.rows[10].text.hasPrefix("<b>kb-custom-1         </b> (Alt+1) "))
        #expect(mode.matches(mode.rows[0], matcher: Matcher(query: "span", options: MatchOptions())))
    }

    // help-keys.c:68-76: read-only; a custom key switches to the mode with
    // its index, every other action closes rofi without output.
    @Test func customKeySwitchesModeElseExits_help_keys_c_68() throws {
        let mode = try keysMode([])
        var input: String? = "kb"
        #expect(mode.result(.ok, input: &input, selectedRow: 0) == .exit)
        #expect(mode.result(.customInput, input: &input, selectedRow: nil) == .exit)
        #expect(mode.result(.cancel, input: &input, selectedRow: nil) == .exit)
        #expect(mode.result(.customKey(2), input: &input, selectedRow: 0) == .switchTo(2))
        #expect(input == "kb")
    }

    // source/modes/combi.c:62-98: keys is a built-in combi can hold.
    @Test func keysWorksInsideCombi_combi_c_62() throws {
        let options = try ShowOptions(
            arguments: Arguments(["rofi", "-modes", "combi", "-combi-modes", "keys"]), environment: [:])
        let combi = try #require(makeModes(options.modes).first)
        #expect(combi.rows.count == KeyAction.allCases.count)
    }
}
