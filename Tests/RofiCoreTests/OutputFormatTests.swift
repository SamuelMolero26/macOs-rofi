import RofiCore
import Testing

// Contract: rofi_output_formatted_line (rofi source/helper.c:1693-1731) and the
// dmenu exit codes (source/modes/dmenu.c:796-802, 888-891).
@Suite struct OutputFormatTests {
    private func line(_ format: String, _ entry: String = "entry", index: Int = 2, filter: String? = "fi") -> String {
        formatOutputLine(format, entry: entry, index: index, filter: filter)
    }

    @Test func entryIndexAndLiterals() {
        #expect(line("s") == "entry\n")
        #expect(line("i") == "2\n")
        #expect(line("d") == "3\n")
        #expect(line("s:i x") == "entry:2 x\n", "unknown characters are printed literally")
        #expect(line("") == "\n")
    }

    @Test func customInputUsesIndexMinusOne() {
        #expect(line("i,d", index: -1) == "-1,0\n")
    }

    @Test func shellQuotingMatchesGShellQuote() {
        #expect(line("q", "it's here") == "'it'\\''s here'\n")
        #expect(line("F", filter: "a b") == "'a b'\n")
        #expect(line("q", "") == "''\n")
    }

    @Test func filterIsEmptyWhenAbsent() {
        #expect(line("f") == "fi\n")
        #expect(line("[f][F]", filter: nil) == "[][]\n")
    }

    @Test func pangoMarkupIsStripped() {
        #expect(line("p", "<b>bold</b> &amp; <span foreground=\"red\">red</span>") == "bold & red\n")
        #expect(line("p", "&#65;&lt;") == "A<\n")
        #expect(line("p", "plain") == "plain\n")
        // Span attribute values are not validated, so they still strip.
        #expect(line("p", "<span bogus=\"1\" foreground=\"nope\">x</span>") == "x\n")
    }

    @Test(arguments: ["a & b", "<b>unclosed", "<foo>x</foo>"])
    func invalidMarkupPrintsInvalidString(entry: String) {
        #expect(line("p", entry) == "invalid string\n")
    }

    @Test func dmenuExitCodes() {
        #expect(DmenuOutcome.accepted.exitCode == 0)
        #expect(DmenuOutcome.cancelled.exitCode == 1)
        #expect(DmenuOutcome.customKey(1).exitCode == 10)
        #expect(DmenuOutcome.customKey(19).exitCode == 28)
    }
}
