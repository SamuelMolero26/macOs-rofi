// Not Foundation: importing it next to Testing pulls in the
// `_Testing_Foundation` cross-import overlay, which Command Line Tools ships
// without a module. File I/O goes through Darwin and URL through member lookup.
import Darwin
import Testing
import RofiCore

// Contract: history_set, history_remove and history_get_list with their file
// parsers and writer (rofi source/history.c:45-357, include/history.h:51-70).
// Defaults max_history_size 25, disable_history false and ignored_prefixes ""
// come from config/config.c:103-161.
@Suite struct HistoryTests {
    /// A history file in a fresh directory under the temporary directory,
    /// removed afterwards.
    private func withHistory(_ contents: String? = nil, _ body: (History) throws -> Void) throws {
        let name = "rofi-history-\(UInt64.random(in: .min ... .max))/history"
        let history = History(url: .temporaryDirectory.appending(path: name))
        let dir = history.url.deletingLastPathComponent().path(percentEncoded: false)
        let file = history.url.path(percentEncoded: false)
        try #require(mkdir(dir, 0o700) == 0)
        defer {
            unlink(file)
            rmdir(dir)
        }
        if let contents {
            let fd = try #require(fopen(file, "w"))
            fputs(contents, fd)
            fclose(fd)
        }
        try body(history)
    }

    private func contents(_ history: History) -> String? {
        guard let fd = fopen(history.url.path(percentEncoded: false), "r") else { return nil }
        defer { fclose(fd) }
        var bytes: [UInt8] = []
        while case let c = fgetc(fd), c != EOF { bytes.append(UInt8(c)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // rofi's own sequence, test/history-test.c:44-100.
    @Test func rofiReferenceSequence() throws {
        try withHistory { history in
            #expect(history.list() == [])
            history.set("aap")
            #expect(history.list() == ["aap"])
            history.remove("aap")
            #expect(history.list() == [])
            #expect(contents(history) == "", "removing the last entry leaves an empty file")
            history.set("aap")
            history.set("aap")
            #expect(history.list() == ["aap"])
            for n in 2...25 {
                history.set("aap\(n)")
                #expect(history.list().count == n)
            }
            history.set("blaat")
            #expect(history.list() == (2...25).map { "aap\($0)" } + ["blaat"], "the lowest count is dropped at 25")
        }
    }

    @Test func missingFileIsEmptyAndRemoveDoesNotCreateIt() throws {
        try withHistory { history in
            #expect(history.list() == [])
            history.remove("aap")
            #expect(contents(history) == nil)
        }
    }

    // Counts are rebased so the smallest is 0; ties keep file order
    // (stable g_qsort_with_data, history.c:58-77).
    @Test func fileFormatIsRebasedCountsSortedDescendingAndStable() throws {
        try withHistory { history in
            history.set("a")
            #expect(contents(history) == "0 a\n")
            history.set("b")
            #expect(contents(history) == "1 b\n0 a\n")
            history.set("a")
            #expect(contents(history) == "0 b\n0 a\n", "a tie keeps file order, so a stays behind b")
            history.set("a")
            #expect(contents(history) == "1 a\n0 b\n")
        }
    }

    @Test func onlyTheFirstDuplicateIsIncremented() throws {
        try withHistory("0 a\n0 a\n") { history in
            history.set("a")
            #expect(contents(history) == "1 a\n0 a\n")
        }
    }

    // history.c:288-293: the last entry is swapped into the removed slot
    // before the stable sort.
    @Test func removeSwapsTheLastEntryIntoTheGap() throws {
        try withHistory("0 a\n0 b\n0 c\n0 d\n") { history in
            history.remove("a")
            #expect(contents(history) == "0 d\n0 b\n0 c\n")
        }
    }

    @Test func removingAnUnknownEntryLeavesTheFileUntouched() throws {
        try withHistory("junk\n9 a\n") { history in
            history.remove("zz")
            #expect(contents(history) == "junk\n9 a\n")
        }
    }

    // __history_get_element_list (history.c:132-179), used by set and remove.
    @Test func setDropsMalformedLinesAndChopsAnUnterminatedLastLine() throws {
        let file = "\nx\nfoo bar\n5\n5 \n  7 seven\n-2 neg\n3xthree\n4 tail"
        try withHistory(file) { history in
            history.set("new")
            #expect(contents(history) == "9 seven\n6 tai\n5 three\n3 new\n0 neg\n")
        }
    }

    // __history_get_element_list_fields (history.c:80-130): everything after
    // the first space, count or not, in file order.
    @Test func listTakesTextAfterTheFirstSpace() throws {
        try withHistory("abc def\n5 \nnospace\n1 b\n0 last") { history in
            #expect(history.list() == ["def", "", "b", "las"])
        }
    }

    // The minimum is taken before the cap, so counts need not rebase to 0.
    @Test func capKeepsTheHighestCountsAndRebasesBeforeCutting() throws {
        try withHistory("5 a\n0 b\n") { history in
            var capped = history
            capped.maxSize = 1
            capped.set("a")
            #expect(contents(history) == "6 a\n")
        }
        try withHistory("1 b\n1 c\n") { history in
            var capped = history
            capped.maxSize = 2
            capped.set("d")
            #expect(contents(history) == "0 b\n0 c\n", "a new entry ties at 1 and sorts last, so it is cut")
        }
    }

    @Test func disabledHistoryNeitherReadsNorWrites() throws {
        try withHistory("0 a\n") { history in
            var disabled = history
            disabled.disabled = true
            #expect(disabled.list() == [])
            disabled.set("b")
            disabled.remove("a")
            #expect(contents(history) == "0 a\n")
        }
    }

    // history.c:188-202: `;`-separated prefixes, leading spaces skipped.
    @Test func ignoredPrefixesAreNotRecorded() throws {
        try withHistory { history in
            var filtered = history
            filtered.ignoredPrefixes = "sudo ;  git"
            filtered.set("sudo rm")
            filtered.set("git status")
            #expect(contents(history) == nil)
            filtered.set("ls")
            #expect(history.list() == ["ls"])
            filtered.ignoredPrefixes = "a; "
            filtered.set("zz")
            #expect(history.list() == ["ls"], "a blank prefix strips to \"\", which prefixes everything")
        }
    }

    @Test func entriesCompareAsBytes() throws {
        try withHistory { history in
            history.set("é")
            history.set("e\u{301}")
            #expect(history.list().count == 2, "strcmp, not canonical equivalence")
        }
    }
}
