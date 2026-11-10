import RofiCore

/// What the panel redraws after its model handled an action.
enum PanelUpdate {
    /// Nothing visible changed.
    case none
    /// The rows, the selection, the query or the chrome may have changed.
    case reload
    /// The interaction is over.
    case close
}

/// The state behind a panel: a dmenu session or a `-show` mode switcher.
/// Each model keeps its own outcome; the panel only redraws and closes.
@MainActor protocol PanelModel: AnyObject {
    var query: String { get }
    var matches: [DmenuMatch] { get }
    var selectedVisibleIndex: Int? { get }
    var prompt: String { get }
    var windowTitle: String { get }
    /// Pango markup (source/view.c:1760-1762), or nil for no message bar.
    var message: String? { get }
    /// The overlay text beside the entry, or nil for none.
    var selectionOverlay: String? { get }
    /// The highlighted switcher button, or nil without modes.
    var currentMode: Int? { get }

    func displayText(for match: DmenuMatch) -> String
    func state(of match: DmenuMatch) -> DmenuRowState
    /// The file whose Finder icon the row shows, or nil for none.
    func iconPath(for match: DmenuMatch) -> String?
    /// The image file the row shows as itself; it beats `iconPath`.
    func iconImagePath(for match: DmenuMatch) -> String?

    func updateQuery(_ query: String) -> PanelUpdate
    /// Rows streamed in after the panel opened; only dmenu streams.
    func appendRows(_ rows: [Row])
    func selectVisibleIndex(_ index: Int?)
    func moveSelection(by offset: Int)
    func accept() -> PanelUpdate
    /// A keymap action: kb-accept-alt, kb-accept-custom(-alt),
    /// kb-delete-entry or kb-custom-N (source/keyb.c:119-134, 216-291).
    func perform(_ action: KeyAction) -> PanelUpdate
    func cancel() -> PanelUpdate
    /// kb-mode-next (+1) and kb-mode-previous (-1). Without modes
    /// (`currentMode` nil) the keys keep their AppKit behavior.
    func switchMode(by offset: Int) -> PanelUpdate
    /// A switcher button click (source/view.c:1614-1631).
    func switchTo(_ index: Int) -> PanelUpdate
}

/// dmenu's session, which ends with the completion `runDmenuPanel` returns.
@MainActor final class DmenuPanelModel: PanelModel {
    private var session: DmenuSession
    private(set) var completion: DmenuCompletion?

    init(session: DmenuSession) {
        self.session = session
    }

    /// The theme in `base` plus dmenu's flags. A direct `-l` wins over the
    /// theme's lines, which win over the default a message implies; `-b`
    /// already resolved to `location` unless `-location` beat it (ADR 0001 §2).
    func style(base: PanelStyle = PanelStyle()) -> PanelStyle {
        let pipeline = session.pipeline
        var style = base
        style.password = pipeline.password
        style.fixedRows = pipeline.lines ?? base.fixedRows ?? pipeline.fixedRows
        if pipeline.atBottom, style.location == nil { style.location = .south }
        style.markupRows = pipeline.markupRows
        style.ellipsizeMode = pipeline.ellipsizeMode
        // The theme never sets the icon column, so the flag alone decides it,
        // as `runModePanel` does for `-show`.
        style.showIcons = pipeline.showIcons
        return style
    }

    var query: String { session.query }
    var matches: [DmenuMatch] { session.matches }
    var selectedVisibleIndex: Int? { session.selectedVisibleIndex }
    var prompt: String { session.pipeline.prompt }
    var windowTitle: String { session.pipeline.windowTitle }
    var message: String? { session.pipeline.message }
    var selectionOverlay: String? { session.selectionOverlay }
    var currentMode: Int? { nil }

    func displayText(for match: DmenuMatch) -> String { session.displayText(for: match) }
    func state(of match: DmenuMatch) -> DmenuRowState { session.state(of: match) }
    func iconPath(for match: DmenuMatch) -> String? { nil }
    func iconImagePath(for match: DmenuMatch) -> String? { match.row.iconImagePath }

    func updateQuery(_ query: String) -> PanelUpdate {
        complete(session.updateQuery(query)) ?? .reload
    }

    func appendRows(_ rows: [Row]) { session.appendRows(rows) }
    func selectVisibleIndex(_ index: Int?) { session.selectVisibleIndex(index) }
    func moveSelection(by offset: Int) { session.moveSelection(by: offset) }

    /// A refused accept or an `-only-match` cancel keeps the panel as it is.
    func accept() -> PanelUpdate { complete(session.accept()) ?? .none }
    func cancel() -> PanelUpdate { complete(session.cancel()) ?? .none }

    /// A `-multi-select` toggle keeps the panel open, so the ballots, the
    /// moved selection and the count overlay are redrawn.
    func perform(_ action: KeyAction) -> PanelUpdate {
        complete(session.perform(action)) ?? (action == .acceptAlt && session.pipeline.multiSelect ? .reload : .none)
    }

    func switchMode(by offset: Int) -> PanelUpdate { .none }
    func switchTo(_ index: Int) -> PanelUpdate { .none }

    private func complete(_ completion: DmenuCompletion?) -> PanelUpdate? {
        guard let completion else { return nil }
        self.completion = completion
        return .close
    }
}
