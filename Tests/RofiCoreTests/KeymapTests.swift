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
        #expect(KeyAction.modeComplete.optionName == "kb-mode-complete")
        #expect(KeyAction.pagePrev.optionName == "kb-page-prev")
        #expect(KeyAction.selectRow(10).optionName == "kb-select-10")
        #expect(KeyAction.allCases.count == 39)
    }

    // source/keyb.c:164-191, 293-331, minus the keypad keys Macs lack.
    @Test func navigationDefaultsFollowUpstream() {
        #expect(lookup("\u{F72C}") == .pagePrev)
        #expect(lookup("\u{F72D}") == .pageNext)
        #expect(lookup("\u{F729}") == .rowFirst)
        #expect(lookup("\u{F72B}") == .rowLast)
        #expect(lookup("1", .command) == .selectRow(1))
        #expect(lookup("0", .command) == .selectRow(10))
        #expect(KeyAction.rowTab.upstreamBinding == "")
        #expect(KeyAction.allCases.filter(\.isNavigation).count == 15)
    }

    // source/keyb.c:143-146: MODE_COMPLETE, "Start completion for mode.".
    @Test func modeCompleteDefaultsToControlL_keyb_c_143() {
        #expect(KeyAction.modeComplete.upstreamBinding == "Control+l")
        #expect(KeyAction.modeComplete.comment == "Start completion for mode.")
        #expect(lookup("l", .control) == .modeComplete)
        #expect(lookup("l") == nil)
    }

    @Test func modeCompleteCanBeRebound_keyb_c_416() throws {
        let keymap = try keymap(["-kb-mode-complete", "Control+Tab"])

        #expect(lookup("\t", .control, in: keymap) == .modeComplete)
        #expect(lookup("l", .control, in: keymap) == nil)
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
        let plain = try keymap(["-kb-custom-1", "Alt+a"])
        #expect(lookup("a", .option, in: plain) == .customKey(1))
        #expect(lookup("A", [.option, .shift], in: plain) == nil)
        let shifted = try keymap(["-kb-custom-1", "Alt+Shift+a"])
        #expect(lookup("A", [.option, .shift], in: shifted) == .customKey(1))
        #expect(lookup("a", .option, in: shifted) == nil)
    }

    @Test func parsesMoreUpstreamKeysyms() throws {
        #expect(try Keymap.parse("Control+space") == [KeyChord(key: " ", modifiers: .control)])
        #expect(try Keymap.parse("Alt+comma") == [KeyChord(key: ",", modifiers: .option)])
        #expect(try Keymap.parse("Control+Page_Down") == [KeyChord(key: "\u{F72D}", modifiers: .control)])
    }

    @Test(arguments: [
        ("plus", "+"), ("minus", "-"), ("period", "."), ("slash", "/"), ("Up", "\u{F700}"), ("Down", "\u{F701}"),
        ("Left", "\u{F702}"), ("Right", "\u{F703}"), ("Home", "\u{F729}"), ("End", "\u{F72B}"),
        ("Page_Up", "\u{F72C}"), ("F1", "\u{F704}"), ("F12", "\u{F70F}"),
    ])
    func parsesNavigationAndPunctuationKeysyms(name: String, key: String) throws {
        #expect(try Keymap.parse("Alt+" + name) == [KeyChord(key: key, modifiers: .option)])
    }

    @Test func tokensAreTrimmed() throws {
        #expect(try Keymap.parse("Alt + 1") == [KeyChord(key: "1", modifiers: .option)])
    }

    // kb-remove-char-back includes Shift+BackSpace, so the keymap leaves it be.
    @Test func shiftBackspaceIsUnbound() {
        #expect(lookup("\u{7F}", .shift) == nil)
    }

    // MARK: `-kb-<name> <binding>` (source/keyb.c:416-423 registers each
    // binding as an option; parse_keys_abe reports failures, 450-491).

    private func keymap(_ argv: [String]) throws -> Keymap {
        try Keymap(arguments: Arguments(["rofi"] + argv))
    }

    @Test func optionRebindsItsAction() throws {
        let keymap = try keymap(["-kb-custom-1", "Control+1", "-kb-accept-custom", ""])

        #expect(lookup("1", .control, in: keymap) == .customKey(1))
        #expect(lookup("1", .option, in: keymap) == nil)
        #expect(lookup(returnKey, .control, in: keymap) == nil)
        #expect(lookup("2", .option, in: keymap) == .customKey(2))
    }

    // One message per failing alternative in binding-table order, worded as
    // parse_keys_abe's with its markup rendered away (source/keyb.c:476-482).
    @Test func invalidBindingsAreStartupErrors() {
        #expect(
            throws: InvalidModeConfiguration(errors: [
                "Failed to set binding Meta+Delete for: Delete entry from history (kb-delete-entry):\n"
                    + "\tUnknown modifier: Meta\n",
                "Failed to set binding Alt+bogus,Hyper+1 for: Custom keybinding 1 (kb-custom-1):\n\tUnknown key: bogus\n",
                "Failed to set binding Alt+bogus,Hyper+1 for: Custom keybinding 1 (kb-custom-1):\n\tUnknown modifier: Hyper\n",
            ])
        ) {
            try keymap(["-kb-delete-entry", "Meta+Delete", "-kb-custom-1", "Alt+bogus,Hyper+1"])
        }
    }
}
