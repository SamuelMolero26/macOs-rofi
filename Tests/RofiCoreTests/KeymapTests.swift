import RofiCore
import Testing

// Contract: rofi's binding table (source/keyb.c:119-134, 216-291) and its
// `Mod+Mod+Key` binding strings, matched against AppKit-shaped chords
// (`charactersIgnoringModifiers` plus modifier flags).
@Suite struct KeymapTests {
    private let returnKey = "\r"
    private let forwardDelete = "\u{F728}"

    private func lookup(_ key: String, _ modifiers: KeyModifiers = [], in keymap: Keymap = Keymap()) -> KeyAction? {
        keymap.action(for: KeyChord(key: key, modifiers: modifiers))
    }

    @Test func optionNamesFollowUpstream() {
        #expect(KeyAction.acceptCustom.optionName == "kb-accept-custom")
        #expect(KeyAction.acceptCustomAlt.optionName == "kb-accept-custom-alt")
        #expect(KeyAction.acceptAlt.optionName == "kb-accept-alt")
        #expect(KeyAction.deleteEntry.optionName == "kb-delete-entry")
        #expect(KeyAction.customKey(1).optionName == "kb-custom-1")
        #expect(KeyAction.customKey(19).optionName == "kb-custom-19")
        #expect(KeyAction.allCases.count == 23)
    }

    @Test func actionFromOptionName() {
        for action in KeyAction.allCases {
            #expect(KeyAction(optionName: action.optionName) == action)
        }
        #expect(KeyAction(optionName: "kb-custom-0") == nil)
        #expect(KeyAction(optionName: "kb-custom-20") == nil)
        #expect(KeyAction(optionName: "kb-accept-entry") == nil)
    }

    @Test func upstreamDefaultStrings() {
        #expect(KeyAction.acceptCustom.upstreamBinding == "Control+Return")
        #expect(KeyAction.acceptCustomAlt.upstreamBinding == "Control+Shift+Return")
        #expect(KeyAction.acceptAlt.upstreamBinding == "Shift+Return")
        #expect(KeyAction.deleteEntry.upstreamBinding == "Shift+Delete")
        let custom = (1...19).map { KeyAction.customKey($0).upstreamBinding }
        #expect(
            custom == [
                "Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0",
                "Alt+exclam", "Alt+at", "Alt+numbersign", "Alt+dollar", "Alt+percent", "Alt+dead_circumflex",
                "Alt+ampersand", "Alt+asterisk", "Alt+parenleft",
            ])
    }

    @Test func parsesModifiersAndAlternatives() throws {
        #expect(try Keymap.parse("Control+Shift+Return") == [KeyChord(key: returnKey, modifiers: [.control, .shift])])
        #expect(
            try Keymap.parse("Alt+1,Super+x")
                == [KeyChord(key: "1", modifiers: .option), KeyChord(key: "x", modifiers: .command)])
        #expect(try Keymap.parse("control+ALT+a") == [KeyChord(key: "a", modifiers: [.control, .option])])
    }

    @Test(arguments: [
        ("Return", "\r"), ("KP_Enter", "\u{3}"), ("Delete", "\u{F728}"), ("BackSpace", "\u{7F}"),
        ("Tab", "\t"), ("Escape", "\u{1B}"), ("exclam", "!"), ("at", "@"), ("numbersign", "#"),
        ("dollar", "$"), ("percent", "%"), ("asciicircum", "^"), ("dead_circumflex", "^"),
        ("ampersand", "&"), ("asterisk", "*"), ("parenleft", "("), ("parenright", ")"),
    ])
    func parsesKeysymNames(name: String, key: String) throws {
        #expect(try Keymap.parse(name) == [KeyChord(key: key, modifiers: [])])
    }

    @Test func invalidTokensThrowNamingTheToken() {
        #expect(throws: KeyBindingError.unknownModifier("Hyper")) { try Keymap.parse("Hyper+a") }
        #expect(throws: KeyBindingError.unknownKey("Fnord")) { try Keymap.parse("Alt+1,Alt+Fnord") }
        #expect(throws: KeyBindingError.unknownKey("")) { try Keymap.parse("Alt+") }
    }

    @Test func emptyBindingUnbinds() throws {
        #expect(try Keymap.parse("") == [])
        #expect(try Keymap.parse(" ") == [])
    }

    @Test func defaultAcceptAndDeleteChords() {
        #expect(lookup(returnKey, .control) == .acceptCustom)
        #expect(lookup(returnKey, [.control, .shift]) == .acceptCustomAlt)
        #expect(lookup(returnKey, .shift) == .acceptAlt)
        #expect(lookup(returnKey) == nil, "plain Return stays accept-entry, outside this keymap")
        #expect(lookup(forwardDelete, .shift) == .deleteEntry)
        #expect(lookup(forwardDelete) == nil)
    }

    @Test func defaultCustomDigits() {
        #expect(lookup("1", .option) == .customKey(1))
        #expect(lookup("9", .option) == .customKey(9))
        #expect(lookup("0", .option) == .customKey(10))
        #expect(lookup("1", .command) == nil)
        #expect(lookup("1", [.option, .control]) == nil)
        #expect(lookup("1") == nil)
    }

    @Test func shiftIsFoldedIntoSymbolCharacters() {
        // Alt+Shift+1 on a US layout reports "!" with Shift held.
        #expect(lookup("!", [.option, .shift]) == .customKey(11))
        #expect(lookup("^", [.option, .shift]) == .customKey(16))
        #expect(lookup("(", [.option, .shift]) == .customKey(19))
        #expect(lookup("!", .option) == .customKey(11))
    }

    @Test func lettersCompareCaseInsensitivelyAndKeepShift() throws {
        var keymap = Keymap()
        try keymap.rebind(.customKey(1), to: "Alt+a")
        #expect(lookup("a", .option, in: keymap) == .customKey(1))
        #expect(lookup("A", [.option, .shift], in: keymap) == nil)
        try keymap.rebind(.customKey(1), to: "Alt+Shift+a")
        #expect(lookup("A", [.option, .shift], in: keymap) == .customKey(1))
        #expect(lookup("a", .option, in: keymap) == nil)
    }

    @Test func rebindReplacesBindings() throws {
        var keymap = Keymap()
        try keymap.rebind(.customKey(1), to: "Control+1")
        #expect(lookup("1", .control, in: keymap) == .customKey(1))
        #expect(lookup("1", .option, in: keymap) == nil)
        try keymap.rebind(.customKey(1), to: "")
        #expect(lookup("1", .control, in: keymap) == nil)
    }

    @Test func failedRebindKeepsPreviousBindings() {
        var keymap = Keymap()
        #expect(throws: KeyBindingError.unknownModifier("Meta")) {
            try keymap.rebind(.customKey(1), to: "Meta+1")
        }
        #expect(lookup("1", .option, in: keymap) == .customKey(1))
    }
}
