import AppKit
import RofiCore
import Testing

@testable import RofiAppKit

// The panel reads a key-down as `charactersIgnoringModifiers` plus the
// Control/Shift/Option/Command flags and asks the keymap for its action.
// Key codes are US ANSI: 18 is "1", 36 Return, 117 forward delete.
@MainActor @Suite struct PanelKeyTests {
    private func keyDown(
        _ characters: String, _ ignoringModifiers: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16,
        type: NSEvent.EventType = .keyDown, windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: false,
            keyCode: keyCode)!
    }

    // Alt+1 types "¡" on a US layout; the keymap sees "1".
    @Test func altOneIsCustomOne() {
        let event = keyDown("¡", "1", .option, keyCode: 18)

        #expect(KeyChord(event: event) == KeyChord(key: "1", modifiers: .option))
        #expect(Keymap().action(for: event) == .customKey(1))
    }

    // Real Alt+Shift+1 may report "1" ignoring modifiers; Shift applied to
    // the key gives "!", upstream's `Alt+exclam`.
    @Test func altShiftOneIsCustomElevenWhetherOrNotShiftIsFolded() {
        #expect(Keymap().action(for: keyDown("⁄", "1", [.option, .shift], keyCode: 18)) == .customKey(11))
        #expect(Keymap().action(for: keyDown("⁄", "!", [.option, .shift], keyCode: 18)) == .customKey(11))
    }

    @Test func returnChordsFollowTheKeymap() {
        #expect(Keymap().action(for: keyDown("\r", "\r", .control, keyCode: 36)) == .acceptCustom)
        #expect(Keymap().action(for: keyDown("\r", "\r", [.control, .shift], keyCode: 36)) == .acceptCustomAlt)
        #expect(Keymap().action(for: keyDown("\r", "\r", .shift, keyCode: 36)) == .acceptAlt)
        #expect(Keymap().action(for: keyDown("\r", "\r", [], keyCode: 36)) == nil, "plain Return stays kb-accept-entry")
    }

    // Shift applied to forward delete gives U+007F; function keys keep
    // `charactersIgnoringModifiers`.
    @Test func shiftForwardDeleteIsDeleteEntry() {
        #expect(Keymap().action(for: keyDown("\u{F728}", "\u{F728}", .shift, keyCode: 117)) == .deleteEntry)
    }

    // Caps Lock, the numeric pad and function-key flags are not modifiers.
    @Test func otherFlagsAreIgnored() {
        let event = keyDown("\u{F728}", "\u{F728}", [.shift, .function, .numericPad, .capsLock], keyCode: 117)

        #expect(Keymap().action(for: event) == .deleteEntry)
    }

    @Test func keyUpIsNoChord() {
        #expect(KeyChord(event: keyDown("¡", "1", .option, keyCode: 18, type: .keyUp)) == nil)
    }

    // The local monitor only consumes the panel's own bound key-downs.
    @Test func monitorConsumesOnlyThePanelsBoundKeys() {
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        defer { panel.close() }
        let altOne = keyDown("¡", "1", .option, keyCode: 18, windowNumber: panel.windowNumber)

        #expect(altOne.window === panel)
        #expect(keymapAction(for: altOne, in: panel, keymap: Keymap()) == .customKey(1))
        #expect(keymapAction(for: keyDown("¡", "1", .option, keyCode: 18), in: panel, keymap: Keymap()) == nil)
        let plainOne = keyDown("1", "1", [], keyCode: 18, windowNumber: panel.windowNumber)
        #expect(keymapAction(for: plainOne, in: panel, keymap: Keymap()) == nil)
    }

    // rofi has no main menu, so the panel itself maps the Edit menu's
    // Command shortcuts onto the search field. Key codes: 0 "a", 6 "z".
    @Test func commandShortcutsEditTheSearchField() throws {
        let panel = DmenuPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        defer { panel.close() }
        let field = NSTextField()
        panel.contentView?.addSubview(field)
        field.stringValue = "abc"
        #expect(panel.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 3, length: 0)
        let command = { (key: String, flags: NSEvent.ModifierFlags, code: UInt16) in
            self.keyDown(key, key, flags, keyCode: code, windowNumber: panel.windowNumber)
        }

        #expect(panel.performKeyEquivalent(with: command("a", .command, 0)))
        #expect(editor.selectedRange == NSRange(location: 0, length: 3))
        editor.insertText("x", replacementRange: editor.selectedRange)
        #expect(panel.performKeyEquivalent(with: command("z", .command, 6)))
        #expect(editor.string == "abc")
        #expect(panel.performKeyEquivalent(with: command("z", [.command, .shift], 6)))
        #expect(editor.string == "x")
        #expect(!panel.performKeyEquivalent(with: command("a", [.command, .option], 0)))
    }
}
