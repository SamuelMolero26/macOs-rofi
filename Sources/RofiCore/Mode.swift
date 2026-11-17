/// What the user did, as handed to a mode's `result` (rofi's MenuReturn,
/// include/mode.h:70-93). Next, previous and quick switch are absent: the
/// switcher resolves them before a mode is asked (source/mode.c:131-141).
public enum MenuAction: Equatable, Sendable {
    /// MENU_OK: a row was accepted.
    case ok
    /// MENU_CUSTOM_INPUT: the query was accepted as typed.
    case customInput
    /// MENU_CANCEL.
    case cancel
    /// MENU_ENTRY_DELETE.
    case deleteEntry
    /// MENU_CUSTOM_COMMAND with the custom key's index.
    case customKey(Int)
}

/// What the switcher does after a mode handled an action (rofi's ModeMode,
/// include/mode.h:55-65, applied in source/rofi.c:235-291).
public enum ModeResult: Equatable, Sendable {
    /// MODE_EXIT: close the switcher.
    case exit
    /// NEXT_DIALOG.
    case next
    /// PREVIOUS_DIALOG.
    case previous
    /// RELOAD_DIALOG: stay, re-read the rows and refilter.
    case reload
    /// RESET_DIALOG: like reload, after clearing the input.
    case reset
    /// A value below MODE_EXIT: switch to that mode index, modulo the count.
    case switchTo(Int)
}

/// A `-show` mode (include/mode.h, source/mode.c:46-222).
///
/// Class-bound because a mode is long-lived state the switcher reaches by
/// reference: `result` changes what `rows` returns next (a script mode re-runs
/// its script), and one mode can sit in the switcher more than once.
///
/// ponytail: icons are file paths only, no theme icon names.
public protocol Mode: AnyObject {
    var name: String { get }
    /// The rows offered now, re-read after every switch and reload
    /// (source/view.c:801-809).
    var rows: [Row] { get }
    /// `_get_message` (source/mode.c:211-222); nil by default.
    var message: String? { get }
    /// `Mode.display_name` set by the mode itself, as a script's prompt
    /// header does (source/modes/script.c:161-164). It beats
    /// `-display-<name>` (source/mode.c:199-202); nil by default.
    var displayName: String? { get }
    /// A source row the mode selected from `result`, as
    /// rofi_view_set_selected_line (source/view.c:369-382), read right after
    /// each `result`. nil keeps the visible selection; the default.
    var selectedRowAfterResult: Int? { get }
    /// Rows are Pango markup, drawn styled (the MARKUP state bit,
    /// source/modes/script.c:505-507); false by default.
    var markupRows: Bool { get }
    /// `_token_match` with the source row index, as upstream passes it
    /// (source/mode.c:150-155); by default the row's text must match. `combi`
    /// routes it to the mode owning the row.
    func matches(_ row: Row, at index: Int, matcher: Matcher) -> Bool
    /// `_preprocess_input` (source/mode.c:212-217): the query the matcher is
    /// built from, asked before each non-empty refilter (source/view.c:833).
    /// Only `combi` changes it; the default returns it unchanged.
    func preprocessInput(_ input: String) -> String
    /// `_get_completion`, used as the text scored by interactive sorting.
    func completion(at row: Int) -> String
    /// `_get_icon` (source/mode.c:87-96) as the file whose Finder icon a
    /// source row shows; nil for none, the default.
    func iconPath(at row: Int) -> String?
    /// An image file a source row shows as itself rather than as its Finder
    /// icon, as a script's `\0icon` row does; nil for none, the default.
    func iconImagePath(at row: Int) -> String?
    /// `_result`. `alt` is MENU_CUSTOM_ACTION (include/mode.h:72,78,90), set
    /// by kb-accept-alt and kb-accept-custom-alt (source/view.c:1280-1293,
    /// 1302-1309); only `run` reads it (source/modes/run.c:456). `input` is the
    /// query: set it to replace the query, or to nil to clear it.
    /// `selectedRow` is the source row, or nil when none applies.
    func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult
    /// `_result` with MENU_COMPLETE (include/mode.h:88), sent by
    /// kb-mode-complete (source/view.c:1128-1136). `selectedRow` is the
    /// highlighted source row, or nil without a visible row; `input` is the
    /// query as for `result`. nil ignores the key, the default.
    /// ponytail: upstream drun opens the file completer for `%f`/`%u` entries
    /// (source/modes/drun.c:1426-1455); `DrunMode` keeps the default.
    /// A requirement, so a call through `any Mode` reaches a mode's own version.
    func complete(input: inout String?, selectedRow: Int?) -> ModeResult?
}

extension Mode {
    public var message: String? { nil }
    public var displayName: String? { nil }
    public var selectedRowAfterResult: Int? { nil }
    public var markupRows: Bool { false }
    public func iconPath(at row: Int) -> String? { nil }
    public func iconImagePath(at row: Int) -> String? { nil }

    public func matches(_ row: Row, at index: Int, matcher: Matcher) -> Bool {
        matcher.matches(row.text)
    }
    public func preprocessInput(_ input: String) -> String { input }
    public func completion(at row: Int) -> String { rows[row].text }

    /// `result` without `alt`.
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        result(action, alt: false, input: &input, selectedRow: selectedRow)
    }

    public func complete(input: inout String?, selectedRow: Int?) -> ModeResult? { nil }
}
