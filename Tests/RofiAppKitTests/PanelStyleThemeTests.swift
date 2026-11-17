import AppKit
import RofiCore
import Testing

@testable import RofiAppKit

/// The Rasi-to-`PanelStyle` mapping of ADR 0001 §3, tested without a window.
@MainActor @Suite struct PanelStyleThemeTests {
    private let visible = NSSize(width: 1000, height: 800)

    @Test func emptyThemeKeepsTodaysNativeDefaults() throws {
        let (style, warnings) = try theme("")
        #expect(warnings.isEmpty)
        #expect(style.backgroundColor == nil)
        #expect(style.textColor == nil)
        #expect(style.borderColor == nil)
        #expect(style.font == nil)
        #expect(style.fixedRows == nil)
        #expect(style.location == nil)
        for kind in [PanelRowKind.normal, .active, .urgent] {
            for variant in [PanelRowVariant.plain, .alternate, .selected] {
                #expect(style.rowBackgroundColor(kind: kind, variant: variant) == nil)
                #expect(style.rowTextColor(kind: kind, variant: variant) == nil)
            }
        }
        let metrics = PanelMetrics(style: style, visibleSize: visible)
        #expect(metrics.width == 640)
        #expect(edges(metrics.padding) == [12, 12, 12, 12])
        #expect(edges(metrics.border) == [0, 0, 0, 0])
        #expect(edges(metrics.contentInsets) == [12, 12, 12, 12])
    }

    @Test func windowColorsOverrideGlobalColorsAsCalibratedSRGB() throws {
        let (style, _) = try theme(
            """
            * { background-color: red; text-color: blue; border-color: lime; }
            window { background-color: #00ff0080; }
            mainbox { border-color: #102030; }
            """)
        #expect(rgba(style.backgroundColor) == [0, 1, 0, 128.0 / 255])
        #expect(rgba(style.textColor) == [0, 0, 1, 1])
        #expect(rgba(style.borderColor) == [16.0 / 255, 32.0 / 255, 48.0 / 255, 1])
        #expect(style.backgroundColor?.colorSpace == .sRGB)
    }

    @Test func rowPaletteFallsBackToTheNearestSlot() throws {
        let (style, _) = try theme(
            """
            * { text-color: white; }
            element normal.normal { background-color: #000001; text-color: #000002; }
            element alternate.normal { background-color: #000003; }
            element selected.normal { background-color: #000004; text-color: #000005; }
            element normal.active { text-color: #000006; }
            element selected.urgent { background-color: #000007; }
            """)
        // Exact slots.
        #expect(hex(style.rowBackgroundColor(kind: .normal, variant: .plain)) == 1)
        #expect(hex(style.rowTextColor(kind: .normal, variant: .plain)) == 2)
        #expect(hex(style.rowBackgroundColor(kind: .normal, variant: .alternate)) == 3)
        #expect(hex(style.rowTextColor(kind: .active, variant: .plain)) == 6)
        // Alternate falls back to its plain row, then to normal rows.
        #expect(hex(style.rowTextColor(kind: .normal, variant: .alternate)) == 2)
        #expect(hex(style.rowTextColor(kind: .active, variant: .alternate)) == 6)
        #expect(hex(style.rowBackgroundColor(kind: .active, variant: .alternate)) == 3)
        // Selected keeps to selected slots so the cursor stays visible.
        #expect(hex(style.rowBackgroundColor(kind: .active, variant: .selected)) == 4)
        #expect(hex(style.rowTextColor(kind: .active, variant: .selected)) == 5)
        #expect(hex(style.rowBackgroundColor(kind: .urgent, variant: .selected)) == 7)
        #expect(hex(style.rowTextColor(kind: .urgent, variant: .selected)) == 5)
        // Urgent rows without urgent slots use normal rows.
        #expect(hex(style.rowBackgroundColor(kind: .urgent, variant: .plain)) == 1)
    }

    @Test func rowTextFallsBackToTheSharedTextColorOnlyForNormalRows() throws {
        let (style, _) = try theme("window { text-color: #000009; }")
        #expect(hex(style.rowTextColor(kind: .normal, variant: .plain)) == 9)
        #expect(hex(style.rowTextColor(kind: .normal, variant: .alternate)) == 9)
        // Active and urgent keep their native colors; the native selection
        // keeps its highlighted text.
        #expect(style.rowTextColor(kind: .active, variant: .plain) == nil)
        #expect(style.rowTextColor(kind: .urgent, variant: .plain) == nil)
        #expect(style.rowTextColor(kind: .normal, variant: .selected) == nil)

        let (themedSelection, _) = try theme(
            "window { text-color: #000009; } element selected { background-color: black; }")
        #expect(hex(themedSelection.rowTextColor(kind: .normal, variant: .selected)) == 9)
    }

    @Test func fontDescriptionsMapToNativeFonts() throws {
        let (menlo, menloWarnings) = try theme(#"window { font: "Menlo Bold 15"; }"#)
        #expect(menloWarnings.isEmpty)
        #expect(menlo.font?.familyName == "Menlo")
        #expect(menlo.font?.pointSize == 15)
        #expect(menlo.font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

        let (mono, _) = try theme(#"* { font: "monospace 11"; }"#)
        #expect(mono.font?.pointSize == 11)
        #expect(mono.font?.isFixedPitch == true)

        let (sizeless, _) = try theme(#"window { font: "Menlo"; }"#)
        #expect(sizeless.font?.pointSize == NSFont.systemFontSize)
    }

    @Test func unavailableFontFamilyWarnsAndKeepsTheBuiltInFont() throws {
        let (style, warnings) = try theme(
            """
            window {
                font: "No Such Family Anywhere 12";
            }
            """)
        #expect(style.font == nil)
        #expect(warnings.map(\.code) == [.unsupportedValue])
        #expect(warnings.first?.source == "theme.rasi")
        #expect(warnings.first?.line == 2)
    }

    @Test func dimensionsConvertToPointsAndClampToTheVisibleFrame() throws {
        let (percent, _) = try theme("window { width: 50%; padding: 10px 5%; border: 2px 0 4px; }")
        let metrics = PanelMetrics(style: percent, visibleSize: visible)
        #expect(metrics.width == 500)
        // Horizontal percentages use the visible width, vertical the height.
        #expect(edges(metrics.padding) == [10, 50, 10, 50])
        #expect(edges(metrics.border) == [2, 0, 4, 0])
        // The border sits outside the padding.
        #expect(edges(metrics.contentInsets) == [12, 50, 14, 50])

        let (wide, _) = try theme("window { width: 4000px; padding: 10%; }")
        let wideMetrics = PanelMetrics(style: wide, visibleSize: visible)
        #expect(wideMetrics.width == 1000)
        #expect(edges(wideMetrics.padding) == [80, 100, 80, 100])

        let (relative, _) = try theme(#"window { font: "Menlo 20"; width: 10em; padding: 2ch; }"#)
        let font = try #require(relative.font)
        let relativeMetrics = PanelMetrics(style: relative, visibleSize: visible)
        #expect(relativeMetrics.width == 10 * lineHeight(of: font))
        let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
        #expect(relativeMetrics.padding.left == 2 * zero)
    }

    @Test func paddingAndBorderTakeTheFirstDefinedOfWindowMainboxGlobal() throws {
        let (style, _) = try theme(
            """
            window { padding: 3px; }
            mainbox { padding: 7px; border: 5px; }
            * { padding: 9px; border: 6px; width: 300px; }
            """)
        let metrics = PanelMetrics(style: style, visibleSize: visible)
        #expect(edges(metrics.padding) == [3, 3, 3, 3])
        #expect(edges(metrics.border) == [5, 5, 5, 5])
        #expect(metrics.width == 300)

        let (window, _) = try theme("* { width: 300px; } window { width: 400px; }")
        #expect(PanelMetrics(style: window, visibleSize: visible).width == 400)
    }

    @Test func linesAndLocationTakeTheLatestOfTheirSelectors() throws {
        let (style, _) = try theme(
            """
            listview { lines: 4; }
            configuration { lines: 6; location: 1; }
            window { location: south east; }
            """)
        #expect(style.fixedRows == 6)
        #expect(style.location == .southEast)

        let (zero, _) = try theme("listview { lines: 0; }")
        #expect(zero.fixedRows == 0)
    }

    @Test func widgetColorsWithoutANativeSlotWarnAndKeepTheSharedDefault() throws {
        let (style, warnings) = try theme(
            """
            prompt { text-color: red; }
            prompt { text-color: blue; }
            entry { background-color: red; }
            """)
        #expect(style.textColor == nil)
        #expect(style.backgroundColor == nil)
        #expect(warnings.map(\.code) == [.unsupportedProperty, .unsupportedProperty])
        #expect(warnings.map(\.line) == [1, 3])
    }

    @Test func dmenuDirectFlagsWinOverTheTheme() throws {
        var base = PanelStyle()
        base.fixedRows = 7
        base.location = .north

        #expect(try dmenuStyle(["-l", "3"], base: base).fixedRows == 3)
        #expect(try dmenuStyle([], base: base).fixedRows == 7)
        #expect(try dmenuStyle([], base: base).location == .north)
        // Without a theme, dmenu keeps today's sizing and `-b` placement.
        #expect(try dmenuStyle(["-mesg", "m"], base: PanelStyle()).fixedRows == 15)
        #expect(try dmenuStyle([], base: PanelStyle()).fixedRows == nil)
        #expect(try dmenuStyle(["-b"], base: PanelStyle()).location == .south)
    }

    @Test func modePanelKeepsTheThemeAndAddsItsChrome() {
        var base = PanelStyle()
        base.fixedRows = 4
        base.textColor = .red
        let model = ModePanelModel(switcher: ModeSwitcher(modes: [EmptyMode()]))
        let style = model.style(base: base, sidebar: true)
        #expect(style.fixedRows == 4)
        #expect(style.textColor == .red)
        #expect(style.accessibilityName == "Rofi")
        #expect(style.switcherLabels == ["e"])
    }

    // MARK: - Helpers

    private func theme(_ text: String) throws -> (PanelStyle, [RasiDiagnostic]) {
        PanelStyle.theme(try RasiResolver().resolve(RasiSource(identity: "theme.rasi", text: text)))
    }

    private func dmenuStyle(_ argv: [String], base: PanelStyle) throws -> PanelStyle {
        let pipeline = try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu", "-sync"] + argv))
        guard case .session(let session) = pipeline.start(rows: [Row(parsing: "a"), Row(parsing: "b")]) else {
            Issue.record("dmenu did not open a session")
            return base
        }
        return DmenuPanelModel(session: session).style(base: base)
    }

    private func rgba(_ color: NSColor?) -> [Double]? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map(Double.init)
    }

    /// A `#0000xx` color as its blue byte.
    private func hex(_ color: NSColor?) -> Int? {
        rgba(color).map { Int(($0[2] * 255).rounded()) }
    }

    private func edges(_ insets: NSEdgeInsets) -> [CGFloat] {
        [insets.top, insets.right, insets.bottom, insets.left]
    }
}

private final class EmptyMode: Mode {
    let name = "e"
    let rows: [Row] = []
    func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult { .exit }
}
