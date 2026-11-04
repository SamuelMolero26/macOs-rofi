import RofiCore
import Testing

// Contract: rofi_force_utf8, rofi source/helper.c:862-888.
// Expected bytes come from a C harness running rofi's function on glib 2.90.
@Suite struct ForceUTF8Tests {
    @Test(
        arguments: [
            ([0x61, 0x62, 0x63], [0x61, 0x62, 0x63]),
            ([], []),
            ([0xC3, 0xA9], [0xC3, 0xA9]),
        ] as [([UInt8], [UInt8])])
    func validInputIsUnchanged(input: [UInt8], expected: [UInt8]) {
        #expect(Array(forceUTF8(input).utf8) == expected)
    }

    // Each invalid byte becomes its own U+FFFD; Swift's String(decoding:)
    // would give one per maximal subpart instead.
    @Test(
        arguments: [
            ([0xE2, 0x82], 2),
            ([0xC0, 0xAF], 2),
            ([0xED, 0xA0, 0x80], 3),
            ([0xFF, 0xFE], 2),
            ([0xF4, 0x90, 0x80, 0x80], 4),
        ] as [([UInt8], Int)])
    func everyInvalidByteBecomesOneReplacement(input: [UInt8], count: Int) {
        #expect(forceUTF8(input) == String(repeating: "\u{FFFD}", count: count))
    }

    @Test func validTextAroundInvalidBytesIsKept() {
        #expect(forceUTF8([0xE2, 0x82, 0x41]) == "\u{FFFD}\u{FFFD}A")
        #expect(forceUTF8([0x61, 0x80, 0x62]) == "a\u{FFFD}b")
        #expect(forceUTF8([0xC3, 0xA9, 0xFF, 0x6F, 0x6B, 0xE2, 0x82, 0xAC]) == "é\u{FFFD}ok€")
    }
}
