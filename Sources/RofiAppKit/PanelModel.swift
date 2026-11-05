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

/// How one panel looks, read once when it is built.
struct PanelStyle {
    /// An `NSSecureTextField` instead of an `NSSearchField`.
    var password = false
    var atBottom = false
    /// Rows the panel is sized around, or nil for the default panel.
    var fixedRows: Int?
    var markupRows = false
    var ellipsizeMode = EllipsizeMode.end
    /// Leads every accessibility label, such as "Dmenu prompt".
    var accessibilityName = "Dmenu"
    /// One switcher button per mode, or nil for no switcher row
    /// (source/view.c:1790-1810).
    var switcherLabels: [String]?
    /// An icon column before the text (`-show-icons`, source/xrmoptions.c:145).
    var showIcons = false
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

    func updateQuery(_ query: String) -> PanelUpdate
    /// Rows streamed in after the panel opened; only dmenu streams.
    func appendRows(_ rows: [Row])
    func selectVisibleIndex(_ index: Int?)
    func moveSelection(by offset: Int)
    func accept() -> PanelUpdate
    /// kb-accept-alt, Shift+Return (source/keyb.c:127-130).
    func acceptAlternate() -> PanelUpdate
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

    var style: PanelStyle {
        let pipeline = session.pipeline
        return PanelStyle(
            password: pipeline.password,
            atBottom: pipeline.atBottom,
            fixedRows: pipeline.fixedRows,
            markupRows: pipeline.markupRows,
            ellipsizeMode: pipeline.ellipsizeMode
        )
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
    func acceptAlternate() -> PanelUpdate {
        complete(session.acceptAlternate()) ?? (session.pipeline.multiSelect ? .reload : .none)
    }

    func switchMode(by offset: Int) -> PanelUpdate { .none }
    func switchTo(_ index: Int) -> PanelUpdate { .none }

    private func complete(_ completion: DmenuCompletion?) -> PanelUpdate? {
        guard let completion else { return nil }
        self.completion = completion
        return .close
    }
}
