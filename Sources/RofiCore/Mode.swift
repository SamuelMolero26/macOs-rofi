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
/// ponytail: no icons, completion or preprocess_input yet.
public protocol Mode: AnyObject {
    var name: String { get }
    /// The rows offered now, re-read after every switch and reload
    /// (source/view.c:801-809).
    var rows: [Row] { get }
    /// `_get_message` (source/mode.c:211-222); nil by default.
    var message: String? { get }
    /// `_token_match`; by default the row's text must match.
    func matches(_ row: Row, matcher: Matcher) -> Bool
    /// `_result`. `input` is the query: set it to replace the query, or to nil
    /// to clear it. `selectedRow` is the source row, or nil when none applies.
    func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult
}

extension Mode {
    public var message: String? { nil }

    public func matches(_ row: Row, matcher: Matcher) -> Bool {
        matcher.matches(row.text)
    }
}
