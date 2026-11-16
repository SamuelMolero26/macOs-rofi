import AppKit
import Dispatch
import RofiCore
import os

/// Runs one synchronous dmenu interaction on the main actor. With `input`,
/// the panel opens at once and rows stream in from what `open` returns.
/// `style` carries the resolved theme.
@MainActor public func runDmenuPanel(
    session: DmenuSession,
    style: PanelStyle = PanelStyle(),
    placement: PanelPlacement = PanelPlacement(),
    streaming input: (open: @Sendable () -> Int32, separator: UInt8)?
) -> DmenuCompletion {
    let model = DmenuPanelModel(session: session)
    runPanel(
        model: model, style: model.style(base: style), keymap: session.pipeline.keymap, placement: placement,
        streaming: input)
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
    placement: PanelPlacement,
    streaming input: (open: @Sendable () -> Int32, separator: UInt8)?
) {
    let application = NSApplication.shared
    // Regular policy reliably registers this unbundled CLI for activation.
    application.setActivationPolicy(.regular)

    // Built before `run` activates rofi, while the launching app is still
    // frontmost (ADR 0002 §3).
    let controller = PanelController(model: model, style: style, keymap: keymap, placement: placement, input: input)
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
        static let panelHeight: CGFloat = 420
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
    private let placement: PanelPlacement
    /// Where `-monitor` puts the panel, or nil without screens.
    private let workArea: WorkArea?
    /// The theme's width, padding and border in points for the work area.
    private let metrics: PanelMetrics
    /// Content edges: border plus padding.
    private let insets: NSEdgeInsets
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
    /// The last keymap action was kb-row-tab (source/view.c:640).
    private var lastActionWasRowTab = false
    /// The keymap's local key-down monitor while the panel is open.
    private var keyMonitor: Any?
    /// click-to-exit's global mouse-down monitor while the panel is open.
    private var clickMonitor: Any?
    /// Finder icons by path, fetched as rows are first shown.
    /// ponytail: never evicted; one image per path shown in this run.
    private var icons: [String: NSImage] = [:]

    init(
        model: any PanelModel, style: PanelStyle, keymap: Keymap, placement: PanelPlacement,
        input: (open: @Sendable () -> Int32, separator: UInt8)?
    ) {
        self.model = model
        self.style = style
        self.placement = placement
        let screens = NSScreen.screens.map {
            Screen(name: $0.localizedName, frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let resolved = placement.workArea(
            screens: screens, mouse: NSEvent.mouseLocation, frontWindow: frontmostWindowBounds)
        if let warning = resolved?.warning {
            FileHandle.standardError.write(Data("rofi: warning: \(warning)\n".utf8))
        }
        workArea = resolved?.area
        metrics = PanelMetrics(style: style, visibleSize: workArea?.frame.size ?? .zero)
        insets = metrics.contentInsets
        self.keymap = keymap
        self.input = input
        searchField = style.password ? NSSecureTextField() : NSSearchField()
        switcherControl = style.switcherLabels.map {
            NSSegmentedControl(labels: $0, trackingMode: .selectOne, target: nil, action: nil)
        }
        panel = DmenuPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: metrics.width, height: Layout.panelHeight)),
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
        if let workArea {
            // Upstream's `-b` is location 6, bottom center, which resolves to
            // `south` (source/modes/dmenu.c:601-603); `-3` forces north west.
            var origin = panelOrigin(
                location: workArea.location ?? style.location, size: panel.frame.size, area: workArea.frame,
                xOffset: placement.xOffset, yOffset: placement.yOffset)
            // A panel as tall as the screen must not slide under the menu bar.
            origin.y = min(origin.y, workArea.frame.maxY - panel.frame.height)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        installKeyMonitor()
    }

    /// Bound key-downs run their action before the window or the field
    /// editor sees them: the field editor would type Alt+1 as "¡", and AppKit
    /// swallows Control+Return before `NSWindow.sendEvent` (observed on
    /// macOS 15), while a local monitor still gets it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            let consumed = MainActor.assumeIsolated {
                guard let action = keymapAction(for: event, in: panel, keymap: keymap) else { return false }
                let repeatedTab = lastActionWasRowTab
                lastActionWasRowTab = action == .rowTab
                if action.isNavigation {
                    perform { $0.navigate(action, pageSize: visibleRowCount, repeatedTab: repeatedTab) }
                    if !finished { syncSelection() }
                } else {
                    perform { $0.perform(action) }
                }
                return true
            }
            return consumed ? nil : event
        }
        // click-to-exit: with no pointer grab, a click that reaches another
        // app is the click outside the window (source/xcb/view.c:864-871).
        // Global mouse monitors need no permission; focus theft alone does
        // not cancel (ADR 0002 §5).
        guard placement.clickToExit else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [unowned self] _ in
            MainActor.assumeIsolated { perform { $0.cancel() } }
        }
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
        // A borderless panel has no title bar; the margins and prompt are the drag handle.
        // ponytail: position resets on every launch, add setFrameAutosaveName if it should persist.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        // A translucent theme background shows what is behind the panel.
        panel.isOpaque = (style.backgroundColor?.alphaComponent ?? 1) >= 1
        panel.backgroundColor = style.backgroundColor ?? .windowBackgroundColor
        let border = metrics.border
        if border.top > 0 || border.left > 0 || border.bottom > 0 || border.right > 0 {
            panel.contentView = PanelBorderView(widths: border, color: style.borderColor ?? .separatorColor)
        }
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
        if let font = style.font { promptLabel.font = font }
        if let color = style.textColor { promptLabel.textColor = color }
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setAccessibilityLabel("\(style.accessibilityName) prompt")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSearchField() {
        searchField.delegate = self
        if let font = style.font { searchField.font = font }
        if let color = style.textColor { searchField.textColor = color }
        searchField.stringValue = model.query
        searchField.setAccessibilityLabel("\(style.accessibilityName) search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Resists compression above the rows constraint, so rows shrink first, but
    /// below window-stay-put, so a message too tall for the panel is clipped.
    private func configureMessageLabel() {
        messageLabel.isSelectable = false
        messageLabel.preferredMaxLayoutWidth = metrics.width - insets.left - insets.right
        if let font = style.font { messageLabel.font = font }
        if let color = style.textColor { messageLabel.textColor = color }
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
                    messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
                    messageLabel.trailingAnchor.constraint(
                        equalTo: contentView.trailingAnchor, constant: -insets.right),
                ])
            }
            if let font = messageLabel.font, let markup = parsePangoMarkup(message) {
                messageLabel.attributedStringValue = markup.attributedString(
                    font: font,
                    color: style.textColor ?? .labelColor,
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
        // A themed font sets the row height; a themed background shows through.
        if let font = style.font { tableView.rowHeight = max(tableView.rowHeight, lineHeight(of: font) + 2) }
        if style.backgroundColor != nil { tableView.backgroundColor = .clear }
        tableView.allowsMultipleSelection = false
        // Like upstream, a visible row stays selected, so Return is predictable.
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityLabel("\(style.accessibilityName) results")
        tableView.dataSource = self
        tableView.delegate = self
        // me-accept-entry is a primary double click (source/keyb.c:379-383).
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))

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
        if let font = style.font { switcherControl.font = font }
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
            equalTo: contentView.bottomAnchor, constant: -insets.bottom)
        if let switcherControl {
            contentView.addSubview(switcherControl)
            NSLayoutConstraint.activate([
                switcherControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
                switcherControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
                switcherControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom),
            ])
            resultsBottom = scrollView.bottomAnchor.constraint(
                equalTo: switcherControl.topAnchor, constant: -Layout.spacing)
        }
        // Full width unless the loading label needs the room, so the label
        // never covers the field's cancel button. Below the label's compression
        // resistance (750), or a long prompt squeezes the label away.
        let searchFieldFullWidth = searchField.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -insets.right
        )
        searchFieldFullWidth.priority = NSLayoutConstraint.Priority(700)
        searchFieldBesideLoading.isActive = !loadingLabel.isHidden
        NSLayoutConstraint.activate([
            loadingLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
            loadingLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
            promptLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
            searchField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: Layout.spacing),
            searchFieldFullWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualTo: contentView.widthAnchor, multiplier: 0.5),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
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
        let maximumHeight = workArea?.frame.height ?? Layout.panelHeight
        // The cap also keeps a huge `-l` within Auto Layout's limits.
        let rowsConstraint = scrollView.heightAnchor.constraint(equalToConstant: min(rowsHeight, maximumHeight))
        rowsConstraint.priority = .dragThatCannotResizeWindow
        rowsConstraint.isActive = true
        panel.setContentSize(
            NSSize(
                width: metrics.width,
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
            for monitor in [keyMonitor, clickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
            clickMonitor = nil
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

    @objc private func switcherClicked(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        perform { $0.switchTo(index) }
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        model.selectVisibleIndex(row)
        perform { $0.accept() }
    }

    /// Whole rows in view: kb-page-prev/next's step.
    private var visibleRowCount: Int {
        Int(scrollView.contentView.bounds.height / (tableView.rowHeight + tableView.intercellSpacing.height))
    }
}

/// The frontmost app's topmost normal window in CGWindowList's top-left
/// coordinates. Bounds, owner and layer need no permission; titles are never
/// read (ADR 0002 §4).
@MainActor func frontmostWindowBounds() -> CGRect? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
        let window = windows.first(where: {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        }),
        let bounds = window[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
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
        // A script's markup-rows header sets the `.markup` flag instead.
        let state = model.state(of: match)
        cell.textField?.stringValue = text
        cell.markup = style.markupRows || state.contains(.markup) ? parsePangoMarkup(text) : nil
        let kind = rowKind(state)
        let native: NSColor = kind == .active ? .systemBlue : kind == .urgent ? .systemRed : .labelColor
        cell.stateColor = style.rowTextColor(kind: kind, variant: rowVariant(row)) ?? native
        cell.selectedColor = style.rowTextColor(kind: kind, variant: .selected) ?? .alternateSelectedControlTextColor
        if let path = model.iconImagePath(for: match) {
            cell.imageView?.image = icon(forFile: path, asImage: true)
        } else {
            cell.imageView?.image = model.iconPath(for: match).map { icon(forFile: $0, asImage: false) }
        }
        return cell
    }

    /// Themed row fills; without them the row view draws natively.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let kind = rowKind(model.state(of: model.matches[row]))
        let fill = style.rowBackgroundColor(kind: kind, variant: rowVariant(row))
        let selection = style.rowBackgroundColor(kind: kind, variant: .selected)
        guard fill != nil || selection != nil else { return nil }
        let rowView = PanelRowView()
        rowView.fillColor = fill
        rowView.selectionColor = selection
        return rowView
    }

    /// Active wins over urgent; the -multi-select `.selected` flag is not
    /// styled (include/widgets/textbox.h:122, source/widgets/textbox.c:312-315).
    private func rowKind(_ state: DmenuRowState) -> PanelRowKind {
        state.contains(.active) ? .active : state.contains(.urgent) ? .urgent : .normal
    }

    /// Upstream alternates from the second visible row.
    private func rowVariant(_ row: Int) -> PanelRowVariant {
        row % 2 == 1 ? .alternate : .plain
    }

    /// Only rows the table vends a cell for are looked up. Image icons are
    /// keyed apart (a path never holds NUL) so a file browser row for the
    /// same file keeps its Finder icon.
    private func icon(forFile path: String, asImage: Bool) -> NSImage {
        let key = asImage ? "\0" + path : path
        if let icon = icons[key] { return icon }
        let icon = rowIcon(forFile: path, asImage: asImage)
        icons[key] = icon
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
        if let font = style.font { label.font = font }
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The keymap action a key-down in `panel` triggers, or nil to pass the event
/// on: another window's event, an unbound chord, or a key during an IME
/// composition.
@MainActor func keymapAction(for event: NSEvent, in panel: NSWindow, keymap: Keymap) -> KeyAction? {
    guard event.window === panel else { return nil }
    if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return nil }
    return keymap.action(for: event)
}

/// The image at `path` when `asImage` and it loads, else the file's Finder
/// icon, so a script's `.app` icon path still shows the app's icon.
@MainActor func rowIcon(forFile path: String, asImage: Bool) -> NSImage {
    (asImage ? NSImage(contentsOfFile: path) : nil) ?? NSWorkspace.shared.icon(forFile: path)
}

extension KeyChord {
    /// The chord of a key-down: its key plus Control, Shift, Option and
    /// Command. `charactersIgnoringModifiers` may or may not fold Shift into
    /// a symbol (real Alt+Shift+1 reports "1"), so a printable non-letter key
    /// takes Shift explicitly ("!", upstream's `exclam`). Letters, control
    /// characters and function keys (U+F700-U+F8FF; Shift+forward delete
    /// would turn into U+007F) keep `charactersIgnoringModifiers`.
    init?(event: NSEvent) {
        guard event.type == .keyDown, var key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        let flags = event.modifierFlags
        if flags.contains(.shift), let char = key.first, key.count == 1, !char.isLetter,
            char.unicodeScalars.allSatisfy({ ![.control, .privateUse].contains($0.properties.generalCategory) })
        {
            key = event.characters(byApplyingModifiers: .shift) ?? key
        }
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

/// Draws a row's -a/-u or themed color, except on the emphasized cursor row,
/// where `selectedColor` (the system's highlighted text color unless themed)
/// keeps it readable on the selection fill.
/// Markup colors win over the state color, but not over the highlight.
private final class DmenuCell: NSTableCellView {
    var stateColor = NSColor.labelColor {
        didSet { applyTextColor() }
    }

    var selectedColor = NSColor.alternateSelectedControlTextColor {
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
        let color = highlighted ? selectedColor : stateColor
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

/// A row with the theme's fill and selection colors, or the native ones.
private final class PanelRowView: NSTableRowView {
    var fillColor: NSColor?
    var selectionColor: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        guard let fillColor else { return super.drawBackground(in: dirtyRect) }
        fillColor.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let selectionColor else { return super.drawSelection(in: dirtyRect) }
        selectionColor.setFill()
        bounds.fill()
    }
}

/// The panel's content view under a themed `border`: solid edges of their
/// own widths, which a layer border cannot draw.
private final class PanelBorderView: NSView {
    private let widths: NSEdgeInsets
    private let color: NSColor

    init(widths: NSEdgeInsets, color: NSColor) {
        self.widths = widths
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: 0, y: bounds.maxY - widths.top, width: bounds.width, height: widths.top).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: widths.bottom).fill()
        NSRect(x: 0, y: 0, width: widths.left, height: bounds.height).fill()
        NSRect(x: bounds.maxX - widths.right, y: 0, width: widths.right, height: bounds.height).fill()
    }
}
