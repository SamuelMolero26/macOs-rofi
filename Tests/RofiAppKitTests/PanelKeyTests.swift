import AppKit
import RofiCore
import Testing

@testable import RofiAppKit

// The panel reads a key-down as `charactersIgnoringModifiers` plus the
// Control/Shift/Option/Command flags and asks the keymap for its action.
@MainActor @Suite struct PanelKeyTests {
    private func keyDown(_ characters: String, _ ignoringModifiers: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: 0)!
    }

    // Alt+1 types "¡" on a US layout; the keymap sees "1".
    @Test func altOneIsCustomOne() {
        let event = keyDown("¡", "1", .option)

        #expect(KeyChord(event: event) == KeyChord(key: "1", modifiers: .option))
        #expect(Keymap().action(for: event) == .customKey(1))
    }

    // Alt+Shift+1 reports "!", upstream's `Alt+exclam`.
    @Test func altShiftOneIsCustomEleven() {
        #expect(Keymap().action(for: keyDown("⁄", "!", [.option, .shift])) == .customKey(11))
    }

    @Test func returnChordsFollowTheKeymap() {
        #expect(Keymap().action(for: keyDown("\r", "\r", .control)) == .acceptCustom)
        #expect(Keymap().action(for: keyDown("\r", "\r", [.control, .shift])) == .acceptCustomAlt)
        #expect(Keymap().action(for: keyDown("\r", "\r", .shift)) == .acceptAlt)
        #expect(Keymap().action(for: keyDown("\r", "\r", [])) == nil, "plain Return stays kb-accept-entry")
    }

    // Caps Lock, the numeric pad and function-key flags are not modifiers.
    @Test func otherFlagsAreIgnored() {
        let event = keyDown("\u{F728}", "\u{F728}", [.shift, .function, .numericPad, .capsLock])

        #expect(Keymap().action(for: event) == .deleteEntry)
    }

    @Test func keyUpIsNoChord() {
        let event = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
            characters: "¡", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 0)!

        #expect(KeyChord(event: event) == nil)
    }
}
