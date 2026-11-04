import AppKit
import Dispatch
import RofiCore
import os

/// Runs one synchronous dmenu interaction on the main actor. With `input`,
/// the panel opens at once and rows stream in from what `open` returns.
@MainActor public func runDmenuPanel(
    session: DmenuSession,
    streaming input: (open: @Sendable () -> Int32, separator: UInt8)?
) -> DmenuCompletion {
    let application = NSApplication.shared
    // Regular policy reliably registers this unbundled CLI for activation.
    application.setActivationPolicy(.regular)

    let controller = DmenuPanelController(session: session, input: input)
    let applicationDelegate = DmenuApplicationDelegate(controller: controller)
    application.delegate = applicationDelegate
    withExtendedLifetime(applicationDelegate) {
        application.run()
    }
    application.delegate = nil

    guard let completion = controller.completion else {
        preconditionFailure("dmenu panel stopped without a completion")
    }
    return completion
}

@MainActor private final class DmenuApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller: DmenuPanelController

    init(controller: DmenuPanelController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.present()
        controller.startStreaming()
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { @MainActor [controller] in
            // Return to accessory mode to avoid persistent Dock and menu presence.
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { @MainActor [controller] in
                NSApplication.shared.activate(ignoringOtherApps: true)
                controller.focus()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.focus()
    }
}

@MainActor private final class DmenuPanelController: NSObject {
    private enum Layout {
        static let panelSize = NSSize(width: 640, height: 420)
        static let inset: CGFloat = 12
        static let spacing: CGFloat = 8
    }

    private enum Identifier {
        static let column = NSUserInterfaceItemIdentifier("dmenu-column")
        static let cell = NSUserInterfaceItemIdentifier("dmenu-cell")
    }

    /// What the reader thread has delivered and the main queue has not drained.
    private struct PendingInput: Sendable {
        var rows: [Row] = []
        var ended = false
        var drainScheduled = false
    }

    private var session: DmenuSession
    private let input: (open: @Sendable () -> Int32, separator: UInt8)?
    private let pendingInput = OSAllocatedUnfairLock(initialState: PendingInput())
    private let panel: DmenuPanel
    private let promptLabel = NSTextField(labelWithString: "")
    /// An `NSSearchField`, or under `-password` an `NSSecureTextField`
    /// (bullets, no IME; upstream draws "*"). Output is the real text.
    private let searchField: NSTextField
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = DmenuTableView()
    private let scrollView = NSScrollView()
    private let loadingLabel = NSTextField(labelWithString: "Loading.. ")
    private lazy var searchFieldBesideLoading = searchField.trailingAnchor.constraint(
        equalTo: loadingLabel.leadingAnchor,
        constant: -Layout.spacing
    )
    private var suppressTableSelectionChanges = false
    private(set) var completion: DmenuCompletion?

    init(session: DmenuSession, input: (open: @Sendable () -> Int32, separator: UInt8)?) {
        self.session = session
        self.input = input
        searchField = session.pipeline.password ? NSSecureTextField() : NSSearchField()
        panel = DmenuPanel(
            contentRect: NSRect(origin: .zero, size: Layout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configurePromptLabel()
        configureSearchField()
        configureMessageLabel()
        configureTable()
        configureLoadingLabel()
        configureLayout()
        reloadMatches()
    }

    func present() {
        panel.center()
        if let visibleFrame = panel.screen?.visibleFrame {
            var origin = panel.frame.origin
            // Upstream's `-b` is location 6, bottom center
            // (source/modes/dmenu.c:601-603, source/xcb/view.c:275-278, 309-311, 327-330).
            if session.pipeline.atBottom {
                origin = NSPoint(x: visibleFrame.midX - panel.frame.width / 2, y: visibleFrame.minY)
            }
            // A panel as tall as the screen must not slide under the menu bar.
            origin.y = min(origin.y, visibleFrame.maxY - panel.frame.height)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func startStreaming() {
        guard let input else { return }
        streamRows(
            open: input.open,
            separator: input.separator,
            onRows: { [self] in enqueueInput(rows: $0) },
            onEnd: { [self] in enqueueInput(ended: true) }
        )
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.title = session.pipeline.windowTitle
        panel.setAccessibilityLabel(session.pipeline.windowTitle)
    }

    /// A long prompt truncates instead of squeezing the input.
    private func configurePromptLabel() {
        promptLabel.stringValue = session.pipeline.prompt
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setAccessibilityLabel("Dmenu prompt")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchField() {
        searchField.delegate = self
        searchField.stringValue = session.query
        searchField.setAccessibilityLabel("Dmenu search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Resists compression above the rows constraint, so rows shrink first, but
    /// below window-stay-put, so a message too tall for the panel is clipped.
    /// The message is always Pango markup (source/view.c:1760-1762); invalid
    /// markup shows raw.
    private func configureMessageLabel() {
        let message = session.pipeline.message ?? ""
        if let font = messageLabel.font, let markup = parsePangoMarkup(message) {
            messageLabel.attributedStringValue = markup.attributedString(
                font: font,
                color: .labelColor,
                lineBreakMode: .byWordWrapping
            )
        } else {
            messageLabel.stringValue = message
        }
        messageLabel.isSelectable = false
        messageLabel.preferredMaxLayoutWidth = Layout.panelSize.width - 2 * Layout.inset
        messageLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 495),
            for: .vertical
        )
        messageLabel.setAccessibilityLabel("Dmenu message")
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: Identifier.column)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // The default inset style pads rows by an unexposed amount, which
        // would clip the last row of a panel sized by `-l`.
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = false
        // Like upstream, a visible row stays selected, so Return is predictable.
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityLabel("Dmenu results")
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Upstream's overlay (source/modes/dmenu.c:1059), which follows the entry
    /// in the input bar (source/view.c:1679, 1810-1814).
    private func configureLoadingLabel() {
        loadingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.setAccessibilityLabel("Dmenu loading")
        loadingLabel.isHidden = input == nil
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        guard let contentView = panel.contentView else { return }
        let rows = session.pipeline.fixedRows
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        contentView.addSubview(promptLabel)
        contentView.addSubview(searchField)
        panel.initialFirstResponder = searchField
        contentView.addSubview(scrollView)
        contentView.addSubview(loadingLabel)
        var resultsTop = searchField.bottomAnchor
        if session.pipeline.message != nil {
            contentView.addSubview(messageLabel)
            NSLayoutConstraint.activate([
                messageLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Layout.spacing),
                messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
                messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            ])
            resultsTop = messageLabel.bottomAnchor
        }
        // Full width unless the loading label needs the room, so the label
        // never covers the field's cancel button. Below the label's compression
        // resistance (750), or a long prompt squeezes the label away.
        let searchFieldFullWidth = searchField.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -Layout.inset
        )
        searchFieldFullWidth.priority = NSLayoutConstraint.Priority(700)
        searchFieldBesideLoading.isActive = !loadingLabel.isHidden
        NSLayoutConstraint.activate([
            loadingLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            loadingLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            promptLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.inset),
            searchField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: Layout.spacing),
            searchFieldFullWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualTo: contentView.widthAnchor, multiplier: 0.5),
            scrollView.topAnchor.constraint(equalTo: resultsTop, constant: rows == 0 ? 0 : Layout.spacing),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.inset),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: rows == 0 ? 0 : rowHeight),
        ])
        if let rows {
            fitPanel(toRowsHeight: CGFloat(rows) * rowHeight)
        }
    }

    /// Sizes the panel around `fixedRows`, no taller than the screen. The rows
    /// constraint sits below window-stay-put priority, so at that cap the rows
    /// shrink instead of the window growing. Fixed, like upstream's default
    /// `fixed_num_lines` (config/config.c:101), however few rows match.
    private func fitPanel(toRowsHeight rowsHeight: CGFloat) {
        guard let contentView = panel.contentView else { return }
        let maximumHeight = panel.screen?.visibleFrame.height ?? Layout.panelSize.height
        // The cap also keeps a huge `-l` within Auto Layout's limits.
        let rowsConstraint = scrollView.heightAnchor.constraint(equalToConstant: min(rowsHeight, maximumHeight))
        rowsConstraint.priority = .dragThatCannotResizeWindow
        rowsConstraint.isActive = true
        panel.setContentSize(
            NSSize(
                width: Layout.panelSize.width,
                height: min(contentView.fittingSize.height, maximumHeight)
            ))
    }

    /// Runs on the reader thread. Batches coalesce into one outstanding drain.
    private nonisolated func enqueueInput(rows: [Row] = [], ended: Bool = false) {
        let needsDrain = pendingInput.withLock { pending in
            pending.rows += rows
            pending.ended = pending.ended || ended
            defer { pending.drainScheduled = true }
            return !pending.drainScheduled
        }
        guard needsDrain else { return }
        DispatchQueue.main.async { @MainActor [self] in drainInput() }
    }

    /// Inserts instead of reloading so scrolling and the search field are left
    /// alone, which keeps typing and IME composition undisturbed.
    private func drainInput() {
        let pending = pendingInput.withLock { pending in
            defer { pending = PendingInput() }
            return pending
        }
        let firstNewRow = tableView.numberOfRows
        let selection = session.selectedVisibleIndex
        session.appendRows(pending.rows)
        tableView.insertRows(at: IndexSet(firstNewRow..<session.matches.count), withAnimation: [])
        if session.selectedVisibleIndex != selection {
            syncSelection()
        }
        // The end of input clears the one overlay, even a multi-select count
        // (source/modes/dmenu.c:237-240).
        if pending.ended {
            setOverlay(nil)
        }
    }

    /// Upstream's single overlay slot holds "Loading.. " or the multi-select
    /// count, whichever was set last (source/modes/dmenu.c:936-943, 1058-1060).
    private func setOverlay(_ text: String?) {
        loadingLabel.stringValue = text ?? ""
        loadingLabel.isHidden = text == nil
        searchFieldBesideLoading.isActive = text != nil
    }

    private func reloadMatches() {
        synchronizeTableSelection(reloadData: true)
    }

    private func syncSelection() {
        synchronizeTableSelection(reloadData: false)
    }

    private func synchronizeTableSelection(reloadData: Bool) {
        let wasSuppressed = suppressTableSelectionChanges
        suppressTableSelectionChanges = true
        defer { suppressTableSelectionChanges = wasSuppressed }
        if reloadData {
            tableView.reloadData()
        }
        restoreCoreSelection()
    }

    private func restoreCoreSelection() {
        guard let index = session.selectedVisibleIndex,
            tableView.numberOfRows > index
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func finish(_ completion: DmenuCompletion?) {
        guard self.completion == nil, let completion else { return }
        self.completion = completion
        panel.orderOut(nil)
        NSApplication.shared.stop(nil)
    }
}

extension DmenuPanelController {
    /// A `-multi-select` toggle keeps the panel open, so the ballots, the
    /// moved selection and the count overlay are redrawn.
    fileprivate func acceptAlternate() {
        let overlayBefore = session.selectionOverlay
        if let completion = session.acceptAlternate() {
            finish(completion)
            return
        }
        guard session.pipeline.multiSelect else { return }
        reloadMatches()
        // A refused toggle leaves the count unchanged and must not clear
        // "Loading.. " mid-stream; upstream returns before touching the
        // overlay (source/modes/dmenu.c:908-911).
        if session.selectionOverlay != overlayBefore { setOverlay(session.selectionOverlay) }
    }
}

extension DmenuPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if let editor = searchField.currentEditor() as? NSTextView,
            editor.hasMarkedText()
        {
            return
        }
        let completion = session.updateQuery(searchField.stringValue)
        reloadMatches()
        finish(completion)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift+Return has no binding of its own in the standard key
            // bindings, so it arrives here; it is upstream's kb-accept-alt
            // (source/keyb.c:127-130).
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .control, .option, .command])
            if modifiers == .shift {
                acceptAlternate()
            } else {
                finish(session.accept())
            }
        case #selector(NSResponder.cancelOperation(_:)):
            finish(session.cancel())
        case #selector(NSResponder.moveUp(_:)):
            session.moveSelection(by: -1)
            syncSelection()
        case #selector(NSResponder.moveDown(_:)):
            session.moveSelection(by: 1)
            syncSelection()
        default:
            return false
        }
        return true
    }
}

extension DmenuPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        session.matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: DmenuCell
        if let reused = tableView.makeView(withIdentifier: Identifier.cell, owner: self) as? DmenuCell {
            cell = reused
        } else {
            cell = makeCell()
        }
        let match = session.matches[row]
        let text = session.displayText(for: match)
        // Under -markup-rows the ballot is part of the markup, as upstream
        // marks up the whole formatted row (source/modes/dmenu.c:459-460).
        // Invalid markup shows raw.
        cell.textField?.stringValue = text
        cell.markup = session.pipeline.markupRows ? parsePangoMarkup(text) : nil
        // Active wins over urgent; the -multi-select `.selected` flag is not
        // styled (include/widgets/textbox.h:122, source/widgets/textbox.c:312-315).
        let state = session.state(of: match)
        cell.stateColor = state.contains(.active) ? .systemBlue : state.contains(.urgent) ? .systemRed : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressTableSelectionChanges else { return }
        let selectedRow = tableView.selectedRow
        session.selectVisibleIndex(selectedRow >= 0 ? selectedRow : nil)
    }

    private func makeCell() -> DmenuCell {
        let cell = DmenuCell()
        cell.identifier = Identifier.cell

        let label = NSTextField(labelWithString: "")
        switch session.pipeline.ellipsizeMode {
        case .start: label.lineBreakMode = .byTruncatingHead
        case .middle: label.lineBreakMode = .byTruncatingMiddle
        case .end: label.lineBreakMode = .byTruncatingTail
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

extension DmenuPanelController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(session.cancel())
        return false
    }
}

private final class DmenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws a row's -a/-u color, except on the emphasized cursor row, where the
/// system's highlighted text color keeps it readable on the accent fill.
/// Markup colors win over the state color, but not over the highlight.
private final class DmenuCell: NSTableCellView {
    var stateColor = NSColor.labelColor {
        didSet { applyTextColor() }
    }

    /// The row's parsed markup, drawn instead of the plain `stringValue`.
    var markup: MarkupText? {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    /// Rebuilds a markup row in full: its colors live in the attributed
    /// string, which `textColor` does not restyle.
    private func applyTextColor() {
        guard let textField else { return }
        let highlighted = backgroundStyle == .emphasized
        let color = highlighted ? .alternateSelectedControlTextColor : stateColor
        if let markup, let font = textField.font {
            textField.attributedStringValue = markup.attributedString(
                font: font,
                color: color,
                lineBreakMode: textField.lineBreakMode,
                overridingColors: highlighted
            )
        } else {
            textField.textColor = color
        }
    }
}

private final class DmenuTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
