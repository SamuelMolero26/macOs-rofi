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
        // The extras are read as a C string, so a second NUL ends them.
        let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
        text = String(parts[0])
        guard parts.count > 1 else { return }

        let fields = parts[1].split(separator: "\u{1F}", omittingEmptySubsequences: false)
        // A trailing key without a value is dropped, like rofi's pair loop.
        for i in stride(from: 0, to: fields.count - 1, by: 2) {
            let value = String(fields[i + 1])
            let isTrue = value.lowercased() == "true"
            switch fields[i].lowercased() {
            case "icon":
                // g_strsplit("") yields no items; inner empties are kept.
                icons = value.isEmpty ? [] : value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
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
}
