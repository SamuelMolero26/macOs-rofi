import Foundation

/// Renders one dmenu output line for `-format`, including the trailing
/// newline. Mirrors rofi's `rofi_output_formatted_line`
/// (source/helper.c:1693-1731). Pass `index: -1` for custom input, which
/// rofi prints as `-1` for `i` and `0` for `d`.
public func formatOutputLine(_ format: String, entry: String, index: Int, filter: String?) -> String {
    var out = ""
    for char in format {
        switch char {
        case "i": out += String(index)
        case "d": out += String(index + 1)
        case "s": out += entry
        case "p": out += stripPangoMarkup(entry) ?? "invalid string"
        case "q": out += shellQuote(entry)
        case "f": out += filter ?? ""
        case "F": out += filter.map(shellQuote) ?? ""
        default: out.append(char)
        }
    }
    return out + "\n"
}

/// How a dmenu run ended (source/modes/dmenu.c:796-802, 888-891).
public enum DmenuOutcome: Equatable, Sendable {
    case accepted
    case cancelled
    /// Custom keybinding `kb-custom-N`, with N in 1...19.
    case customKey(Int)

    public var exitCode: Int32 {
        switch self {
        case .accepted: 0
        case .cancelled: 1
        case .customKey(let n): Int32(10 + n - 1)
        }
    }
}

/// `g_shell_quote`: single quotes, with each `'` written as `'\''`.
private func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// `pango_parse_markup` text extraction: nil when the markup is invalid.
// ponytail: checks well-formedness and tag names only; Pango's span
// attribute validation is skipped, so a bad attribute still strips cleanly.
private func stripPangoMarkup(_ markup: String) -> String? {
    let parser = XMLParser(data: Data(("<markup>" + markup + "</markup>").utf8))
    let collector = MarkupTextCollector()
    parser.delegate = collector
    return parser.parse() && collector.valid ? collector.text : nil
}

private let pangoTags: Set<String> = ["markup", "span", "b", "big", "i", "s", "sub", "sup", "small", "tt", "u"]

private final class MarkupTextCollector: NSObject, XMLParserDelegate {
    var text = ""
    var valid = true

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard pangoTags.contains(elementName) else {
            valid = false
            parser.abortParsing()
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }
}
