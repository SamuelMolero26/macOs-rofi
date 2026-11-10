import Foundation

/// One dmenu or script row: the text before the first NUL, then
/// `key\x1fvalue` pairs up to the next NUL. Mirrors rofi's
/// `dmenuscript_parse_entry_extras` (source/modes/script.c:89-131).
public struct Row: Equatable, Sendable {
    public var text: String
    public var icons: [String] = []
    public var display: String?
    public var meta: String?
    public var info: String?
    public var nonselectable = false
    public var permanent = false
    public var urgent = false
    public var active = false

    public init(parsing line: String) {
        self.init(parsing: Array(line.utf8))
    }

    /// Only the text goes through `rofi_force_utf8` (source/modes/dmenu.c:181-190).
    public init<C: Collection>(parsing bytes: C) where C.Element == UInt8 {
        let nul = bytes.firstIndex(of: 0) ?? bytes.endIndex
        text = forceUTF8(bytes[..<nul])
        guard nul != bytes.endIndex else { return }

        // The extras are read as a C string, so a second NUL ends them.
        // ponytail: rofi keeps extras as raw bytes; invalid UTF-8 here becomes U+FFFD.
        let extras = bytes[bytes.index(after: nul)...].prefix { $0 != 0 }
        let fields = extras.split(separator: 0x1F, omittingEmptySubsequences: false).map(forceUTF8)
        // A trailing key without a value is dropped, like rofi's pair loop.
        for i in stride(from: 0, to: fields.count - 1, by: 2) {
            let value = fields[i + 1]
            let isTrue = value.lowercased() == "true"
            switch fields[i].lowercased() {
            case "icon":
                // g_strsplit("") yields no items; inner empties are kept.
                icons =
                    value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            case "display": display = value
            case "meta": meta = value
            case "info": info = value
            case "nonselectable": nonselectable = isTrue
            case "permanent": permanent = isTrue
            case "urgent": urgent = isTrue
            case "active": active = isTrue
            default: break
            }
        }
    }

    /// `\0icon` (source/modes/script.c:100-101): the first entry of the comma
    /// list that is an absolute path on disk.
    /// ponytail: theme icon names (`firefox`) are not looked up (#73).
    public var iconImagePath: String? {
        icons.first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    /// `dmenu_token_match` and `script_token_match` (source/modes/dmenu.c:668-708,
    /// source/modes/script.c:515-554): a permanent row always matches, before
    /// its markup is parsed; a token the text misses is retried on meta. Under
    /// `markup` the text is the markup's, and invalid markup never matches.
    public func matches(_ matcher: Matcher, markup: Bool) -> Bool {
        guard !permanent else { return true }
        guard let text = markup ? stripPangoMarkup(text) : text else { return false }
        return matcher.matches(text, meta: meta)
    }
}
