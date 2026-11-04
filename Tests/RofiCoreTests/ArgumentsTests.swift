import RofiCore
import Testing

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

    @Test func bytesReturnTheRawValueOfTheFirstOccurrence() {
        let args = Arguments(rawArgv: [Array("rofi".utf8), Array("-input".utf8), [0x66, 0xFF]])
        #expect(args.bytes("-input") == [0x66, 0xFF])
        #expect(args.string("-input") == "f\u{FFFD}")
        #expect(args.bytes("-format") == nil)
    }

    @Test func charParsesTheValueLikeHelperParseChar() {
        #expect(Arguments(["rofi", "-sep", "|"]).char("-sep") == UInt8(ascii: "|"))
        #expect(Arguments(["rofi", "-sep", "\\t"]).char("-sep") == 0x09)
        #expect(Arguments(["rofi", "-sep"]).char("-sep") == nil)
        #expect(Arguments(["rofi"]).char("-sep") == nil)
    }

    // Contract: find_arg_uint, rofi source/helper.c:373-380.
    @Test func uintParsesLikeStrtoul() {
        #expect(Arguments(["rofi", "-l", "25"]).uint("-l") == 25)
        #expect(Arguments(["rofi", "-l", " +7"]).uint("-l") == 7)
        #expect(Arguments(["rofi", "-l", "12abc"]).uint("-l") == 12)
        #expect(Arguments(["rofi", "-l", "abc"]).uint("-l") == 0)
        #expect(Arguments(["rofi", "-l", ""]).uint("-l") == 0)
    }

    @Test func uintIsAlwaysBaseTen() {
        #expect(Arguments(["rofi", "-l", "010"]).uint("-l") == 10)
        #expect(Arguments(["rofi", "-l", "0x10"]).uint("-l") == 0)
    }

    @Test func uintWrapsIntoAnUnsignedInt() {
        #expect(Arguments(["rofi", "-l", "-1"]).uint("-l") == UInt32.max)
        #expect(Arguments(["rofi", "-l", "4294967299"]).uint("-l") == 3)
        #expect(Arguments(["rofi", "-l", "99999999999999999999999"]).uint("-l") == UInt32.max)
    }

    @Test func uintNeedsAFollowingArgument() {
        #expect(Arguments(["rofi", "-l"]).uint("-l") == nil)
        #expect(Arguments(["rofi"]).uint("-l") == nil)
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
