import RofiCore
import Testing

/// A mode whose `result` answers with a scripted ModeResult and input rewrite,
/// recording what the switcher handed it.
private final class FakeMode: Mode {
    let name: String
    var rows: [Row]
    var message: String?
    var answer: ModeResult = .exit
    var rewrite: String?? = .none
    var onResult: () -> Void = {}
    private(set) var calls: [(action: MenuAction, input: String?, selectedRow: Int?)] = []

    init(_ name: String, _ rows: [String], message: String? = nil) {
        self.name = name
        self.rows = rows.map { Row(parsing: $0) }
        self.message = message
    }

    func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        calls.append((action, input, selectedRow))
        if case .some(let value) = rewrite { input = value }
        onResult()
        return answer
    }
}

// Contract: the switcher driver in rofi source/rofi.c:201-291, mode_result in
// source/mode.c:131-147 and rofi_view_switch_mode in source/view.c:2150-2177.
@Suite struct ModeSwitcherTests {
    private let a = FakeMode("a", ["apple", "Banana", "cherry"])
    private let b = FakeMode("b", ["band", "bee"])
    private let c = FakeMode("c", ["cat"])

    private func switcher(start: Int = 0, displayNames: [String]? = nil) -> ModeSwitcher {
        ModeSwitcher(modes: [a, b, c], displayNames: displayNames, start: start)
    }

    @Test func startsOnTheGivenModeWithItsRows() {
        let s = switcher(start: 1)
        #expect(s.currentIndex == 1)
        #expect(s.matches.map(\.row.text) == ["band", "bee"])
        #expect(s.selectedVisibleIndex == 0)
    }

    // source/rofi.c:262-263: NEXT_DIALOG wraps with (cur + 1) % n.
    @Test func nextWrapsAround_rofi_c_262() {
        var s = switcher(start: 2)
        s.next()
        #expect(s.currentIndex == 0)
        s.next()
        #expect(s.currentIndex == 1)
    }

    // source/rofi.c:264-269: PREVIOUS_DIALOG wraps 0 -> n - 1.
    @Test func previousWrapsAround_rofi_c_264() {
        var s = switcher()
        s.previous()
        #expect(s.currentIndex == 2)
        s.previous()
        #expect(s.currentIndex == 1)
    }

    // source/mode.c:134-139: switching keys never reach the mode.
    @Test func switchingKeysDoNotCallTheMode_mode_c_134() {
        var s = switcher()
        s.next()
        s.previous()
        s.switchTo(2)
        #expect(a.calls.isEmpty && b.calls.isEmpty && c.calls.isEmpty)
    }

    // source/view.c:2170-2174: the typed input survives a switch and the new
    // mode's rows are refiltered against it. Case-insensitive by default
    // (config/config.c:111).
    @Test func queryIsKeptAndRefilteredAcrossASwitch_view_c_2170() {
        var s = switcher()
        s.updateQuery("BAN")
        #expect(s.matches.map(\.row.text) == ["Banana"])
        s.next()
        #expect(s.query == "BAN")
        #expect(s.matches.map(\.row.text) == ["band"])
    }

    // source/widgets/listview.c:614-623, 651-656: a switch keeps the visible
    // selection, clamped to the new mode's matches.
    @Test func switchClampsTheVisibleSelection_listview_c_651() {
        var s = switcher()
        s.selectVisibleIndex(2)
        s.next()
        #expect(s.selectedVisibleIndex == 1)
        s.switchTo(2)
        #expect(s.selectedVisibleIndex == 0)
        s.updateQuery("zzz")
        #expect(s.selectedVisibleIndex == nil)
    }

    // source/rofi.c:270-271: a quick-switch index is taken modulo n.
    @Test func switchToTakesTheIndexModuloModeCount_rofi_c_270() {
        var s = switcher()
        s.switchTo(4)
        #expect(s.currentIndex == 1)
        a.answer = .switchTo(5)
        s.switchTo(0)
        s.accept()
        #expect(s.isOpen)
        #expect(s.currentIndex == 2)
    }

    // source/view.c:1308-1319: accept sends MENU_OK with the selected source
    // row, or custom input when nothing is selected.
    @Test func acceptForwardsTheSelectedSourceRow_view_c_1308() throws {
        a.answer = .reload
        var s = switcher()
        s.updateQuery("e")
        s.selectVisibleIndex(1)
        s.accept()
        #expect(s.isOpen)
        let call = try #require(a.calls.last)
        #expect(call.action == .ok)
        #expect(call.input == "e")
        #expect(call.selectedRow == 2)

        s.updateQuery("zzz")
        s.accept()
        #expect(s.isOpen)
        #expect(a.calls.last?.action == .customInput)
        #expect(a.calls.last?.selectedRow == nil)
    }

    // source/view.c:1296-1301: kb-accept-custom never carries a row.
    @Test func customInputCarriesNoRow_view_c_1296() {
        a.answer = .reload
        var s = switcher()
        s.perform(.customInput)
        #expect(s.isOpen)
        #expect(a.calls.last?.action == .customInput)
        #expect(a.calls.last?.selectedRow == nil)
    }

    @Test func otherActionsCarryTheSelectedRow() {
        a.answer = .reload
        var s = switcher()
        s.selectVisibleIndex(2)
        s.perform(.deleteEntry)
        #expect(s.isOpen)
        #expect(a.calls.last?.selectedRow == 2)
        s.perform(.customKey(3))
        #expect(s.isOpen)
        #expect(a.calls.last?.action == .customKey(3))
    }

    // source/rofi.c:243-251: a non-nil rewrite becomes the query, nil clears it.
    @Test func inputRewriteSetsOrClearsTheQuery_rofi_c_243() {
        a.answer = .reload
        var s = switcher()
        s.updateQuery("x")
        a.rewrite = .some("che")
        s.accept()
        #expect(s.isOpen)
        #expect(s.query == "che")
        #expect(s.matches.map(\.row.text) == ["cherry"])
        a.rewrite = .some(nil)
        s.accept()
        #expect(s.isOpen)
        #expect(s.query == "")
        #expect(s.matches.count == 3)
    }

    // source/rofi.c:272-273, source/view.c:2138-2143: RESET_DIALOG clears the
    // input and selects the first row.
    @Test func resetClearsTheQuery_rofi_c_272() {
        a.answer = .reset
        var s = switcher()
        s.updateQuery("a")
        s.selectVisibleIndex(1)
        s.accept()
        #expect(s.isOpen)
        #expect(s.currentIndex == 0)
        #expect(s.query == "")
        #expect(s.matches.count == 3)
        #expect(s.selectedVisibleIndex == 0)
    }

    // source/rofi.c:270, source/view.c:801-809: RELOAD_DIALOG stays on the
    // mode and re-reads its rows.
    @Test func reloadRereadsRowsAndRefilters_view_c_801() {
        a.answer = .reload
        a.onResult = { [a] in a.rows = [Row(parsing: "avocado"), Row(parsing: "date")] }
        var s = switcher()
        s.updateQuery("a")
        s.accept()
        #expect(s.isOpen)
        #expect(s.currentIndex == 0)
        #expect(s.matches.map(\.row.text) == ["avocado", "date"])
    }

    @Test func modeResultsCanSwitch() {
        var s = switcher()
        a.answer = .next
        s.accept()
        #expect(s.isOpen)
        #expect(s.currentIndex == 1)
        b.answer = .previous
        s.accept()
        #expect(s.isOpen)
        #expect(s.currentIndex == 0)
    }

    // source/rofi.c:279-289: MODE_EXIT ends the switcher.
    @Test func exitEndsTheSwitcher_rofi_c_279() {
        var s = switcher()
        let stillOpen = s.accept()
        #expect(!stillOpen)
        #expect(!s.isOpen)
        #expect(a.calls.count == 1)
        let afterExit = s.cancel()
        #expect(!afterExit)
        #expect(a.calls.count == 1)
    }

    @Test func cancelReachesTheMode() {
        var s = switcher()
        s.cancel()
        #expect(!s.isOpen)
        #expect(a.calls.last?.action == .cancel)
        #expect(a.calls.last?.selectedRow == nil)
    }

    // source/view.c:222-227, 2150-2166 and 1790-1810: prompt, window title and
    // switcher buttons use the display name.
    @Test func chromeFollowsTheDisplayName_view_c_2150() {
        var s = switcher(displayNames: ["Apps", "Bees", "Cats"])
        #expect(s.prompt == "Apps")
        #expect(s.windowTitle == "rofi - Apps")
        s.next()
        #expect(s.prompt == "Bees")
        #expect(s.windowTitle == "rofi - Bees")
        #expect(s.displayNames == ["Apps", "Bees", "Cats"])
        #expect(s.currentIndex == 1)
    }

    // source/mode.c:189-208: without a display name the mode name is used.
    @Test func displayNamesDefaultToModeNames_mode_c_189() {
        let s = switcher()
        #expect(s.displayNames == ["a", "b", "c"])
        #expect(s.prompt == "a")
    }

    // source/view.c:230-240: the message comes from the current mode.
    @Test func messageFollowsTheCurrentMode() {
        b.message = "hello"
        var s = switcher()
        #expect(s.message == nil)
        s.next()
        #expect(s.message == "hello")
    }

    // source/view.c:829: an empty query shows every row unfiltered.
    @Test func emptyQueryShowsEveryRow_view_c_829() {
        let s = switcher()
        #expect(s.matches.map(\.sourceIndex) == [0, 1, 2])
    }
}
