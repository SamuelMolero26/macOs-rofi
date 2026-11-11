/// `keys` (source/modes/help-keys.c): the key bindings as read-only markup
/// rows, built like config_parser_return_display_help (source/xrmoptions.c:
/// 1240-1330): `<b>name</b> (binding) <span ...>comment</span>`, in
/// source/keyb.c's order, with `-kb-*` values applied.
///
/// ponytail: only the bindings in `KeyAction`; upstream also lists the keys
/// this port hard-wires in the panel (kb-accept-entry, kb-cancel, movement,
/// editing, `ml-*`, `me-*`). Names pad to the longest listed name, not to the
/// longest option name of all.
public final class KeysMode: Mode {
    public let name = "keys"
    /// help_keys_token_match (help-keys.c:99-104) matches the markup itself,
    /// so the row's text is the markup.
    public let rows: [Row]

    public init(keymap: Keymap) {
        let width = KeyAction.allCases.map(\.optionName.count).max() ?? 0
        rows = KeyAction.allCases.map { action in
            let name = action.optionName.padding(toLength: width, withPad: " ", startingAt: 0)
            return Row(
                parsing: "<b>\(escapeMarkup(name))</b> (\(escapeMarkup(keymap.binding(for: action)))) "
                    + "<span style='italic' size='small'>\(escapeMarkup(action.comment))</span>")
        }
    }

    /// The MARKUP state bit (help-keys.c:93).
    public var markupRows: Bool { true }

    /// help_keys_mode_result (help-keys.c:68-76): a custom key switches to the
    /// mode with its index; anything else closes rofi without output.
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        if case .customKey(let index) = action { return .switchTo(index) }
        return .exit
    }
}
