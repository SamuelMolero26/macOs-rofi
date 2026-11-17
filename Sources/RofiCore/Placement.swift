import CoreGraphics
import Foundation

/// `-monitor` as ADR 0002 §1 maps it (doc/rofi.1.markdown:551-569,
/// source/xcb/display.c:922-1072).
public enum MonitorSelector: Equatable, Sendable {
    /// `-5`, the default: the screen under the mouse.
    case mouse
    /// `-3`: the panel's top-left corner at the mouse (source/helper.c:769-772).
    case atMouse
    /// `-2`: the frontmost window's frame.
    case focusedWindow
    /// `-4`, and `-1` because Spaces have no public API: the screen holding
    /// the frontmost window's top-left corner.
    case focusedMonitor
    case primary
    case index(Int)
    case name(String)

    /// Unknown negative ids and `wid:` act as `-5`, as upstream falls back
    /// for an id it cannot resolve.
    public init(_ raw: String) {
        switch raw {
        case "primary": self = .primary
        case "-1", "-4": self = .focusedMonitor
        case "-2": self = .focusedWindow
        case "-3": self = .atMouse
        default:
            if let index = Int(raw) {
                self = index >= 0 ? .index(index) : .mouse
            } else {
                self = raw.hasPrefix("wid:") ? .mouse : .name(raw)
            }
        }
    }
}

/// One display: AppKit's `localizedName`, `frame` and `visibleFrame`, in
/// AppKit's bottom-left coordinates.
public struct Screen: Equatable, Sendable {
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(name: String, frame: CGRect, visibleFrame: CGRect) {
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// The rectangle the panel is placed in, plus `-3`'s forced location.
public struct WorkArea: Equatable, Sendable {
    public let frame: CGRect
    public let location: RasiLocation?
}

/// The panel options outside the theme: `-monitor`, `-xoffset`, `-yoffset`
/// and `-click-to-exit` (source/xrmoptions.c, config/config.c:97-99, 149, 156).
/// ponytail: command line only, like `-no-cycle`; config.rasi does not set them.
public struct PanelPlacement: Equatable, Sendable {
    public var monitor = MonitorSelector.mouse
    public var xOffset = 0
    public var yOffset = 0
    public var clickToExit = true

    public init() {}

    /// Offsets parse like xrmoptions' `strtol`, so garbage is 0. `-m` comes
    /// after `-monitor` in the option table, so it wins (source/xrmoptions.c:466-484).
    public init(arguments args: Arguments) {
        if let monitor = args.string("-m") ?? args.string("-monitor") { self.monitor = MonitorSelector(monitor) }
        xOffset = args.string("-xoffset").map { strtol($0, nil, 10) } ?? 0
        yOffset = args.string("-yoffset").map { strtol($0, nil, 10) } ?? 0
        clickToExit = args.bool("click-to-exit", default: true)
    }

    /// The area `monitor` selects, or nil without screens. `frontWindow` is
    /// the frontmost window's `kCGWindowBounds` (top-left origin); it is read
    /// only when the answer depends on it (ADR 0002 §3). An unknown name or
    /// index warns and uses the primary screen.
    public func workArea(
        screens: [Screen], mouse: CGPoint, frontWindow: () -> CGRect?
    ) -> (area: WorkArea, warning: String?)? {
        guard let primary = screens.first else { return nil }
        func area(_ screen: Screen) -> WorkArea { WorkArea(frame: screen.visibleFrame, location: nil) }
        func screen(containing point: CGPoint) -> Screen? {
            screens.first { $0.frame.minX...$0.frame.maxX ~= point.x && $0.frame.minY...$0.frame.maxY ~= point.y }
        }
        let mouseScreen = screens.count == 1 ? primary : screen(containing: mouse) ?? primary
        // CGWindowList's top-left origin, flipped against the primary screen.
        func window() -> CGRect? {
            frontWindow().map {
                CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
            }
        }
        switch monitor {
        case .mouse:
            return (area(mouseScreen), nil)
        case .atMouse:
            let size = mouseScreen.visibleFrame.size
            let frame = CGRect(x: mouse.x, y: mouse.y - size.height, width: size.width, height: size.height)
            return (WorkArea(frame: frame, location: .northWest), nil)
        case .focusedWindow:
            guard let window = window() else { return (area(mouseScreen), nil) }
            return (WorkArea(frame: window, location: nil), nil)
        case .focusedMonitor:
            guard screens.count > 1 else { return (area(primary), nil) }
            guard let window = window() else { return (area(mouseScreen), nil) }
            return (area(screen(containing: CGPoint(x: window.minX, y: window.maxY)) ?? mouseScreen), nil)
        case .primary:
            return (area(primary), nil)
        case .index(let index):
            guard screens.indices.contains(index) else {
                return (area(primary), "monitor \(index) was not found, using the primary screen")
            }
            return (area(screens[index]), nil)
        case .name(let name):
            guard let match = screens.first(where: { $0.name == name }) else {
                return (area(primary), "monitor '\(name)' was not found, using the primary screen")
            }
            return (area(match), nil)
        }
    }
}

/// The panel origin for `location` in `area`, then the offsets with positive Y
/// going down (source/xcb/view.c:279-364). No location is upstream's center.
public func panelOrigin(location: RasiLocation?, size: CGSize, area: CGRect, xOffset: Int, yOffset: Int) -> CGPoint {
    let left = area.minX
    let middle = area.midX - size.width / 2
    let right = area.maxX - size.width
    let top = area.maxY - size.height
    let center = area.midY - size.height / 2
    let bottom = area.minY
    let origin: CGPoint
    switch location ?? .center {
    case .center: origin = CGPoint(x: middle, y: center)
    case .north: origin = CGPoint(x: middle, y: top)
    case .northEast: origin = CGPoint(x: right, y: top)
    case .east: origin = CGPoint(x: right, y: center)
    case .southEast: origin = CGPoint(x: right, y: bottom)
    case .south: origin = CGPoint(x: middle, y: bottom)
    case .southWest: origin = CGPoint(x: left, y: bottom)
    case .west: origin = CGPoint(x: left, y: center)
    case .northWest: origin = CGPoint(x: left, y: top)
    }
    return CGPoint(x: origin.x + CGFloat(xOffset), y: origin.y - CGFloat(yOffset))
}
