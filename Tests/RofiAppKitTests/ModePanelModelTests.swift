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

// source/modes/script.c:505-507: a markup-rows mode sets the MARKUP bit on
// every row, which the panel draws as markup.
@MainActor @Suite struct ModePanelModelTests {
    @Test func markupRowsModeSetsTheMarkupBit() {
        for markupRows in [true, false] {
            let model = ModePanelModel(switcher: ModeSwitcher(modes: [MarkupMode(markupRows: markupRows)]))
            #expect(model.state(of: model.matches[0]).contains(.markup) == markupRows)
        }
    }
}
