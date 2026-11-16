import RofiCore
import Testing

@testable import RofiAppKit

/// A mode whose rows are markup, as a script's markup-rows header sets.
private final class MarkupMode: Mode {
    let name = "m"
    let rows = [Row(parsing: "<b>x</b>")]
    let markupRows: Bool

    init(markupRows: Bool) {
        self.markupRows = markupRows
    }

    func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult { .exit }
}

/// Rows "1"..."count" that record the row accepted, then exit.
private final class NumberedMode: Mode {
    let name = "n"
    let rows: [Row]
    private(set) var accepted: Int?

    init(count: Int) {
        rows = (1...count).map { Row(parsing: "\($0)") }
    }

    func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        accepted = selectedRow
        return .exit
    }
}

@MainActor @Suite struct ModePanelModelTests {
    // source/modes/script.c:505-507: a markup-rows mode sets the MARKUP bit on
    // every row, which the panel draws as markup.
    @Test func markupRowsModeSetsTheMarkupBit() {
        for markupRows in [true, false] {
            let model = ModePanelModel(switcher: ModeSwitcher(modes: [MarkupMode(markupRows: markupRows)]))
            #expect(model.state(of: model.matches[0]).contains(.markup) == markupRows)
        }
    }

    // source/view.c:1157-1174, 1218-1241, source/widgets/listview.c:1029-1075.
    @Test func navigationKeysMoveByPositionAndClamp() {
        let model = ModePanelModel(switcher: ModeSwitcher(modes: [NumberedMode(count: 12)]))
        func press(_ action: KeyAction) -> Int? {
            #expect(model.navigate(action, pageSize: 5, repeatedTab: false) == .none)
            return model.selectedVisibleIndex
        }
        #expect(press(.pageNext) == 5)
        #expect(press(.pageNext) == 10)
        #expect(press(.pageNext) == 11)  // clamps, never wraps
        #expect(press(.pagePrev) == 6)
        #expect(press(.rowFirst) == 0)
        #expect(press(.pagePrev) == 0)
        #expect(press(.rowLast) == 11)
        #expect(press(.rowTab) == 0)  // moves down, wrapping with the default cycle
    }

    @Test func selectRowAcceptsTheNthVisibleRow() {
        let mode = NumberedMode(count: 3)
        let model = ModePanelModel(switcher: ModeSwitcher(modes: [mode]))
        #expect(model.navigate(.selectRow(4), pageSize: 5, repeatedTab: false) == .none)
        #expect(mode.accepted == nil)
        #expect(model.navigate(.selectRow(3), pageSize: 5, repeatedTab: false) == .close)
        #expect(mode.accepted == 2)
    }

    // source/view.c:630-648: one row accepts; an empty list tabbed twice
    // switches to the next mode.
    @Test func rowTabAcceptsALoneRowAndSwitchesModeWhenEmpty() {
        let lone = NumberedMode(count: 1)
        #expect(
            ModePanelModel(switcher: ModeSwitcher(modes: [lone])).navigate(.rowTab, pageSize: 5, repeatedTab: false)
                == .close)
        #expect(lone.accepted == 0)

        let model = ModePanelModel(switcher: ModeSwitcher(modes: [NumberedMode(count: 2), NumberedMode(count: 2)]))
        _ = model.updateQuery("no match")
        #expect(model.navigate(.rowTab, pageSize: 5, repeatedTab: false) == .none)
        #expect(model.currentMode == 0)
        #expect(model.navigate(.rowTab, pageSize: 5, repeatedTab: true) == .reload)
        #expect(model.currentMode == 1)
    }
}
