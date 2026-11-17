import Foundation

/// `combi` (source/modes/combi.c): the rows of several modes in one list. Each
/// action, match, completion and icon is handed to the mode owning the row,
/// with the row index made local to it.
///
/// ponytail: the theme color per mode name (combi.c:232-245) is not read, and
/// `-combi-display-format` substitutes only `{mode}` and `{text}`, without
/// `[...]` groups.
public final class CombiMode: Mode {
    public let name = "combi"
    private let modes: [any Mode]
    private let displayNames: [String]
    private let displayFormat: String?
    /// Each mode's rows and their place in the combined list, from the last
    /// `rows` read (`starts`/`lengths`, combi.c:100-111).
    private var parts: [(rows: [Row], range: Range<Int>)] = []
    /// Modes hidden by the `!prefix` filter (combi.c:301-335).
    private var disabled: [Bool]

    /// `displayNames` holds each mode's `-display-<name>` or name; a nil
    /// `displayFormat` is `-combi-hide-mode-prefix`.
    public init(modes: [any Mode], displayNames: [String], displayFormat: String?) {
        self.modes = modes
        self.displayNames = displayNames
        self.displayFormat = displayFormat
        disabled = modes.map { _ in false }
    }

    /// combi_mgrv (combi.c:208-254): a prefixed row is escaped into markup.
    public var markupRows: Bool { displayFormat != nil || modes.contains { $0.markupRows } }

    /// combi_mode_get_num_entries (combi.c:100-111) with combi_mgrv's text.
    public var rows: [Row] {
        var start = 0
        parts = modes.map { mode in
            let rows = mode.rows
            defer { start += rows.count }
            return (rows, start..<start + rows.count)
        }
        let markup = markupRows
        return modes.indices.flatMap { index in
            parts[index].rows.map { row in
                var row = row
                var text = row.display ?? row.text
                if markup && !modes[index].markupRows { text = escapeMarkup(text) }
                if let displayFormat {
                    // mode_get_display_name: the mode's own name first.
                    let mode = modes[index].displayName ?? displayNames[index]
                    text = displayFormat.replacingOccurrences(of: "{mode}", with: mode)
                        .replacingOccurrences(of: "{text}", with: text)
                }
                row.display = text
                return row
            }
        }
    }

    /// combi_mode_match (combi.c:192-205).
    public func matches(_ row: Row, at index: Int, matcher: Matcher) -> Bool {
        guard let owner = owner(of: index), !disabled[owner.mode] else { return false }
        return modes[owner.mode].matches(parts[owner.mode].rows[owner.row], at: owner.row, matcher: matcher)
    }

    /// combi_preprocess_input (combi.c:301-343): `!prefix rest` keeps only the
    /// modes whose name starts with `prefix` and matches on `rest`.
    public func preprocessInput(_ input: String) -> String {
        guard let bang = bang(input) else {
            disabled = modes.map { _ in false }
            return input
        }
        disabled = modes.map { !$0.name.hasPrefix(bang.prefix) }
        return bang.rest ?? ""
    }

    /// combi_get_completion (combi.c:256-270).
    public func completion(at row: Int) -> String {
        guard let owner = owner(of: row) else { return "" }
        return "!\(modes[owner.mode].name) \(modes[owner.mode].completion(at: owner.row))"
    }

    public func iconPath(at row: Int) -> String? {
        owner(of: row).flatMap { modes[$0.mode].iconPath(at: $0.row) }
    }

    public func iconImagePath(at row: Int) -> String? {
        owner(of: row).flatMap { modes[$0.mode].iconImagePath(at: $0.row) }
    }

    /// combi_mode_result (combi.c:153-190).
    public func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult {
        route(&input, selectedRow, customInput: action == .customInput) {
            $0.result(action, alt: alt, input: &$1, selectedRow: $2)
        } ?? .exit
    }

    /// combi.c:187-189: without a `!prefix`, MENU_COMPLETE only reloads.
    public func complete(input: inout String?, selectedRow: Int?) -> ModeResult? {
        guard input?.first == "!" else { return .reload }
        return route(&input, selectedRow, customInput: false) { $0.complete(input: &$1, selectedRow: $2) }
    }

    /// A `!prefix` naming a mode wins; else the mode owning the row; else
    /// typed text goes to the first mode (combi.c:157-200).
    private func route(
        _ input: inout String?, _ selectedRow: Int?, customInput: Bool,
        _ call: (any Mode, inout String?, Int?) -> ModeResult?
    ) -> ModeResult? {
        if let bang = bang(input), let index = modes.firstIndex(where: { $0.name.hasPrefix(bang.prefix) }) {
            // 167-180: the mode gets a copy of the rest; its rewrite is dropped.
            var rest = bang.rest
            let row = selectedRow.flatMap { owner(of: $0) }.flatMap { $0.mode == index ? $0.row : nil }
            return call(modes[index], &rest, row)
        }
        if let owner = selectedRow.flatMap({ owner(of: $0) }) {
            return call(modes[owner.mode], &input, owner.row)
        }
        if customInput, let first = modes.first {
            return call(first, &input, nil)
        }
        return .exit
    }

    private func owner(of row: Int) -> (mode: Int, row: Int)? {
        parts.firstIndex { $0.range.contains(row) }.map { ($0, row - parts[$0].range.lowerBound) }
    }
}

/// The `!prefix` starting `input`, and the text after the first space, nil
/// without one (combi.c:157-166, 307-314). nil for no prefix.
/// ponytail: the prefix compares with `hasPrefix`, not utf8_strncmp's collation.
private func bang(_ input: String?) -> (prefix: Substring, rest: String?)? {
    guard let input, input.first == "!" else { return nil }
    let body = input.dropFirst()
    let space = body.firstIndex(of: " ")
    let prefix = body[..<(space ?? body.endIndex)]
    guard !prefix.isEmpty else { return nil }
    return (prefix, space.map { String(body[body.index(after: $0)...]) })
}

/// g_markup_escape_text, as g_markup_printf_escaped escapes each argument.
func escapeMarkup(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
