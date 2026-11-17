import AppKit
import RofiCore

@MainActor func prepareErrorDialogMessage(
    _ message: String,
    markup: Bool,
    font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
    color: NSColor = .labelColor
) -> NSAttributedString {
    if markup, let parsed = parsePangoMarkup(message) {
        return parsed.attributedString(font: font, color: color, lineBreakMode: .byWordWrapping)
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(
        string: message,
        attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    )
}

@MainActor public func runErrorDialog(_ message: String, markup: Bool) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Error"
    alert.accessoryView = errorDialogMessageField(prepareErrorDialogMessage(message, markup: markup))
    alert.addButton(withTitle: "OK")

    application.activate(ignoringOtherApps: true)
    alert.runModal()
}

@MainActor private func errorDialogMessageField(_ message: NSAttributedString) -> NSTextField {
    let width: CGFloat = 420
    let messageBounds = message.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let field = NSTextField(
        frame: NSRect(x: 0, y: 0, width: width, height: max(20, ceil(messageBounds.height)))
    )
    field.isEditable = false
    field.isSelectable = true
    field.isBezeled = false
    field.drawsBackground = false
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.attributedStringValue = message
    return field
}
