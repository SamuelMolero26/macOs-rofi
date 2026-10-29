import Darwin
import Testing
import RofiCore

// Contract: dmenu_mode_dialog -dump path, rofi source/modes/dmenu.c:989-1034;
// options from source/modes/dmenu.c:550-560, 605-608 and source/helper.c:695-731.
@Suite struct DmenuDumpTests {
    private func dump(_ argv: [String]) throws -> DmenuDump {
        try DmenuDump(arguments: Arguments(["rofi", "-dmenu", "-dump"] + argv))
    }

    private let fruit = ["apple", "Banana", "cherry"].map { Row(parsing: $0) }

    @Test func defaults() throws {
        let options = try dump([])
        #expect(options.format == "s")
        #expect(options.separator == 0x0A)
        #expect(options.filter == nil)
        #expect(!options.autoSelect)
        #expect(!options.onlyMatch)
        #expect(options.match.method == .normal)
        #expect(options.match.tokenize)
        #expect(!options.match.caseSmart)
        #expect(!options.match.normalize)
        #expect(options.match.negateChar == "-")
        // dmenu forces case sensitivity on (dmenu.c:605-606).
        #expect(options.match.caseSensitive)
    }

    @Test func readsTheStringAndCharOptions() throws {
        let options = try dump(["-format", "i:s", "-sep", "|", "-filter", "an", "-matching-negate-char", "!"])
        #expect(options.format == "i:s")
        #expect(options.separator == UInt8(ascii: "|"))
        #expect(options.filter == "an")
        #expect(options.match.negateChar == "!")
    }

    @Test func readsTheBooleanOptions() throws {
        let options = try dump(["-no-tokenize", "-case-smart", "-normalize-match", "-auto-select"])
        #expect(!options.match.tokenize)
        #expect(options.match.caseSmart)
        #expect(options.match.normalize)
        #expect(options.autoSelect)
    }

    @Test(arguments: ["-only-match", "-no-custom"])
    func onlyMatchHasTwoSpellings(flag: String) throws {
        #expect(try dump([flag]).onlyMatch)
    }

    @Test func dashIOverridesCaseSensitive() throws {
        #expect(!(try dump(["-case-sensitive", "-i"]).match.caseSensitive))
        #expect(try dump(["-no-case-sensitive"]).match.caseSensitive)
    }

    @Test func matchingUsesTheFirstMethodIgnoringCase() throws {
        #expect(try dump(["-matching", "FUZZY,regex"]).match.method == .fuzzy)
        #expect(try dump(["-matching", "prefix"]).match.method == .prefix)
        // g_strsplit("") yields no items, so the default stays.
        #expect(try dump(["-matching", ""]).match.method == .normal)
    }

    @Test func anUnknownMatchingMethodAnywhereIsAnError() {
        #expect(throws: InvalidMatchingMethod(name: "bogus")) { try dump(["-matching", "bogus"]) }
        #expect(throws: InvalidMatchingMethod(name: "bogus")) { try dump(["-matching", "normal,bogus"]) }
    }

    @Test func onlyMatchWithNoRowsPrintsNothing() throws {
        #expect(try dump(["-only-match"]).dump(rows: []) == [])
    }

    @Test func autoSelectWithOneRowSkipsTheFilter() throws {
        let options = try dump(["-auto-select", "-filter", "zzz", "-format", "i:s:f"])
        #expect(options.dump(rows: [Row(parsing: "only")]) == ["0:only:zzz\n"])
    }

    @Test func autoSelectWithSeveralRowsStillFilters() throws {
        let options = try dump(["-auto-select", "-filter", "zzz"])
        #expect(options.dump(rows: fruit) == [])
    }

    @Test func dumpPrintsMatchesWithTheirOriginalIndex() throws {
        let options = try dump(["-filter", "an", "-i", "-format", "i:s"])
        #expect(options.dump(rows: fruit) == ["1:Banana\n"])
    }

    @Test func dumpIsCaseSensitiveWithoutDashI() throws {
        #expect(try dump(["-filter", "an"]).dump(rows: fruit) == ["Banana\n"])
        #expect(try dump(["-filter", "AN"]).dump(rows: fruit) == [])
        #expect(try dump(["-filter", "AN", "-i"]).dump(rows: fruit) == ["Banana\n"])
    }

    @Test func noFilterPrintsEveryRowInOrderAndAnEmptyF() throws {
        let options = try dump(["-format", "d[f]s"])
        #expect(options.dump(rows: fruit) == ["1[]apple\n", "2[]Banana\n", "3[]cherry\n"])
    }

    @Test func dumpMatchesOnlyTheRowText() throws {
        let rows = [Row(parsing: "apple\0display\u{1F}banana"), Row(parsing: "banana")]
        #expect(try dump(["-filter", "ban", "-format", "i"]).dump(rows: rows) == ["1\n"])
    }

    @Test func readRowsReadsToEndOfInput() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let bytes = Array("a|b".utf8)
        #expect(write(fds[1], bytes, bytes.count) == bytes.count)
        close(fds[1])
        #expect(readRows(fileDescriptor: fds[0], separator: UInt8(ascii: "|")).map(\.text) == ["a", "b"])
        close(fds[0])
    }
}
