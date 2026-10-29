import Testing
import RofiCore

// Contract: read_input_sync and read_input_thread,
// rofi source/modes/dmenu.c:246-346.
@Suite struct RowSplitterTests {
    private func split(_ input: String, separator: UInt8 = 0x0A) -> [String] {
        var splitter = RowSplitter(separator: separator)
        var rows = splitter.feed(Array(input.utf8))
        if let last = splitter.finish() { rows.append(last) }
        return rows.map(\.text)
    }

    @Test func emptyRowsAreKeptButATrailingSeparatorAddsNone() {
        #expect(split("a\nb") == ["a", "b"])
        #expect(split("a\n") == ["a"])
        #expect(split("a\n\nb\n") == ["a", "", "b"])
        #expect(split("\n") == [""])
        #expect(split("") == [])
    }

    @Test func customSeparatorLeavesNewlinesInTheText() {
        #expect(split("a\nb|c", separator: UInt8(ascii: "|")) == ["a\nb", "c"])
    }

    // With -sep '\0' the NUL ends the row, so no extras are parsed.
    @Test func nulSeparatorSplitsBeforeExtrasAreSeen() {
        #expect(split("a\0icon\u{1F}x", separator: 0) == ["a", "icon\u{1F}x"])
    }

    @Test func rowsSpanFeedsAndArriveAsSoonAsTheyEnd() {
        var splitter = RowSplitter(separator: 0x0A)
        #expect(splitter.feed(Array("ab".utf8)).isEmpty)
        #expect(splitter.feed(Array("c\nd".utf8)).map(\.text) == ["abc"])
        #expect(splitter.feed([0xC3]).isEmpty)
        #expect(splitter.feed([0xA9, 0x0A]).map(\.text) == ["dé"])
        #expect(splitter.finish() == nil)
    }

    @Test func finishFlushesTheRemainderOnce() {
        var splitter = RowSplitter(separator: 0x0A)
        _ = splitter.feed(Array("tail".utf8))
        #expect(splitter.finish()?.text == "tail")
        #expect(splitter.finish() == nil)
    }
}
