import Testing
import RofiCore

// Contract: dmenu_format_output_string (source/modes/dmenu.c:365-411), its
// display source (469-477) and the option reading (659-664).
@Suite struct DisplayColumnsTests {
    /// A session made by `start`, the production entry point.
    private func makeSession(_ argv: [String], _ lines: [String]) throws -> DmenuSession {
        let pipeline = try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
        let session: DmenuSession? = if case .session(let session) = pipeline.start(rows: lines.map { Row(parsing: $0) }) {
            session
        } else {
            nil
        }
        return try #require(session, "Expected an interactive dmenu session")
    }

    /// The display string of each row.
    private func displayed(_ argv: [String], _ lines: [String]) throws -> [String] {
        let session = try makeSession(argv, lines)
        return session.matches.map { session.displayText(for: $0) }
    }

    @Test(arguments: [
        ("3,1", "c\ta"),
        ("2", "b"),
        // Only a list position after the first gets a tab, so an invalid
        // first index leaves a leading tab.
        ("9,2", "\tb"),
        ("0,4,2", "\tb"),
        // g_ascii_strtoull: leading whitespace, trailing garbage, no digits.
        (" 2,2abc", "b\tb"),
        ("abc,2", "\tb"),
        ("-1,3", "\tc"),
        ("", ""),
    ])
    func columnsPickOneBasedPiecesJoinedByTabs(columns: String, expected: String) throws {
        #expect(try displayed(["-display-columns", columns], ["a\tb\tc"]) == [expected])
    }

    @Test func separatorIsACaseInsensitiveRegex() throws {
        #expect(try displayed(["-display-columns", "3,2,1", "-display-column-separator", "[,;]"], ["a,b;c"])
            == ["c\tb\ta"])
        #expect(try displayed(["-display-columns", "2", "-display-column-separator", "x"], ["aXb"]) == ["b"])
    }

    // g_regex_split_simple keeps empty pieces and capture groups, splits an
    // empty match between characters, and splits "" into nothing.
    @Test(arguments: [
        ("2,3", "\t", "a\t\tc", "\tc"),
        ("2,1", "\t", "a\t", "\ta"),
        ("2", "(,)", "a,b", ","),
        ("2,1", "x*", "ab", "b\ta"),
        ("1", "\t", "", ""),
    ])
    func splittingFollowsGLib(columns: String, separator: String, line: String, expected: String) throws {
        #expect(try displayed(["-display-columns", columns, "-display-column-separator", separator], [line])
            == [expected])
    }

    @Test func invalidSeparatorShowsNothingButTheBallot() throws {
        #expect(try displayed(["-display-columns", "1", "-display-column-separator", "("], ["a"]) == [""])
        #expect(try displayed(["-display-columns", "1", "-display-column-separator", "(", "-multi-select"], ["a"])
            == ["☐ "])
    }

    @Test func separatorIsIgnoredWithoutColumns() throws {
        #expect(try displayed(["-display-column-separator", "b"], ["a\tb\tc"]) == ["a\tb\tc"])
    }

    @Test func displayExtraReplacesTheTextAsSource() throws {
        let row = "raw\0display\u{1f}x\ty"
        #expect(try displayed([], [row]) == ["x\ty"])
        #expect(try displayed(["-display-columns", "2"], [row]) == ["y"])
    }

    @Test func multiSelectPrefixesTheBallotToTheDisplayString() throws {
        #expect(try displayed(["-multi-select"], ["raw\0display\u{1f}shown"]) == ["☐ shown"])
        #expect(try displayed(["-multi-select", "-display-columns", "3,1"], ["a\tb\tc"]) == ["☐ c\ta"])
    }

    @Test func matchingAndOutputKeepTheRawText() throws {
        let argv = ["-display-columns", "2", "-format", "i:s"]
        let lines = ["a\tb\tc", "1:Banana"]
        let rows = lines.map { Row(parsing: $0) }
        let columns = try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
        let plain = try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu", "-format", "i:s"]))

        #expect(columns.dump(rows: rows) == plain.dump(rows: rows))
        // "b" is the displayed column of the first row, but matching sees
        // the whole text, so "c" still finds it.
        var session = try makeSession(argv, lines)
        #expect(session.updateQuery("c") == nil)
        #expect(session.matches.map(\.sourceIndex) == [0])
        #expect(session.accept()?.output == "0:a\tb\tc\n")
    }
}
