import Testing
import RofiCore

// Contract: -markup-rows, -password, -keep-right and -ellipsize-mode reading
// (source/modes/dmenu.c:986-1001, 1039-1055), the listview default
// (source/widgets/listview.c:804) and markup-stripped matching
// (source/modes/dmenu.c:668-708) against raw -dump/-select (1005-1028).
@Suite struct RenderingFlagsTests {
    private func pipeline(_ argv: [String]) throws -> DmenuPipeline {
        try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
    }

    /// A session made by `start`, the production entry point.
    private func makeSession(_ argv: [String], _ lines: [String]) throws -> DmenuSession {
        let session: DmenuSession? = if case .session(let session) = try pipeline(argv).start(rows: lines.map { Row(parsing: $0) }) {
            session
        } else {
            nil
        }
        return try #require(session, "Expected an interactive dmenu session")
    }

    /// The raw text of each visible row.
    private func visible(_ argv: [String], _ lines: [String]) throws -> [String] {
        try makeSession(argv, lines).matches.map(\.row.text)
    }

    @Test func defaults() throws {
        let plain = try pipeline([])
        #expect(!plain.markupRows)
        #expect(!plain.password)
        #expect(plain.ellipsizeMode == .end)
    }

    @Test func booleanFlags() throws {
        #expect(try pipeline(["-markup-rows"]).markupRows)
        #expect(try pipeline(["-password"]).password)
    }

    @Test(arguments: [
        ([], EllipsizeMode.end),
        (["-keep-right"], .start),
        (["-ellipsize-mode", "middle"], .middle),
        (["-ellipsize-mode", "MIDDLE"], .middle),
        (["-ellipsize-mode", "Start"], .start),
        (["-keep-right", "-ellipsize-mode", "end"], .end),
        // -ellipsize-mode is applied after -keep-right whatever the order.
        (["-ellipsize-mode", "middle", "-keep-right"], .middle),
        // An unknown mode keeps the previous one.
        (["-ellipsize-mode", "bogus"], .end),
        (["-keep-right", "-ellipsize-mode", "bogus"], .start),
    ])
    func ellipsizeMode(argv: [String], expected: EllipsizeMode) throws {
        #expect(try pipeline(argv).ellipsizeMode == expected)
    }

    @Test func markupRowsMatchTheStrippedText() throws {
        #expect(try visible(["-markup-rows", "-filter", "foo"], ["<b>foo</b>"]) == ["<b>foo</b>"])
        #expect(try visible(["-markup-rows", "-filter", "b"], ["<b>foo</b>"]) == [])
        #expect(try visible(["-filter", "b"], ["<b>foo</b>"]) == ["<b>foo</b>"])
    }

    @Test func queryChangesMatchTheStrippedText() throws {
        var session = try makeSession(["-markup-rows"], ["<b>foo</b>", "bar"])
        _ = session.updateQuery("b")
        #expect(session.matches.map(\.sourceIndex) == [1])
        session.appendRows([Row(parsing: "<i>baz</i>"), Row(parsing: "<u>x</u>")])
        #expect(session.matches.map(\.sourceIndex) == [1, 2])
    }

    // pango_parse_markup leaves the stripped text NULL, so the row never
    // matches, even an empty query.
    @Test func invalidMarkupRowsNeverMatch() throws {
        #expect(try visible(["-markup-rows"], ["<b>x", "ok", "a & b"]) == ["ok"])
        #expect(try visible([], ["<b>x", "ok"]) == ["<b>x", "ok"])
    }

    @Test func outputStaysRaw() throws {
        let session = try makeSession(["-markup-rows", "-filter", "foo"], ["<b>foo</b>"])
        #expect(session.accept()?.output == "<b>foo</b>\n")
    }

    @Test func dumpMatchesRawText() throws {
        let dump = try pipeline(["-dump", "-markup-rows", "-filter", "b"])
        #expect(dump.dump(rows: [Row(parsing: "<b>foo</b>"), Row(parsing: "<b>x")]) == ["<b>foo</b>\n", "<b>x\n"])
    }

    @Test func selectMatchesRawText() throws {
        let session = try makeSession(["-markup-rows", "-select", "b"], ["<i>x</i>", "<b>y</b>", "b"])
        #expect(session.selectedVisibleIndex == 1)
    }
}
