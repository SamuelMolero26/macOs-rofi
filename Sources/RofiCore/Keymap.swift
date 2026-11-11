import Foundation

/// The key actions this port binds beyond plain accept, cancel and movement:
/// rofi's ACCEPT_CUSTOM, ACCEPT_CUSTOM_ALT, ACCEPT_ALT, DELETE_ENTRY,
/// CUSTOM_1..19 and MODE_COMPLETE (include/keyb.h, source/keyb.c:119-146,
/// 216-291).
public enum KeyAction: Hashable, Sendable, CaseIterable {
    case acceptCustom
    case acceptCustomAlt
    case acceptAlt
    case deleteEntry
    /// `kb-custom-N`, with N in 1...19.
    case customKey(Int)
    /// `kb-mode-complete`: MENU_COMPLETE (source/view.c:1128-1136).
    case modeComplete

    /// In source/keyb.c's binding order.
    public static let allCases: [KeyAction] =
        [.acceptCustom, .acceptCustomAlt, .acceptAlt, .deleteEntry, .modeComplete] + (1...19).map { .customKey($0) }

    /// The upstream option name, used as `-kb-<name>` on the command line.
    public var optionName: String {
        switch self {
        case .acceptCustom: "kb-accept-custom"
        case .acceptCustomAlt: "kb-accept-custom-alt"
        case .acceptAlt: "kb-accept-alt"
        case .deleteEntry: "kb-delete-entry"
        case .customKey(let n): "kb-custom-\(n)"
        case .modeComplete: "kb-mode-complete"
        }
    }

    public init?(optionName: String) {
        guard let action = Self.allCases.first(where: { $0.optionName == optionName }) else { return nil }
        self = action
    }

    /// The default binding string, copied from source/keyb.c:119-146, 216-291.
    public var upstreamBinding: String {
        switch self {
        case .acceptCustom: "Control+Return"
        case .acceptCustomAlt: "Control+Shift+Return"
        case .acceptAlt: "Shift+Return"
        case .deleteEntry: "Shift+Delete"
        case .customKey(let n) where n <= 10: "Alt+\(n % 10)"
        case .customKey(let n): "Alt+" + Self.shiftedDigitKeysyms[n - 11]
        case .modeComplete: "Control+l"
        }
    }

    /// The binding's description in source/keyb.c:119-146, 216-291.
    public var comment: String {
        switch self {
        case .acceptCustom, .acceptCustomAlt: "Use entered text as command (in ssh/run modes)"
        case .acceptAlt: "Use alternate accept command."
        case .deleteEntry: "Delete entry from history"
        case .customKey(let n): "Custom keybinding \(n)"
        case .modeComplete: "Start completion for mode."
        }
    }

    /// Keysyms of Shift+1 ... Shift+9 as upstream binds custom-11..19.
    private static let shiftedDigitKeysyms = [
        "exclam", "at", "numbersign", "dollar", "percent", "dead_circumflex", "ampersand", "asterisk", "parenleft",
    ]
}

/// The modifier keys of a chord, named after AppKit's modifier flags.
/// Upstream's `Alt` is Option and `Super` is Command.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// One key press: the key as AppKit's `charactersIgnoringModifiers` reports
/// it, plus the modifiers held. Bindings and events build chords the same
/// way, so equal chords match.
public struct KeyChord: Hashable, Sendable {
    public let key: String
    public let modifiers: KeyModifiers

    /// Normalizes so a binding and an event for the same press compare equal:
    /// letters compare case-insensitively and keep Shift; named non-printable
    /// keys (Return, Delete, Tab...) keep Shift. A printable symbol already
    /// has Shift folded in (Alt+Shift+1 reports "!", matching `Alt+exclam`),
    /// so Shift is dropped for it.
    public init(key: String, modifiers: KeyModifiers) {
        self.key = key.lowercased()
        self.modifiers = KeyChord.isSymbol(key) ? modifiers.subtracting(.shift) : modifiers
    }

    /// One printable non-letter character: not a letter, a control
    /// character, or an AppKit function key (private use, U+F700...).
    private static func isSymbol(_ key: String) -> Bool {
        guard key.count == 1, let char = key.first, !char.isLetter else { return false }
        return char.unicodeScalars.allSatisfy {
            ![.control, .privateUse].contains($0.properties.generalCategory)
        }
    }
}

/// A binding string that does not parse; the payload is the offending token.
public enum KeyBindingError: Error, Equatable, CustomStringConvertible {
    case unknownModifier(String)
    case unknownKey(String)

    /// ponytail: nkutils' own wording is not vendored upstream, so this is ours.
    public var description: String {
        switch self {
        case .unknownModifier(let token): "Unknown modifier: \(token)"
        case .unknownKey(let token): "Unknown key: \(token)"
        }
    }
}

/// Which chord triggers which action, starting from upstream's defaults.
///
/// ponytail: only the actions in `KeyAction`; accept-entry, cancel and
/// movement stay hard-wired in the panel. When one chord is bound to two
/// actions, the first in `KeyAction.allCases` wins.
public struct Keymap: Equatable, Sendable {
    private var bindings: [KeyAction: [KeyChord]]
    /// Each action's binding string as given, shown by the `keys` mode.
    private var strings: [KeyAction: String] = [:]

    /// Upstream's default bindings.
    public init() {
        bindings = Dictionary(
            uniqueKeysWithValues: KeyAction.allCases.map { ($0, try! Keymap.parse($0.upstreamBinding)) })
    }

    /// Replaces `action`'s bindings, as `-kb-<name> <binding>` does. An empty
    /// string unbinds it. On error the old bindings stay.
    public mutating func rebind(_ action: KeyAction, to binding: String) throws {
        bindings[action] = try Keymap.parse(binding)
        strings[action] = binding
    }

    /// `action`'s binding string: the `-kb-<name>` value, else the default.
    public func binding(for action: KeyAction) -> String {
        strings[action] ?? action.upstreamBinding
    }

    /// Upstream's defaults with every `-kb-<name> <binding>` applied; each
    /// binding is an option (source/keyb.c:416-423). Like parse_keys_abe
    /// (source/keyb.c:450-491) every failing alternative is one startup error
    /// with its markup rendered away, and the dialog exits `EX_DATAERR`
    /// (source/rofi.c:1271, 840-857, 882-885).
    public init(arguments args: Arguments) throws {
        self.init()
        var errors: [String] = []
        for action in KeyAction.allCases {
            guard let binding = args.string("-" + action.optionName) else { continue }
            var chords: [KeyChord] = []
            for alternative in binding.split(separator: ",") {
                do {
                    chords += try Keymap.parse(String(alternative))
                } catch {
                    errors.append(
                        "Failed to set binding \(binding) for: \(action.comment) (\(action.optionName)):\n\t\(error)\n")
                }
            }
            bindings[action] = chords
            strings[action] = binding
        }
        if !errors.isEmpty { throw InvalidModeConfiguration(errors: errors) }
    }

    /// The action bound to `chord`, if any.
    public func action(for chord: KeyChord) -> KeyAction? {
        KeyAction.allCases.first { bindings[$0]?.contains(chord) == true }
    }

    /// Parses a binding string: comma-separated alternatives, each
    /// `Mod+Mod+Key`. Modifiers are Control, Shift, Alt and Super, in any
    /// case. Keys are single characters or the keysym names in `keysyms`.
    /// Empty alternatives are skipped, so "" binds nothing.
    public static func parse(_ binding: String) throws -> [KeyChord] {
        try binding.split(separator: ",").compactMap { alternative in
            let alternative = alternative.trimmingCharacters(in: .whitespaces)
            guard !alternative.isEmpty else { return nil }
            var tokens = alternative.split(separator: "+", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let keyToken = tokens.removeLast()
            var modifiers: KeyModifiers = []
            for token in tokens {
                guard let modifier = modifierNames[token.lowercased()] else {
                    throw KeyBindingError.unknownModifier(token)
                }
                modifiers.insert(modifier)
            }
            return KeyChord(key: try key(named: keyToken), modifiers: modifiers)
        }
    }

    private static func key(named token: String) throws -> String {
        if token.count == 1 { return token }
        if let key = keysyms[token.lowercased()] { return key }
        throw KeyBindingError.unknownKey(token)
    }

    private static let modifierNames: [String: KeyModifiers] = [
        "control": .control, "shift": .shift, "alt": .option, "super": .command,
    ]

    /// X11 keysym names (matched in any case) mapped to the character AppKit
    /// reports for that key: navigation and F keys as AppKit's function-key
    /// characters (NSUpArrowFunctionKey...). Shifted-digit names assume a US
    /// layout. macOS has no dead circumflex on Shift+6, so `dead_circumflex`
    /// (upstream's custom-16 default) is plain `^`.
    private static let keysyms: [String: String] = [
        "return": "\r",
        "kp_enter": "\u{3}",  // NSEnterCharacter
        "delete": "\u{F728}",  // NSDeleteFunctionKey (forward delete)
        "backspace": "\u{7F}",
        "tab": "\t",
        "escape": "\u{1B}",
        "exclam": "!",
        "at": "@",
        "numbersign": "#",
        "dollar": "$",
        "percent": "%",
        "asciicircum": "^",
        "dead_circumflex": "^",
        "ampersand": "&",
        "asterisk": "*",
        "parenleft": "(",
        "parenright": ")",
        "space": " ",
        "comma": ",",
        "plus": "+",
        "minus": "-",
        "period": ".",
        "slash": "/",
        "up": "\u{F700}",
        "down": "\u{F701}",
        "left": "\u{F702}",
        "right": "\u{F703}",
        "home": "\u{F729}",
        "end": "\u{F72B}",
        "page_up": "\u{F72C}",
        "page_down": "\u{F72D}",
    ].merging((1...12).map { ("f\($0)", String(UnicodeScalar(0xF703 + $0)!)) }) { $1 }
}
