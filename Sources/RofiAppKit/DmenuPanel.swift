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
    let model = DmenuPanelModel(session: session)
    runPanel(model: model, style: model.style, keymap: session.pipeline.keymap, streaming: input)
    guard let completion = model.completion else {
        preconditionFailure("dmenu panel stopped without a completion")
    }
    return completion
}

/// Runs the panel until its model closes it.
@MainActor func runPanel(
    model: any PanelModel,
    style: PanelStyle,
    keymap: Keymap,
    streaming input: (open: @Sendable () -> Int32, separator: UInt8)?
) {
    let application = NSApplication.shared
    // Regular policy reliably registers this unbundled CLI for activation.
    application.setActivationPolicy(.regular)

    let controller = PanelController(model: model, style: style, keymap: keymap, input: input)
    let applicationDelegate = PanelApplicationDelegate(controller: controller)
    application.delegate = applicationDelegate
    withExtendedLifetime(applicationDelegate) {
        application.run()
    }
    application.delegate = nil
}

@MainActor private final class PanelApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller: PanelController

    init(controller: PanelController) {
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

@MainActor private final class PanelController: NSObject {
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

    private let model: any PanelModel
    private let style: PanelStyle
    private let keymap: Keymap
    private let input: (open: @Sendable () -> Int32, separator: UInt8)?
    private let pendingInput = OSAllocatedUnfairLock(initialState: PendingInput())
    private let panel: DmenuPanel
    private let promptLabel = NSTextField(labelWithString: "")
    /// An `NSSearchField`, or under `-password` an `NSSecureTextField`
    /// (bullets, no IME; upstream draws "*"). Output is the real text.
    private let searchField: NSTextField
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// The message on display, nil for a hidden message bar, or `.none`
    /// before the first update.
    private var shownMessage: String?? = .none
    private lazy var resultsBelowSearch = scrollView.topAnchor.constraint(
        equalTo: searchField.bottomAnchor,
        constant: style.fixedRows == 0 ? 0 : Layout.spacing
    )
    private lazy var resultsBelowMessage = scrollView.topAnchor.constraint(
        equalTo: messageLabel.bottomAnchor,
        constant: style.fixedRows == 0 ? 0 : Layout.spacing
    )
    /// The `-sidebar-mode` row, one segment per mode.
    private let switcherControl: NSSegmentedControl?
    private let tableView = DmenuTableView()
    private let scrollView = NSScrollView()
    private let loadingLabel = NSTextField(labelWithString: "Loading.. ")
    private lazy var searchFieldBesideLoading = searchField.trailingAnchor.constraint(
        equalTo: loadingLabel.leadingAnchor,
        constant: -Layout.spacing
    )
    private var suppressTableSelectionChanges = false
    private var finished = false
    /// Finder icons by path, fetched as rows are first shown.
    /// ponytail: never evicted; one image per path shown in this run.
    private var icons: [String: NSImage] = [:]

    init(
        model: any PanelModel, style: PanelStyle, keymap: Keymap,
        input: (open: @Sendable () -> Int32, separator: UInt8)?
    ) {
        self.model = model
        self.style = style
        self.keymap = keymap
        self.input = input
        searchField = style.password ? NSSecureTextField() : NSSearchField()
        switcherControl = style.switcherLabels.map {
            NSSegmentedControl(labels: $0, trackingMode: .selectOne, target: nil, action: nil)
        }
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
        configureSwitcher()
        configureLayout()
        reloadMatches()
    }

    func present() {
        panel.center()
        if let visibleFrame = panel.screen?.visibleFrame {
            var origin = panel.frame.origin
            // Upstream's `-b` is location 6, bottom center
            // (source/modes/dmenu.c:601-603, source/xcb/view.c:275-278, 309-311, 327-330).
            if style.atBottom {
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
        panel.keyHandler = { [unowned self] in handleKey($0) }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // A borderless panel has no title bar; the margins and prompt are the drag handle.
        // ponytail: position resets on every launch, add setFrameAutosaveName if it should persist.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        updateTitle()
    }

    /// The prompt and title follow the current mode (source/view.c:2150-2160).
    private func updateTitle() {
        promptLabel.stringValue = model.prompt
        panel.title = model.windowTitle
        panel.setAccessibilityLabel(model.windowTitle)
    }

    /// A long prompt truncates instead of squeezing the input.
    private func configurePromptLabel() {
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setAccessibilityLabel("\(style.accessibilityName) prompt")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchField() {
        searchField.delegate = self
        searchField.stringValue = model.query
        searchField.setAccessibilityLabel("\(style.accessibilityName) search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Resists compression above the rows constraint, so rows shrink first, but
    /// below window-stay-put, so a message too tall for the panel is clipped.
    private func configureMessageLabel() {
        messageLabel.isSelectable = false
        messageLabel.preferredMaxLayoutWidth = Layout.panelSize.width - 2 * Layout.inset
        messageLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 495),
            for: .vertical
        )
        messageLabel.setAccessibilityLabel("\(style.accessibilityName) message")
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The message bar shows only with a message, which a mode may change
    /// after every result (source/view.c:230-240, 808). The message is always
    /// Pango markup (source/view.c:1760-1762); invalid markup shows raw.
    private func updateMessage() {
        let message = model.message
        guard message != shownMessage else { return }
        shownMessage = message
        if let message {
            if messageLabel.superview == nil, let contentView = panel.contentView {
                contentView.addSubview(messageLabel)
                NSLayoutConstraint.activate([
                    messageLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Layout.spacing),
                    messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
                    messageLabel.trailingAnchor.constraint(
                        equalTo: contentView.trailingAnchor, constant: -Layout.inset),
                ])
            }
            if let font = messageLabel.font, let markup = parsePangoMarkup(message) {
                messageLabel.attributedStringValue = markup.attributedString(
                    font: font,
                    color: .labelColor,
                    lineBreakMode: .byWordWrapping
                )
            } else {
                messageLabel.stringValue = message
            }
        }
        messageLabel.isHidden = message == nil
        resultsBelowSearch.isActive = message == nil
        resultsBelowMessage.isActive = message != nil
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
        tableView.setAccessibilityLabel("\(style.accessibilityName) results")
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
        loadingLabel.setAccessibilityLabel("\(style.accessibilityName) loading")
        loadingLabel.isHidden = input == nil
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Upstream's mode-switcher sits below the list with one equal-width
    /// button per mode (source/view.c:1668, 1795-1806). It never takes focus,
    /// so typing stays in the entry.
    private func configureSwitcher() {
        guard let switcherControl else { return }
        switcherControl.selectedSegment = model.currentMode ?? -1
        switcherControl.segmentDistribution = .fillEqually
        switcherControl.refusesFirstResponder = true
        switcherControl.target = self
        switcherControl.action = #selector(switcherClicked(_:))
        switcherControl.setAccessibilityLabel("\(style.accessibilityName) modes")
        switcherControl.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        guard let contentView = panel.contentView else { return }
        let rows = style.fixedRows
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        contentView.addSubview(promptLabel)
        contentView.addSubview(searchField)
        panel.initialFirstResponder = searchField
        contentView.addSubview(scrollView)
        contentView.addSubview(loadingLabel)
        updateMessage()
        var resultsBottom = scrollView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -Layout.inset)
        if let switcherControl {
            contentView.addSubview(switcherControl)
            NSLayoutConstraint.activate([
                switcherControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
                switcherControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
                switcherControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.inset),
            ])
            resultsBottom = scrollView.bottomAnchor.constraint(
                equalTo: switcherControl.topAnchor, constant: -Layout.spacing)
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
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            resultsBottom,
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
        let selection = model.selectedVisibleIndex
        model.appendRows(pending.rows)
        tableView.insertRows(at: IndexSet(firstNewRow..<model.matches.count), withAnimation: [])
        if model.selectedVisibleIndex != selection {
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
        guard let index = model.selectedVisibleIndex,
            tableView.numberOfRows > index
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Runs one model action and redraws what it changed.
    private func perform(_ action: (any PanelModel) -> PanelUpdate) {
        guard !finished else { return }
        let overlayBefore = model.selectionOverlay
        switch action(model) {
        case .none:
            return
        case .close:
            finished = true
            panel.orderOut(nil)
            NSApplication.shared.stop(nil)
        case .reload:
            reloadMatches()
            // A refused toggle leaves the count unchanged and must not clear
            // "Loading.. " mid-stream; upstream returns before touching the
            // overlay (source/modes/dmenu.c:908-911).
            if model.selectionOverlay != overlayBefore { setOverlay(model.selectionOverlay) }
            refreshChrome()
        }
    }

    /// After a mode's result or a switch: prompt, title, message, the
    /// highlighted switcher button, and the query a mode rewrote, with the
    /// cursor at the end (source/rofi.c:243-251, source/view.c:2150-2177).
    private func refreshChrome() {
        updateTitle()
        updateMessage()
        if let currentMode = model.currentMode {
            switcherControl?.selectedSegment = currentMode
        }
        if searchField.stringValue != model.query {
            searchField.stringValue = model.query
            searchField.currentEditor()?.selectedRange = NSRange(location: (model.query as NSString).length, length: 0)
        }
    }

    /// A key-down bound in the keymap runs its action before the field editor
    /// sees it, which would type Alt+1 as "¡" and send Control+Return as
    /// insertLineBreak:. An IME composition keeps every key.
    private func handleKey(_ event: NSEvent) -> Bool {
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        guard let action = keymap.action(for: event) else { return false }
        perform { $0.perform(action) }
        return true
    }

    @objc private func switcherClicked(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        perform { $0.switchTo(index) }
    }
}

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if let editor = searchField.currentEditor() as? NSTextView,
            editor.hasMarkedText()
        {
            return
        }
        let query = searchField.stringValue
        perform { $0.updateQuery(query) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        // Shift+Return, kb-accept-alt, is taken by the keymap before it gets here.
        case #selector(NSResponder.insertNewline(_:)):
            perform { $0.accept() }
        case #selector(NSResponder.cancelOperation(_:)):
            perform { $0.cancel() }
        case #selector(NSResponder.moveUp(_:)):
            model.moveSelection(by: -1)
            syncSelection()
        case #selector(NSResponder.moveDown(_:)):
            model.moveSelection(by: 1)
            syncSelection()
        // kb-mode-next is Control+Tab and kb-mode-previous Control+Shift+Tab
        // (source/keyb.c:135-142; Shift+Right/Left stay text selection). The
        // field editor gets them as these key-view selectors: observed with
        // System Events key code 48 on macOS 15, while plain Tab and Shift+Tab
        // arrive as insertTab: and insertBacktab:. dmenu has no modes and
        // leaves them to AppKit.
        case #selector(NSWindow.selectNextKeyView(_:)), #selector(NSWindow.selectPreviousKeyView(_:)):
            let offset = commandSelector == #selector(NSWindow.selectNextKeyView(_:)) ? 1 : -1
            guard model.currentMode != nil else { return false }
            perform { $0.switchMode(by: offset) }
        default:
            return false
        }
        return true
    }
}

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: DmenuCell
        if let reused = tableView.makeView(withIdentifier: Identifier.cell, owner: self) as? DmenuCell {
            cell = reused
        } else {
            cell = makeCell()
        }
        let match = model.matches[row]
        let text = model.displayText(for: match)
        // Under -markup-rows the ballot is part of the markup, as upstream
        // marks up the whole formatted row (source/modes/dmenu.c:459-460).
        // Invalid markup shows raw.
        cell.textField?.stringValue = text
        cell.markup = style.markupRows ? parsePangoMarkup(text) : nil
        // Active wins over urgent; the -multi-select `.selected` flag is not
        // styled (include/widgets/textbox.h:122, source/widgets/textbox.c:312-315).
        let state = model.state(of: match)
        cell.stateColor = state.contains(.active) ? .systemBlue : state.contains(.urgent) ? .systemRed : .labelColor
        cell.imageView?.image = model.iconPath(for: match).map(icon(forFile:))
        return cell
    }

    /// Only rows the table vends a cell for are looked up.
    private func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressTableSelectionChanges else { return }
        let selectedRow = tableView.selectedRow
        model.selectVisibleIndex(selectedRow >= 0 ? selectedRow : nil)
    }

    private func makeCell() -> DmenuCell {
        let cell = DmenuCell()
        cell.identifier = Identifier.cell

        let label = NSTextField(labelWithString: "")
        switch style.ellipsizeMode {
        case .start: label.lineBreakMode = .byTruncatingHead
        case .middle: label.lineBreakMode = .byTruncatingMiddle
        case .end: label.lineBreakMode = .byTruncatingTail
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        guard style.showIcons else {
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
            return cell
        }
        // A square as tall as the row, before the text.
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.topAnchor.constraint(equalTo: cell.topAnchor),
            icon.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            icon.widthAnchor.constraint(equalTo: icon.heightAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
        ])
        return cell
    }
}

extension PanelController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        perform { $0.cancel() }
        return false
    }
}

private final class DmenuPanel: NSPanel {
    /// Sees every key-down first; true consumes it.
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

extension KeyChord {
    /// The chord of a key-down: `charactersIgnoringModifiers`, which keeps
    /// Shift ("!" for Shift+1), plus Control, Shift, Option and Command.
    init?(event: NSEvent) {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        let flags = event.modifierFlags
        var modifiers: KeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(key: key, modifiers: modifiers)
    }
}

extension Keymap {
    func action(for event: NSEvent) -> KeyAction? {
        KeyChord(event: event).flatMap(action(for:))
    }
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
