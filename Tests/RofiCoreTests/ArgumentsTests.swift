import Testing
import RofiCore

// Contract: find_arg, find_arg_str, find_arg_char, rofi source/helper.c:325-342, 431-439;
// boolean options, rofi source/xrmoptions.c:760-771.
@Suite struct ArgumentsTests {
    @Test func hasMatchesExactlyIgnoringASCIICase() {
        let args = Arguments(["rofi", "-DMenu"])
        #expect(args.has("-dmenu"))
        #expect(!args.has("--dmenu"))
        #expect(!Arguments(["rofi", "--dmenu"]).has("-dmenu"))
        #expect(!args.has("-dmen"))
    }

    @Test func hasScansValuesAndArgvZeroToo() {
        #expect(Arguments(["rofi", "-filter", "-i"]).has("-i"))
        #expect(Arguments(["-dump"]).has("-dump"))
    }

    @Test func stringIsTheNextArgumentOfTheFirstOccurrence() {
        let args = Arguments(["rofi", "-format", "i", "-format", "s"])
        #expect(args.string("-format") == "i")
        #expect(args.string("-filter") == nil)
    }

    @Test func stringNeedsAFollowingArgument() {
        #expect(Arguments(["rofi", "-format"]).string("-format") == nil)
    }

    @Test func stringIgnoresTheFlagInPositionZero() {
        // The first occurrence wins even when it cannot take a value.
        #expect(Arguments(["-format", "a", "-format", "b"]).string("-format") == nil)
    }

    @Test func charParsesTheValueLikeHelperParseChar() {
        #expect(Arguments(["rofi", "-sep", "|"]).char("-sep") == UInt8(ascii: "|"))
        #expect(Arguments(["rofi", "-sep", "\\t"]).char("-sep") == 0x09)
        #expect(Arguments(["rofi", "-sep"]).char("-sep") == nil)
        #expect(Arguments(["rofi"]).char("-sep") == nil)
    }

    @Test func boolKeepsTheDefaultWhenAbsent() {
        #expect(Arguments(["rofi"]).bool("tokenize", default: true))
        #expect(!Arguments(["rofi"]).bool("case-smart", default: false))
    }

    @Test func boolFlagSetsTrueAndNoFlagSetsFalse() {
        #expect(Arguments(["rofi", "-case-smart"]).bool("case-smart", default: false))
        #expect(!Arguments(["rofi", "-NO-tokenize"]).bool("tokenize", default: true))
    }

    @Test func boolFlagWinsOverNoFlag() {
        #expect(Arguments(["rofi", "-no-tokenize", "-tokenize"]).bool("tokenize", default: false))
    }
}
