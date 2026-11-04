import RofiCore
import Testing

// Contract: dmenuscript_parse_entry_extras, rofi source/modes/script.c:89-131,
// and the NUL split in source/modes/dmenu.c:176-189.
@Suite struct RowTests {
    @Test func plainLineHasNoExtras() {
        let row = Row(parsing: "firefox")
        #expect(row.text == "firefox")
        #expect(row.icons.isEmpty)
        #expect(row.display == nil && row.meta == nil && row.info == nil)
        #expect(!row.nonselectable && !row.permanent && !row.urgent && !row.active)
    }

    @Test func extrasAfterNulAreKeyValuePairs() {
        let row = Row(
            parsing: "ff\0icon\u{1F}firefox,web\u{1F}display\u{1F}Firefox\u{1F}meta\u{1F}browser\u{1F}info\u{1F}id-1")
        #expect(row.text == "ff")
        #expect(row.icons == ["firefox", "web"])
        #expect(row.display == "Firefox")
        #expect(row.meta == "browser")
        #expect(row.info == "id-1")
    }

    @Test func keysAndBooleanValuesAreCaseInsensitive() {
        let row = Row(
            parsing: "x\0NonSelectable\u{1F}TRUE\u{1F}permanent\u{1F}true\u{1F}URGENT\u{1F}True\u{1F}active\u{1F}yes")
        #expect(row.nonselectable && row.permanent && row.urgent)
        #expect(!row.active, "only the word true enables a flag")
    }

    @Test func unpairedTrailingKeyAndUnknownKeysAreIgnored() {
        let row = Row(parsing: "x\0bogus\u{1F}1\u{1F}meta\u{1F}m\u{1F}display")
        #expect(row.meta == "m")
        #expect(row.display == nil)
    }

    @Test func onlyBytesBeforeTheSecondNulAreExtras() {
        let row = Row(parsing: "x\0meta\u{1F}m\0display\u{1F}d")
        #expect(row.meta == "m")
        #expect(row.display == nil)
    }

    @Test func iconListKeepsInnerEmptiesAndEmptyValueMeansNoIcons() {
        #expect(Row(parsing: "x\0icon\u{1F}a,,b").icons == ["a", "", "b"])
        #expect(Row(parsing: "x\0icon\u{1F}").icons.isEmpty)
    }

    // read_add passes only the bytes before the NUL to rofi_force_utf8
    // (source/modes/dmenu.c:181-190).
    @Test func bytesRepairInvalidUTF8InTheTextOnly() {
        let row = Row(parsing: [0x61, 0xFF, 0x00] + Array("icon\u{1F}term".utf8))
        #expect(row.text == "a\u{FFFD}")
        #expect(row.icons == ["term"])
    }

    @Test func bytesWithALeadingNulHaveEmptyText() {
        #expect(Row(parsing: [0x00] as [UInt8]).text == "")
        #expect(Row(parsing: [UInt8]()).text == "")
    }
}
