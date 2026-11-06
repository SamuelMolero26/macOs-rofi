import AppKit
import RofiCore

/// How one panel looks, read once when it is built. The theme fields come
/// from the resolved Rasi subset (ADR 0001 §3); nil keeps the native default.
public struct PanelStyle {
    /// An `NSSecureTextField` instead of an `NSSearchField`.
    var password = false
    /// Rows the panel is sized around, or nil for the default panel.
    var fixedRows: Int?
    var markupRows = false
    var ellipsizeMode = EllipsizeMode.end
    /// Leads every accessibility label, such as "Dmenu prompt".
    var accessibilityName = "Dmenu"
    /// One switcher button per mode, or nil for no switcher row
    /// (source/view.c:1790-1810).
    var switcherLabels: [String]?
    /// An icon column before the text (`-show-icons`, source/xrmoptions.c:145).
    var showIcons = false

    /// Placement in the visible frame, or nil for AppKit's centering.
    var location: RasiLocation?
    var backgroundColor: NSColor?
    /// Prompt, entry, message and normal row foreground.
    var textColor: NSColor?
    var borderColor: NSColor?
    var font: NSFont?
    var width: RasiDimension?
    var padding: RasiInsets?
    var border: RasiInsets?
    var rowBackgrounds: [PanelRowSlot: NSColor] = [:]
    var rowTexts: [PanelRowSlot: NSColor] = [:]

    public init() {}
}

extension PanelStyle {
    /// Maps a resolved theme onto the panel. The warnings cover values that
    /// resolved but have no native effect; the resolver reports the rest.
    public static func theme(_ resolution: RasiResolution) -> (style: PanelStyle, warnings: [RasiDiagnostic]) {
        var mapping = ThemeMapping(resolution: resolution)
        return mapping.run()
    }

    /// The row fill, or nil for none (the native accent when selected).
    func rowBackgroundColor(kind: PanelRowKind, variant: PanelRowVariant) -> NSColor? {
        fallbackSlots(kind: kind, variant: variant).lazy.compactMap { rowBackgrounds[$0] }.first
    }

    /// The row text color, or nil for the native one: label, active blue,
    /// urgent red, or highlighted text on the native selection.
    func rowTextColor(kind: PanelRowKind, variant: PanelRowVariant) -> NSColor? {
        if let color = fallbackSlots(kind: kind, variant: variant).lazy.compactMap({ rowTexts[$0] }).first {
            return color
        }
        // The native selection keeps its readable highlighted text.
        guard kind == .normal, variant != .selected || rowBackgroundColor(kind: kind, variant: .selected) != nil
        else { return nil }
        return textColor
    }

    /// The ADR's "nearest active/urgent or normal slot". Selected rows keep to
    /// selected slots, as upstream drops trailing states from `selected.active`.
    private func fallbackSlots(kind: PanelRowKind, variant: PanelRowVariant) -> [PanelRowSlot] {
        switch variant {
        case .selected:
            return [.init(kind: kind, variant: .selected), .init(kind: .normal, variant: .selected)]
        case .alternate:
            return [
                .init(kind: kind, variant: .alternate), .init(kind: kind, variant: .plain),
                .init(kind: .normal, variant: .alternate), .init(kind: .normal, variant: .plain),
            ]
        case .plain:
            return [.init(kind: kind, variant: .plain), .init(kind: .normal, variant: .plain)]
        }
    }
}

enum PanelRowKind: Hashable {
    case normal, active, urgent
}

enum PanelRowVariant: Hashable {
    case plain, alternate, selected
}

struct PanelRowSlot: Hashable {
    let kind: PanelRowKind
    let variant: PanelRowVariant
}

/// The theme's dimensions in AppKit points (ADR 0001 §3): `px` is one point,
/// `em` the font's line height, `ch` the width of "0", `%` the visible frame.
struct PanelMetrics {
    static let defaultWidth: CGFloat = 640
    static let defaultPadding: CGFloat = 12

    let font: NSFont
    let width: CGFloat
    let padding: NSEdgeInsets
    let border: NSEdgeInsets

    init(style: PanelStyle, visibleSize: NSSize) {
        let font = style.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        self.font = font
        let width = style.width.map { Self.points($0, percentOf: visibleSize.width, font: font) } ?? Self.defaultWidth
        // Clamped to the visible frame; without a screen nothing clamps.
        self.width = visibleSize.width > 0 ? min(width, visibleSize.width) : width
        let padding = Self.defaultPadding
        self.padding =
            style.padding.map { Self.edges($0, in: visibleSize, font: font) }
            ?? NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        border = style.border.map { Self.edges($0, in: visibleSize, font: font) } ?? NSEdgeInsets()
    }

    /// Content sits inside the border, then the padding.
    var contentInsets: NSEdgeInsets {
        NSEdgeInsets(
            top: border.top + padding.top, left: border.left + padding.left,
            bottom: border.bottom + padding.bottom, right: border.right + padding.right)
    }

    static func points(_ dimension: RasiDimension, percentOf base: CGFloat, font: NSFont) -> CGFloat {
        let value = CGFloat(dimension.value)
        switch dimension.unit {
        case .pixels: return value
        case .em: return value * lineHeight(of: font)
        case .ch: return value * ("0" as NSString).size(withAttributes: [.font: font]).width
        case .percent: return value / 100 * base
        }
    }

    private static func edges(_ insets: RasiInsets, in size: NSSize, font: NSFont) -> NSEdgeInsets {
        NSEdgeInsets(
            top: points(insets.top, percentOf: size.height, font: font),
            left: points(insets.left, percentOf: size.width, font: font),
            bottom: points(insets.bottom, percentOf: size.height, font: font),
            right: points(insets.right, percentOf: size.width, font: font))
    }
}

/// One line of `font`, which is what `em` measures.
func lineHeight(of font: NSFont) -> CGFloat {
    (font.ascender - font.descender + font.leading).rounded(.up)
}

/// The panel origin for `location` in `visibleFrame`, or nil to let AppKit
/// center it (the default, and Rasi's `center`).
func panelOrigin(location: RasiLocation?, size: NSSize, visibleFrame: NSRect) -> NSPoint? {
    guard let location, location != .center else { return nil }
    let left = visibleFrame.minX
    let middle = visibleFrame.midX - size.width / 2
    let right = visibleFrame.maxX - size.width
    let top = visibleFrame.maxY - size.height
    let center = visibleFrame.midY - size.height / 2
    let bottom = visibleFrame.minY
    switch location {
    case .center: return nil
    case .north: return NSPoint(x: middle, y: top)
    case .northEast: return NSPoint(x: right, y: top)
    case .east: return NSPoint(x: right, y: center)
    case .southEast: return NSPoint(x: right, y: bottom)
    case .south: return NSPoint(x: middle, y: bottom)
    case .southWest: return NSPoint(x: left, y: bottom)
    case .west: return NSPoint(x: left, y: center)
    case .northWest: return NSPoint(x: left, y: top)
    }
}

/// The selector/property table of ADR 0001 §3.
private struct ThemeMapping {
    let resolution: RasiResolution
    var warnings: [RasiDiagnostic] = []

    init(resolution: RasiResolution) {
        self.resolution = resolution
    }

    mutating func run() -> (style: PanelStyle, warnings: [RasiDiagnostic]) {
        var style = PanelStyle()
        style.backgroundColor = color(.backgroundColor, [.window, .global])
        style.textColor = color(.textColor, [.window, .global])
        style.borderColor = color(.borderColor, [.window, .mainbox, .global])
        style.font = font()
        if case .dimension(let width) = first(.width, [.window, .global])?.value { style.width = width }
        if case .insets(let padding) = first(.padding, [.window, .mainbox, .global])?.value {
            style.padding = padding
        }
        if case .border(let border) = first(.border, [.window, .mainbox, .global])?.value {
            style.border = border.widths
        }
        if case .integer(let lines) = latest(.lines, [.listview, .configuration])?.value { style.fixedRows = lines }
        if case .location(let location) = latest(.location, [.window, .configuration])?.value {
            style.location = location
        }
        for declaration in resolution.declarations where declaration.selector.name == "element" {
            guard case .color(let color) = declaration.value else { continue }
            let slot = Self.slot(for: declaration.selector)
            switch declaration.property {
            case .backgroundColor: style.rowBackgrounds[slot] = nsColor(color)
            case .textColor: style.rowTexts[slot] = nsColor(color)
            default: break
            }
        }
        warnAboutWidgetColors()
        return (style, warnings)
    }

    /// The last declaration on the first selector that has one: a supported
    /// element selector beats `*` whatever their order.
    private func first(_ property: RasiProperty, _ selectors: [RasiSelector]) -> RasiResolvedDeclaration? {
        selectors.lazy.compactMap { selector in
            resolution.declarations.last { $0.selector == selector && $0.property == property }
        }.first
    }

    /// The last declaration on any of `selectors`, by source order.
    private func latest(_ property: RasiProperty, _ selectors: [RasiSelector]) -> RasiResolvedDeclaration? {
        resolution.declarations.last { selectors.contains($0.selector) && $0.property == property }
    }

    private func color(_ property: RasiProperty, _ selectors: [RasiSelector]) -> NSColor? {
        guard case .color(let color) = first(property, selectors)?.value else { return nil }
        return nsColor(color)
    }

    private mutating func font() -> NSFont? {
        guard let declaration = first(.font, [.window, .global]), case .font(let description) = declaration.value
        else { return nil }
        if let font = nativeFont(description) { return font }
        warn(declaration, .unsupportedValue, "font '\(description)' is not available; the built-in font is kept")
        return nil
    }

    /// Entry, prompt, message, button and mode-switcher colors parse, but the
    /// panel has no slot for them yet; warn once per selector and property.
    private mutating func warnAboutWidgetColors() {
        var seen: Set<String> = []
        for declaration in resolution.declarations {
            guard ["entry", "prompt", "message", "button", "mode-switcher"].contains(declaration.selector.name)
            else { continue }
            let label = ([declaration.selector.name] + declaration.selector.states).joined(separator: " ")
            let key = "\(label) \(declaration.property.rawValue)"
            guard seen.insert(key).inserted else { continue }
            warn(
                declaration, .unsupportedProperty,
                "'\(key)' has no native panel slot; the shared default is used")
        }
    }

    private mutating func warn(_ declaration: RasiResolvedDeclaration, _ code: RasiDiagnosticCode, _ message: String) {
        warnings.append(
            RasiDiagnostic(
                severity: .warning, code: code, message: message,
                source: declaration.source, line: declaration.line, column: declaration.column))
    }

    private static func slot(for selector: RasiSelector) -> PanelRowSlot {
        let states = Set(selector.states)
        let kind: PanelRowKind = states.contains("active") ? .active : states.contains("urgent") ? .urgent : .normal
        let variant: PanelRowVariant =
            states.contains("selected") ? .selected : states.contains("alternate") ? .alternate : .plain
        return PanelRowSlot(kind: kind, variant: variant)
    }
}

/// Calibrated sRGB, so screenshots and `-dump-config` agree in every appearance.
private func nsColor(_ color: RasiColor) -> NSColor {
    NSColor(
        srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
        alpha: CGFloat(color.alpha))
}

/// A Pango-like "family [traits] [size]" description. AppKit matching is
/// authoritative; nil when the family is unavailable.
private func nativeFont(_ description: String) -> NSFont? {
    var words = description.split(whereSeparator: \.isWhitespace).map(String.init)
    var size = NSFont.systemFontSize
    if let last = words.last, let points = Double(last), points > 0 {
        size = CGFloat(points)
        words.removeLast()
    }
    let traitWords: [String: NSFontTraitMask] = [
        "bold": .boldFontMask, "italic": .italicFontMask, "oblique": .italicFontMask,
        "regular": [], "normal": [], "book": [], "roman": [],
    ]
    var traits: NSFontTraitMask = []
    while let last = words.last?.lowercased(), let trait = traitWords[last] {
        traits.formUnion(trait)
        words.removeLast()
    }
    var family = words.joined(separator: " ")
    if family.hasSuffix(",") { family.removeLast() }

    let manager = NSFontManager.shared
    let base: NSFont?
    switch family.lowercased() {
    case "", "sans", "sans-serif", "system-ui":
        base = .systemFont(ofSize: size, weight: traits.contains(.boldFontMask) ? .bold : .regular)
    case "mono", "monospace":
        base = .monospacedSystemFont(ofSize: size, weight: traits.contains(.boldFontMask) ? .bold : .regular)
    case "serif":
        return manager.font(withFamily: "Times", traits: traits, weight: 5, size: size)
    default:
        return manager.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
    }
    guard let base, traits.contains(.italicFontMask) else { return base }
    return manager.convert(base, toHaveTrait: .italicFontMask)
}
