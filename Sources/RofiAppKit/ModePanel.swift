import RofiCore

/// Runs one `-show` interaction on the main actor until a mode answers
/// `.exit`. `sidebar` adds the switcher row (`-sidebar-mode`,
/// source/view.c:1667-1668); `icons` the icon column (`-show-icons`).
/// `style` carries the resolved theme.
@MainActor public func runModePanel(
    switcher: ModeSwitcher, sidebar: Bool, icons: Bool, keymap: Keymap, style: PanelStyle = PanelStyle()
) {
    let model = ModePanelModel(switcher: switcher)
    var style = model.style(base: style, sidebar: sidebar)
    style.showIcons = icons
    runPanel(model: model, style: style, keymap: keymap, streaming: nil)
}

/// A `-show` mode switcher (source/rofi.c:201-291), which ends when a mode
/// answers `.exit`.
@MainActor final class ModePanelModel: PanelModel {
    private var switcher: ModeSwitcher

    init(switcher: ModeSwitcher) {
        self.switcher = switcher
    }

    /// Button labels are read once, when the row is built (source/view.c:1798-1806).
    func style(base: PanelStyle = PanelStyle(), sidebar: Bool) -> PanelStyle {
        var style = base
        style.accessibilityName = "Rofi"
        style.switcherLabels = sidebar ? switcher.modes.indices.map(switcher.displayName(at:)) : nil
        return style
    }

    var query: String { switcher.query }
    var matches: [DmenuMatch] { switcher.matches }
    var selectedVisibleIndex: Int? { switcher.selectedVisibleIndex }
    var prompt: String { switcher.prompt }
    var windowTitle: String { switcher.windowTitle }
    var message: String? { switcher.message }
    var selectionOverlay: String? { nil }
    var currentMode: Int? { switcher.currentIndex }

    /// `_get_display_value` shows a row's display text over its text
    /// (source/modes/script.c:508-512).
    func displayText(for match: DmenuMatch) -> String { match.row.display ?? match.row.text }

    /// source/modes/script.c:499-507.
    func state(of match: DmenuMatch) -> DmenuRowState {
        var state: DmenuRowState = []
        if match.row.active { state.insert(.active) }
        if match.row.urgent { state.insert(.urgent) }
        if switcher.current.markupRows { state.insert(.markup) }
        return state
    }

    func iconPath(for match: DmenuMatch) -> String? { switcher.current.iconPath(at: match.sourceIndex) }
    func iconImagePath(for match: DmenuMatch) -> String? { switcher.current.iconImagePath(at: match.sourceIndex) }

    func updateQuery(_ query: String) -> PanelUpdate {
        switcher.updateQuery(query)
        return .reload
    }

    func appendRows(_ rows: [Row]) {}
    func selectVisibleIndex(_ index: Int?) { switcher.selectVisibleIndex(index) }
    func moveSelection(by offset: Int) { switcher.moveSelection(by: offset) }

    func accept() -> PanelUpdate { switcher.accept() ? .reload : .close }
    func perform(_ action: KeyAction) -> PanelUpdate { switcher.perform(key: action) ? .reload : .close }
    func cancel() -> PanelUpdate { switcher.cancel() ? .reload : .close }

    func switchMode(by offset: Int) -> PanelUpdate {
        offset < 0 ? switcher.previous() : switcher.next()
        return .reload
    }

    func switchTo(_ index: Int) -> PanelUpdate {
        switcher.switchTo(index)
        return .reload
    }
}
