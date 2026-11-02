import Foundation

/// A markup color, 8 bits per channel.
public struct MarkupColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// `<sub>` and `<sup>`: a lowered or raised, smaller run.
public enum MarkupScript: Equatable, Sendable {
    case sub
    case sup
}

/// The combined style of every tag around a run. The defaults mean "as the
/// surrounding text", so a run with default attributes is never reported.
public struct MarkupAttributes: Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    /// `<tt>`; cleared again by an inner `font_family`.
    public var monospace = false
    public var fontFamily: String?
    public var foreground: MarkupColor?
    public var background: MarkupColor?
    /// Size relative to `pointSize`, or to the base font when that is nil:
    /// each `<big>`/`larger` multiplies by 1.2, each `<small>`/`smaller`,
    /// `<sub>` or `<sup>` divides by it.
    public var scale = 1.0
    /// An absolute `size`, in points. Setting it resets `scale` to 1.
    public var pointSize: Double?
    public var script: MarkupScript?

    public init() {}
}

/// A styled stretch of `MarkupText.text`.
public struct MarkupRun: Equatable, Sendable {
    public let range: Range<String.Index>
    public let attributes: MarkupAttributes
}

/// Markup split into its plain text and the styled runs over it.
public struct MarkupText: Equatable, Sendable {
    public let text: String
    public let runs: [MarkupRun]
}

/// `pango_parse_markup`: the text and attributes of `markup`, or nil when it
/// is not well-formed or uses a tag Pango does not know. Adjacent text with
/// equal attributes forms one run.
// ponytail: Pango also rejects an unknown span attribute or an unparsable
// value; both are ignored here, so `-format p` strips them cleanly. Colors
// are hex only (#rgb, #rgba, #rrggbb, #rrggbbaa), not X11 names; `size`
// takes keywords, 1024ths of a point and "Npt", not "N%".
public func parsePangoMarkup(_ markup: String) -> MarkupText? {
    let parser = XMLParser(data: Data(("<markup>" + markup + "</markup>").utf8))
    let builder = MarkupBuilder()
    parser.delegate = builder
    return parser.parse() && builder.valid ? builder.result : nil
}

/// The `-format p` text: the markup's text, or nil when it is invalid.
func stripPangoMarkup(_ markup: String) -> String? {
    parsePangoMarkup(markup)?.text
}

private final class MarkupBuilder: NSObject, XMLParserDelegate {
    private var text = ""
    private(set) var valid = true
    /// The attributes in force inside each open tag.
    private var stack: [MarkupAttributes] = []
    /// Runs as UTF-8 offsets into `text`, which is still growing.
    private var runs: [(start: Int, end: Int, attributes: MarkupAttributes)] = []

    var result: MarkupText {
        let utf8 = text.utf8
        let index = { utf8.index(utf8.startIndex, offsetBy: $0) }
        return MarkupText(text: text, runs: runs.map {
            MarkupRun(range: index($0.start)..<index($0.end), attributes: $0.attributes)
        })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes = stack.last ?? MarkupAttributes()
        guard attributes.apply(tag: elementName, spanAttributes: attributeDict) else {
            valid = false
            parser.abortParsing()
            return
        }
        stack.append(attributes)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let start = text.utf8.count
        text += string
        let attributes = stack.last ?? MarkupAttributes()
        guard attributes != MarkupAttributes() else { return }
        if let last = runs.last, last.end == start, last.attributes == attributes {
            runs[runs.count - 1].end = text.utf8.count
        } else {
            runs.append((start, text.utf8.count, attributes))
        }
    }
}

/// Pango's relative size step (`PANGO_SCALE_LARGE`).
private let sizeStep = 1.2

private extension MarkupAttributes {
    /// Applies one opening tag; false for a tag Pango does not know.
    mutating func apply(tag: String, spanAttributes: [String: String]) -> Bool {
        switch tag {
        case "markup": break
        case "b": bold = true
        case "i": italic = true
        case "u": underline = true
        case "s": strikethrough = true
        case "tt":
            monospace = true
            fontFamily = nil
        case "big": scale *= sizeStep
        case "small": scale /= sizeStep
        case "sub", "sup":
            script = tag == "sub" ? .sub : .sup
            scale /= sizeStep
        case "span":
            for (name, value) in spanAttributes {
                applySpan(name, value)
            }
        default: return false
        }
        return true
    }

    /// One `<span>` attribute. Unknown names and unparsable values change
    /// nothing.
    mutating func applySpan(_ name: String, _ value: String) {
        let keyword = value.lowercased()
        switch name {
        case "foreground", "fgcolor", "color":
            foreground = parseHexColor(value) ?? foreground
        case "background", "bgcolor":
            background = parseHexColor(value) ?? background
        case "font_family", "face":
            fontFamily = value
            monospace = false
        case "weight":
            if let weight = fontWeights[keyword] ?? Int(value) { bold = weight >= 600 }
        case "style":
            if let slanted = ["normal": false, "italic": true, "oblique": true][keyword] { italic = slanted }
        case "underline":
            if keyword == "none" {
                underline = false
            } else if underlineStyles.contains(keyword) {
                underline = true
            }
        case "strikethrough":
            if let on = parseBoolean(keyword) { strikethrough = on }
        case "size":
            applySize(keyword)
        default: break
        }
    }

    mutating func applySize(_ value: String) {
        if let level = sizeLevels[value] {
            scale = level < 0
                ? (0 ..< -level).reduce(1) { scale, _ in scale / sizeStep }
                : (0 ..< level).reduce(1) { scale, _ in scale * sizeStep }
        } else if value == "larger" {
            scale *= sizeStep
        } else if value == "smaller" {
            scale /= sizeStep
        } else if let units = Int(value), units > 0 {
            pointSize = Double(units) / 1024
            scale = 1
        } else if value.hasSuffix("pt"), let points = Double(value.dropLast(2)), points > 0 {
            pointSize = points
            scale = 1
        }
    }
}

/// `PangoWeight` names (pango/pango-font.h).
private let fontWeights = [
    "thin": 100, "ultralight": 200, "light": 300, "semilight": 350, "book": 380, "normal": 400,
    "medium": 500, "semibold": 600, "bold": 700, "ultrabold": 800, "heavy": 900, "ultraheavy": 1000,
]

/// Absolute size keywords as steps from the base font.
private let sizeLevels = [
    "xx-small": -3, "x-small": -2, "small": -1, "medium": 0, "large": 1, "x-large": 2, "xx-large": 3,
]

private let underlineStyles: Set = ["single", "double", "low", "error", "single-line", "double-line", "error-line"]

/// Pango's `span_parse_boolean`.
private func parseBoolean(_ value: String) -> Bool? {
    if ["true", "yes", "t", "y", "1"].contains(value) { return true }
    if ["false", "no", "f", "n", "0"].contains(value) { return false }
    return nil
}

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
private func parseHexColor(_ value: String) -> MarkupColor? {
    guard value.first == "#" else { return nil }
    let digits = Array(value.dropFirst())
    guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    let width = digits.count <= 4 ? 1 : 2
    let channels = stride(from: 0, to: digits.count, by: width).map { offset -> UInt8 in
        let channel = UInt8(String(digits[offset ..< offset + width]), radix: 16)!
        return width == 1 ? channel * 17 : channel
    }
    return MarkupColor(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count == 4 ? channels[3] : 255)
}
