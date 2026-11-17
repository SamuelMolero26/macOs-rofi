import AppKit
import Testing

@testable import RofiAppKit

@MainActor @Suite struct ErrorDialogTests {
    @Test func plainMessagePreservesLiteralTextAndBaseStyle() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let message = prepareErrorDialogMessage("<b>plain</b>", markup: false, font: font, color: .systemBlue)

        #expect(message.string == "<b>plain</b>")
        let attributes = message.attributes(at: 0, effectiveRange: nil)
        #expect((attributes[.font] as? NSFont)?.pointSize == 13)
        #expect((attributes[.foregroundColor] as? NSColor)?.isEqual(NSColor.systemBlue) == true)
    }

    @Test func markupMessageRendersSupportedAttributesAndInvalidMarkupFallsBack() throws {
        let message = prepareErrorDialogMessage(
            ##"<span foreground="#ff0000"><b>bold</b></span>"##,
            markup: true,
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )

        #expect(message.string == "bold")
        let attributes = message.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let color = try #require((attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(color.redComponent == 1)
        #expect(color.greenComponent == 0)
        #expect(color.blueComponent == 0)

        let invalid = prepareErrorDialogMessage(
            "<b>broken",
            markup: true,
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        #expect(invalid.string == "<b>broken")
    }
}
