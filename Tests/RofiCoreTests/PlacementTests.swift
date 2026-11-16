import CoreGraphics
import Testing

@testable import RofiCore

/// ADR 0002: `-monitor` resolution and panel origin, without real displays.
@Suite struct PlacementTests {
    /// The primary (menu bar) screen and a taller one left of and below it.
    private let primary = Screen(
        name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950))
    private let left = Screen(
        name: "Left", frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1055))
    private let onLeft = CGPoint(x: -100, y: 300)
    /// A window at AppKit (-1800, 200, 800, 600), as CGWindowList reports it
    /// from the primary screen's top-left corner.
    private let windowOnLeft = CGRect(x: -1800, y: 982 - 800, width: 800, height: 600)

    private func resolve(
        _ raw: String, screens: [Screen]? = nil, mouse: CGPoint? = nil, window: CGRect? = nil
    ) -> (area: WorkArea, warning: String?, windowReads: Int) {
        var placement = PanelPlacement()
        placement.monitor = MonitorSelector(raw)
        var reads = 0
        let result = placement.workArea(screens: screens ?? [primary, left], mouse: mouse ?? onLeft) {
            reads += 1
            return window
        }!
        return (result.area, result.warning, reads)
    }

    @Test func selectorsMapToScreens() {
        #expect(resolve("-5").area.frame == left.visibleFrame)
        #expect(resolve("-5", mouse: CGPoint(x: 5000, y: 0)).area.frame == primary.visibleFrame)
        #expect(resolve("primary").area.frame == primary.visibleFrame)
        #expect(resolve("1").area.frame == left.visibleFrame)
        #expect(resolve("Left").area.frame == left.visibleFrame)
        // -4 and -1 take the window's screen, not the mouse's.
        for raw in ["-4", "-1"] {
            #expect(resolve(raw, mouse: .zero, window: windowOnLeft).area.frame == left.visibleFrame)
        }
        #expect(resolve("-2", window: windowOnLeft).area.frame == CGRect(x: -1800, y: 200, width: 800, height: 600))
        // wid: and unknown negative ids act as -5.
        #expect(resolve("wid:0x1").area.frame == left.visibleFrame)
        #expect(resolve("-9").area.frame == left.visibleFrame)
    }

    @Test func missingWindowFallsBackToTheMouseScreen() {
        for raw in ["-1", "-2", "-4"] {
            #expect(resolve(raw, window: nil).area.frame == left.visibleFrame)
        }
    }

    @Test func unknownMonitorsWarnAndUsePrimary() {
        let index = resolve("7")
        #expect(index.area.frame == primary.visibleFrame)
        #expect(index.warning == "monitor 7 was not found, using the primary screen")
        let name = resolve("HDMI-1")
        #expect(name.area.frame == primary.visibleFrame)
        #expect(name.warning == "monitor 'HDMI-1' was not found, using the primary screen")
        #expect(resolve("Left").warning == nil)
    }

    // ADR 0002 §3: one screen answers -1 and -4 without the window list.
    @Test func windowListIsReadOnlyWhenTheAnswerNeedsIt() {
        #expect(resolve("-4", screens: [primary], window: windowOnLeft).windowReads == 0)
        #expect(resolve("-1", screens: [primary], window: windowOnLeft).windowReads == 0)
        #expect(resolve("-5", window: windowOnLeft).windowReads == 0)
        #expect(resolve("-2", screens: [primary], window: windowOnLeft).windowReads == 1)
        #expect(resolve("-4", window: windowOnLeft).windowReads == 1)
    }

    // -3 puts the panel's top-left corner at the mouse (source/helper.c:769-772).
    @Test func atMouseAnchorsTheTopLeftCornerAtThePointer() {
        let area = resolve("-3").area
        #expect(area.location == .northWest)
        let origin = panelOrigin(
            location: area.location, size: CGSize(width: 640, height: 400), area: area.frame, xOffset: 0, yOffset: 0)
        #expect(origin == CGPoint(x: onLeft.x, y: onLeft.y - 400))
    }

    @Test func locationsThenOffsetsWithPositiveYGoingDown() {
        let size = CGSize(width: 100, height: 50)
        let area = CGRect(x: 10, y: 20, width: 1000, height: 800)
        let expected: [(RasiLocation?, CGPoint)] = [
            (nil, CGPoint(x: 460, y: 395)), (.center, CGPoint(x: 460, y: 395)),
            (.north, CGPoint(x: 460, y: 770)), (.northEast, CGPoint(x: 910, y: 770)),
            (.east, CGPoint(x: 910, y: 395)), (.southEast, CGPoint(x: 910, y: 20)),
            (.south, CGPoint(x: 460, y: 20)), (.southWest, CGPoint(x: 10, y: 20)),
            (.west, CGPoint(x: 10, y: 395)), (.northWest, CGPoint(x: 10, y: 770)),
        ]
        for (location, origin) in expected {
            #expect(panelOrigin(location: location, size: size, area: area, xOffset: 0, yOffset: 0) == origin)
        }
        #expect(
            panelOrigin(location: .northWest, size: size, area: area, xOffset: 30, yOffset: 40)
                == CGPoint(x: 40, y: 730))
    }

    @Test func optionsParseLikeXrmoptions() {
        let placement = PanelPlacement(
            arguments: Arguments([
                "rofi", "-monitor", "primary", "-m", "-4", "-xoffset", "-12", "-yoffset", "x", "-no-click-to-exit",
            ]))
        #expect(placement.monitor == .focusedMonitor)
        #expect(placement.xOffset == -12)
        #expect(placement.yOffset == 0)
        #expect(!placement.clickToExit)
        #expect(PanelPlacement(arguments: Arguments(["rofi"])) == PanelPlacement())
    }
}
