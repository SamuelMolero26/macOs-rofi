import AppKit
import Dispatch
import RofiCore
import os

/// Runs one synchronous dmenu interaction on the main actor. With `input`,
/// the panel opens at once and rows stream in from that file descriptor.
@MainActor public func runDmenuPanel(
    session: DmenuSession,
    streaming input: (fileDescriptor: Int32, separator: UInt8)? = nil
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
    private let input: (fileDescriptor: Int32, separator: UInt8)?
    private let pendingInput = OSAllocatedUnfairLock(initialState: PendingInput())
    private let panel: DmenuPanel
    private let searchField = NSSearchField()
    private let tableView = DmenuTableView()
    private let scrollView = NSScrollView()
    private let loadingLabel = NSTextField(labelWithString: "Loading.. ")
    private var suppressTableSelectionChanges = false
    private(set) var completion: DmenuCompletion?

    init(session: DmenuSession, input: (fileDescriptor: Int32, separator: UInt8)?) {
        self.session = session
        self.input = input
        panel = DmenuPanel(
            contentRect: NSRect(origin: .zero, size: Layout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureSearchField()
        configureTable()
        configureLoadingLabel()
        configureLayout()
        reloadMatches()
    }

    func present() {
        panel.center()
        panel.orderFrontRegardless()
    }

    func startStreaming() {
        guard let input else { return }
        streamRows(
            fileDescriptor: input.fileDescriptor,
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
        panel.title = "Rofi dmenu"
        panel.setAccessibilityLabel("Rofi dmenu")
    }

    private func configureSearchField() {
        searchField.delegate = self
        searchField.stringValue = session.query
        searchField.setAccessibilityLabel("Dmenu search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: Identifier.column)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
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

    /// Upstream's overlay (source/modes/dmenu.c:1059), drawn over the results.
    private func configureLoadingLabel() {
        loadingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.drawsBackground = true
        loadingLabel.backgroundColor = .windowBackgroundColor
        loadingLabel.setAccessibilityLabel("Dmenu loading")
        loadingLabel.isHidden = input == nil
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        guard let contentView = panel.contentView else { return }
        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(loadingLabel)
        NSLayoutConstraint.activate([
            loadingLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            loadingLabel.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.inset),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Layout.spacing),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.inset),
        ])
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
        if pending.ended {
            loadingLabel.isHidden = true
        }
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

extension DmenuPanelController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        if let editor = searchField.currentEditor() as? NSTextView,
           editor.hasMarkedText() {
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
            finish(session.accept())
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
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: Identifier.cell, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = makeCell()
        }
        cell.textField?.stringValue = session.matches[row].row.text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressTableSelectionChanges else { return }
        let selectedRow = tableView.selectedRow
        session.selectVisibleIndex(selectedRow >= 0 ? selectedRow : nil)
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Identifier.cell

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
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

private final class DmenuTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
