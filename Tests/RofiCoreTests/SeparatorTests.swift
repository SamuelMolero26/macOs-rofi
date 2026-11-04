import Testing
import RofiCore

// Contract: helper_parse_char, rofi source/helper.c:383-429.
@Suite struct SeparatorTests {
    @Test func singleCharacterIsLiteral() {
        #expect(parseSeparator("a") == UInt8(ascii: "a"))
        #expect(parseSeparator("|") == UInt8(ascii: "|"))
    }

    @Test(arguments: [
        ("\\n", 0x0A), ("\\a", 0x07), ("\\b", 0x08), ("\\t", 0x09),
        ("\\v", 0x0B), ("\\f", 0x0C), ("\\r", 0x0D), ("\\\\", 0x5C), ("\\0", 0x00),
    ])
    func backslashEscapes(arg: String, expected: Int) {
        #expect(parseSeparator(arg) == UInt8(expected))
    }

    @Test func hexEscapeReadsLeadingHexDigits() {
        #expect(parseSeparator("\\x1f") == 0x1F)
        #expect(parseSeparator("\\x41zz") == 0x41)
    }

    @Test(arguments: [
        ("\\x 41", 0x41), ("\\x+41", 0x41), ("\\x-1", 0xFF),
        ("\\x0x41", 0x41), ("\\x8000000000000000", 0xFF),
    ])
    func hexEscapeUsesStrtolSyntaxAndOverflow(arg: String, expected: Int) {
        #expect(parseSeparator(arg) == UInt8(expected))
    }

    @Test func hexEscapeTruncatesToOneByteLikeCCharCast() {
        #expect(parseSeparator("\\x1FF") == 0xFF)
    }

    @Test(arguments: ["", "ab", "\\q", "\\x", "é"])
    func anythingElseFallsBackToNewline(arg: String) {
        #expect(parseSeparator(arg) == 0x0A)
    }
}
