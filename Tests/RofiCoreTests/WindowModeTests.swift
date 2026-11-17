// Not Foundation: see HistoryTests.swift.
import RofiCore
import Testing

// Contract: rofi's window mode, source/modes/window.c (match 427-470, result
// 775-862, display string 881-966), over an injected window list.
@Suite final class WindowModeTests {
    private var windows = [
        WindowRecord(handle: 1, id: "42", app: "Code", title: "a & b", bundlePath: "/Applications/Code.app"),
        WindowRecord(handle: 2, id: "", app: "Brave Browser", title: "x", active: true),
    ]
    private var listed = 0
    private var listFailure: WindowListFailure?
    private var raised: [Int] = []
    private var closed: [Int] = []
    private var launched: [[String]] = []
    private var launchResult: Result<Void, ApplicationLaunchFailure> = .success(())

    private func make(
        format: String = "{c}   {t}", matchFields: String = "all", hideActiveWindow: Bool = false,
        closeOnDelete: Bool = true
    ) -> WindowMode {
        WindowMode(
            windows: { [unowned self] in
                listed += 1
                if let listFailure { throw listFailure }
                return windows
            },
            raise: { [unowned self] in raised.append($0.handle) },
            close: { [unowned self] in closed.append($0.handle) },
            format: format, matchFields: matchFields, hideActiveWindow: hideActiveWindow,
            closeOnDelete: closeOnDelete, terminal: "ghostty",
            launcher: { [unowned self] argv in
                launched.append(argv)
                return launchResult
            },
            writeScript: { _, _ in .success("/tmp/unused.command") })
    }

    private func act(
        _ mode: WindowMode, _ action: MenuAction, alt: Bool = false, input: String? = nil, row: Int? = nil
    ) -> ModeResult {
        var input = input
        return mode.result(action, alt: alt, input: &input, selectedRow: row)
    }

    // helper_eval_add_str (window.c:881-905) and _generate_display_string
    // (938-944): width 0 pads to the column's widest value, a positive width
    // truncates or pads, a negative one adds the value as is; only the first
    // letter names the field, unknown fields vanish, trailing blanks go.
    // Rows are markup with the active window flagged (958-964).
    @Test func displayStringPadsTruncatesAndEscapesFields_window_c_881() {
        #expect(make().rows.map(\.text) == ["Code            a &amp; b", "Brave Browser   x"])
        let mode = make(format: "{c:3}|{t:4}|{x}{w}{c:-5}|{class}")
        #expect(mode.rows.map(\.text) == ["Cod|a &amp; |Code|Code", "Bra|x   |Brave Browser|Brave Browser"])
        #expect(mode.markupRows)
        #expect(mode.rows.map(\.active) == [false, true])
        #expect(mode.iconPath(at: 0) == "/Applications/Code.app")
    }

    // window_match (window.c:427-470) on the raw fields named by
    // -window-match-fields (481-510), not on the display string.
    @Test func matchFieldsPickTheRawFieldsMatched_window_c_427() {
        func matching(_ query: String, fields: String) -> [Int] {
            let mode = make(matchFields: fields)
            let matcher = Matcher(query: query, options: MatchOptions())
            return mode.rows.indices.filter { mode.matches(mode.rows[$0], at: $0, matcher: matcher) }
        }
        #expect(matching("brave", fields: "all") == [1])
        #expect(matching("brave", fields: "title") == [])
        #expect(matching("brave", fields: "title,class") == [1])
        #expect(matching("& b", fields: "title") == [0])
        #expect(matching("code a", fields: "all") == [0])
    }

    // window_mode_result (window.c:775-862).
    @Test func actionsRaiseCloseAndRunCommands_window_c_775() {
        let mode = make()
        #expect(act(mode, .ok, row: 1) == .exit)
        #expect(raised == [2])
        // act_on_window (745-773): -window-command with {window}.
        #expect(act(mode, .ok, alt: true, row: 0) == .exit)
        #expect(launched == [["wmctrl", "-i", "-R", "42"]])
        #expect(act(mode, .deleteEntry, row: 0) == .exit)
        #expect(closed == [1])
        // Typed text runs -run-command, or -run-shell-command in a terminal
        // with alt (838-857); empty text just exits.
        #expect(act(mode, .customInput, input: "ls -la") == .exit)
        #expect(act(mode, .customInput, alt: true, input: "top") == .exit)
        #expect(act(mode, .customInput, input: "") == .exit)
        #expect(launched.dropFirst() == [["ls", "-la"], ["ghostty", "-e", "top"]])
        #expect(act(mode, .customKey(2)) == .switchTo(2))
        #expect(act(mode, .cancel) == .exit)

        launchResult = .failure(ApplicationLaunchFailure(command: "nope", reason: "missing"))
        #expect(act(mode, .customInput, input: "nope") == .reload)
        #expect(mode.message == "Failed to execute: 'nope'\nError: 'missing'")
        #expect(act(mode, .ok, alt: true, row: 0) == .reload)
        #expect(mode.message == "Failed to execute action for window: '42'\nError: 'missing'")
    }

    // mode_init runs only when a mode is shown (source/rofi.c:204), so the
    // list is read on first use; a list that cannot be read is the message.
    @Test func listIsReadOnFirstUseAndItsFailureShown_rofi_c_204() {
        let mode = make()
        #expect(listed == 0)
        #expect(mode.rows.count == 2)
        #expect(listed == 1)
        listFailure = WindowListFailure(message: "no access")
        let denied = make()
        #expect(denied.rows.isEmpty)
        #expect(denied.message == "no access")
    }

    // hide-active-window (window.c:704-708, 689-691) drops the active window
    // after it has widened the columns (613-616), and close-on-delete false
    // reloads after closing (833-838), re-reading the list.
    @Test func themeFlagsHideActiveAndKeepOpenOnDelete_window_c_704() {
        let mode = make(hideActiveWindow: true, closeOnDelete: false)
        #expect(mode.rows.map(\.text) == ["Code            a &amp; b"])
        windows.removeFirst()
        windows.append(WindowRecord(handle: 3, id: "7", app: "Music", title: "Music"))
        #expect(act(mode, .deleteEntry, row: 0) == .reload)
        #expect(closed == [1])
        #expect(mode.rows.map(\.text) == ["Music           Music"])
        #expect(act(mode, .ok, row: 0) == .exit)
        #expect(raised == [3])
    }
}
