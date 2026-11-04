import RofiCore
import Testing

// Contract: the Pango markup subset rofi rows and messages use
// (pango_parse_markup, as called from source/helper.c:1700-1709 and
// source/modes/dmenu.c:680-682).
@Suite struct MarkupTests {
    /// Each run as its text and attributes.
    private func runs(_ markup: String) throws -> [(String, MarkupAttributes)] {
        let parsed = try #require(parsePangoMarkup(markup), "Expected valid markup")
        return parsed.runs.map { (String(parsed.text[$0.range]), $0.attributes) }
    }

    private func attributes(_ markup: String) throws -> MarkupAttributes {
        let all = try runs(markup)
        try #require(all.count == 1, "Expected one run, got \(all.count)")
        return all[0].1
    }

    private func bold() -> MarkupAttributes {
        var attributes = MarkupAttributes()
        attributes.bold = true
        return attributes
    }

    @Test func plainTextHasNoRuns() throws {
        let parsed = try #require(parsePangoMarkup("plain"))
        #expect(parsed.text == "plain")
        #expect(parsed.runs.isEmpty)
    }

    @Test func boldRunCoversOnlyItsText() throws {
        #expect(parsePangoMarkup("<b>foo</b>bar")?.text == "foobar")
        let all = try runs("<b>foo</b>bar")
        #expect(all.map(\.0) == ["foo"])
        #expect(all.map(\.1) == [bold()])
    }

    @Test func nestedTagsCombine() throws {
        var boldItalic = bold()
        boldItalic.italic = true
        let all = try runs("<b>a<i>b</i></b>")
        #expect(all.map(\.0) == ["a", "b"])
        #expect(all.map(\.1) == [bold(), boldItalic])
    }

    @Test func simpleTags() throws {
        #expect(try attributes("<i>x</i>").italic)
        #expect(try attributes("<u>x</u>").underline)
        #expect(try attributes("<s>x</s>").strikethrough)
        #expect(try attributes("<tt>x</tt>").monospace)
        #expect(try attributes("<sub>x</sub>").script == .sub)
        #expect(try attributes("<sup>x</sup>").script == .sup)
    }

    @Test func relativeSizesMultiply() throws {
        #expect(try attributes("<big>x</big>").scale == 1.2)
        #expect(try attributes("<small>x</small>").scale == 1 / 1.2)
        #expect(try attributes("<big><big>x</big></big>").scale == 1.2 * 1.2)
        #expect(try attributes("<sup>x</sup>").scale == 1 / 1.2)
        #expect(try attributes("<span size=\"larger\">x</span>").scale == 1.2)
    }

    @Test func spanSizes() throws {
        #expect(try attributes("<span size=\"xx-large\">x</span>").scale == 1.2 * 1.2 * 1.2)
        #expect(try runs("<big><span size=\"medium\">x</span></big>").isEmpty)
        let points = try attributes("<big><span size=\"12pt\">x</span></big>")
        #expect(points.pointSize == 12)
        #expect(points.scale == 1)
        #expect(try attributes("<span size=\"10240\">x</span>").pointSize == 10)
    }

    @Test func spanColors() throws {
        #expect(
            try attributes("<span foreground=\"#ff0000\">x</span>").foreground
                == MarkupColor(red: 255, green: 0, blue: 0))
        #expect(
            try attributes("<span fgcolor=\"#0f0\">x</span>").foreground
                == MarkupColor(red: 0, green: 255, blue: 0))
        #expect(
            try attributes("<span color=\"#0000FF80\">x</span>").foreground
                == MarkupColor(red: 0, green: 0, blue: 255, alpha: 128))
        #expect(
            try attributes("<span background=\"#123456\">x</span>").background
                == MarkupColor(red: 0x12, green: 0x34, blue: 0x56))
        #expect(
            try attributes("<span bgcolor=\"#abcd\">x</span>").background
                == MarkupColor(red: 0xAA, green: 0xBB, blue: 0xCC, alpha: 0xDD))
    }

    @Test func spanTextAttributes() throws {
        #expect(try attributes("<span weight=\"bold\">x</span>").bold)
        #expect(try attributes("<span weight=\"700\">x</span>").bold)
        #expect(try runs("<b><span weight=\"normal\">x</span></b>").isEmpty)
        #expect(try attributes("<span style=\"italic\">x</span>").italic)
        #expect(try attributes("<span style=\"oblique\">x</span>").italic)
        #expect(try attributes("<span underline=\"single\">x</span>").underline)
        #expect(try runs("<u><span underline=\"none\">x</span></u>").isEmpty)
        #expect(try attributes("<span strikethrough=\"true\">x</span>").strikethrough)
        #expect(try attributes("<span font_family=\"Menlo\">x</span>").fontFamily == "Menlo")
        #expect(try attributes("<span face=\"Menlo\">x</span>").fontFamily == "Menlo")
    }

    @Test func unknownOrUnparsableSpanAttributesAreIgnored() throws {
        #expect(try runs("<span bogus=\"1\" foreground=\"red\" weight=\"heavyish\">x</span>").isEmpty)
        #expect(parsePangoMarkup("<span bogus=\"1\">x</span>")?.text == "x")
    }

    @Test func entitiesDecodeIntoOneRun() throws {
        #expect(parsePangoMarkup("&amp;lt;")?.text == "&lt;")
        #expect(parsePangoMarkup("&#65;&lt;")?.text == "A<")
        let all = try runs("<b>a &amp; b</b>")
        #expect(all.map(\.0) == ["a & b"])
    }

    @Test(arguments: ["<b>x", "<foo>x</foo>", "a & b", "<b>x</i>", "<b><i>x</b></i>"])
    func invalidMarkupIsNil(markup: String) {
        #expect(parsePangoMarkup(markup) == nil)
    }
}
