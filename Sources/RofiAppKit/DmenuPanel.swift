import AppKit
import RofiCore

/// Runs one synchronous dmenu interaction on the main actor.
@MainActor public func runDmenuPanel(session: DmenuSession) -> DmenuCompletion {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let controller = DmenuPanelController(session: session)
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
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        controller.present()
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

    private var session: DmenuSession
    private let panel: DmenuPanel
    private let searchField = NSSearchField()
    private let tableView = DmenuTableView()
    private let scrollView = NSScrollView()
    private var suppressTableSelectionChanges = false
    private(set) var completion: DmenuCompletion?

    init(session: DmenuSession) {
        self.session = session
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
        configureLayout()
        reloadMatches()
    }

    func present() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
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
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel("Dmenu results")
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        guard let contentView = panel.contentView else { return }
        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Layout.inset),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Layout.spacing),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Layout.inset),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Layout.inset),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Layout.inset),
        ])
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
