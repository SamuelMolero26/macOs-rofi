import RofiCore
import Testing

// Contract: parse_pair/parse_ranges, rofi source/helper.c:1620-1670, and
// get_index plus the membership check in source/modes/dmenu.c:413-455.
@Suite struct RowRangeTests {
    @Test(arguments: [
        ("5", 5, 5),
        ("2-5", 2, 5),  // dash form: inclusive end
        ("2:5", 2, 4),  // colon form: exclusive end, like Python
        ("2-", 2, -1),  // empty end means the last row
        ("2:", 2, -1),  // empty end is not decremented
        ("-3", -3, -3),  // leading dash means a negative index, colon form
        ("-3:", -3, -1),
        ("-3:-1", -3, -2),
        ("  7", 7, 7),  // leading blanks are skipped
        ("x", 0, 0),  // strtol of a non-number is 0
    ])
    func parsesOnePair(input: String, start: Int, stop: Int) {
        #expect(parseRowRanges(input) == [RowRange(start: start, stop: stop)])
    }

    @Test func commaSeparatedListSkipsEmptyTokens() {
        #expect(parseRowRanges("1,,3-4") == [RowRange(start: 1, stop: 1), RowRange(start: 3, stop: 4)])
        #expect(parseRowRanges("").isEmpty)
    }

    @Test func membershipResolvesNegativeIndexesFromTheEnd() {
        let lastTwo = RowRange(start: -2, stop: -1)
        #expect((0..<5).filter { lastTwo.contains($0, rowCount: 5) } == [3, 4])
        #expect((0..<5).filter { RowRange(start: 1, stop: 2).contains($0, rowCount: 5) } == [1, 2])
    }

    @Test func outOfRangeStartMatchesNothing() {
        #expect(!(0..<5).contains { RowRange(start: -9, stop: -1).contains($0, rowCount: 5) })
    }

    @Test func outOfRangeStopMatchesEverythingFromStart() {
        // get_index returns UINT_MAX, so `index <= stop` is always true.
        #expect((0..<5).filter { RowRange(start: 2, stop: -9).contains($0, rowCount: 5) } == [2, 3, 4])
    }
}
