import Foundation

/// One listed window, as window.c's `client` (source/modes/window.c:115-135).
public struct WindowRecord: Equatable, Sendable {
    /// The platform's key for raising and closing this window.
    public var handle: Int
    /// `{window}` in `-window-command`: the window id, empty when unknown.
    public var id: String
    /// `{c}`: the owning application's name.
    public var app: String
    /// `{t}` and `{n}`.
    public var title: String
    /// The application bundle, shown as the row's icon.
    public var bundlePath: String?
    /// The focused window (window.c:625-627).
    public var active: Bool

    public init(
        handle: Int, id: String, app: String, title: String, bundlePath: String? = nil, active: Bool = false
    ) {
        self.handle = handle
        self.id = id
        self.app = app
        self.title = title
        self.bundlePath = bundlePath
        self.active = active
    }
}

/// Why the window list could not be read, shown as the mode's message.
public struct WindowListFailure: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// The platform's window list and actions, injected into `WindowMode`.
public struct WindowSystem {
    public var windows: () throws -> [WindowRecord]
    public var raise: (WindowRecord) -> Void
    public var close: (WindowRecord) -> Void

    public init(
        windows: @escaping () throws -> [WindowRecord], raise: @escaping (WindowRecord) -> Void,
        close: @escaping (WindowRecord) -> Void
    ) {
        self.windows = windows
        self.raise = raise
        self.close = close
    }

    /// No windows: for callers without a platform window list.
    public static var none: WindowSystem { WindowSystem(windows: { [] }, raise: { _ in }, close: { _ in }) }
}

/// The `window` mode (source/modes/window.c): the open windows, Enter raising
/// the selected one.
///
/// Listing, raising and closing are injected; the mode owns the display
/// string, matching and the menu actions. On macOS `{w}` (desktop) and `{r}`
/// (role) are always empty: Spaces have no public API, and every listed
/// window's AX subrole is the same.
///
/// ponytail: no urgent rows (no AX attribute signals attention) and no
/// thumbnails (ScreenCaptureKit needs macOS 14 and Screen Recording).
public final class WindowMode: Mode {
    public let name = "window"
    /// Read on first use: mode_init runs only when a mode is shown
    /// (source/rofi.c:204).
    public var rows: [Row] {
        if !loaded { load() }
        return loadedRows
    }
    private var loaded = false
    private var loadedRows: [Row] = []
    /// The windows behind `rows`, after hide-active-window.
    private var shown: [WindowRecord] = []
    private var listed: [WindowRecord] {
        if !loaded { load() }
        return shown
    }
    /// Why the list could not be read; kept until the next read.
    private var listFailure: String?
    private let listWindows: () throws -> [WindowRecord]
    private let raise: (WindowRecord) -> Void
    private let close: (WindowRecord) -> Void
    private let format: String
    /// title, class, role, name, desktop (window.c:85-105).
    private let enabledFields: [Bool]
    private let windowCommand: String
    private let hideActiveWindow: Bool
    private let closeOnDelete: Bool
    private let terminal: String?
    private let runCommand: String
    private let runShellCommand: String
    private let launcher: CommandLauncher
    private let writeScript: ScriptWriter
    /// The last failed command, as upstream's error dialog; cleared by the
    /// next action.
    private var failure: String?

    /// `format` defaults to upstream's `{w}    {c}   {t}` (config/config.c:155)
    /// without `{w}`, which is always empty here. `windowCommand` keeps
    /// upstream's default (config/config.c:76). `hideActiveWindow` and
    /// `closeOnDelete` are the theme booleans (window.c:704-708, 833-838).
    public init(
        windows: @escaping () throws -> [WindowRecord], raise: @escaping (WindowRecord) -> Void,
        close: @escaping (WindowRecord) -> Void, format: String = "{c}   {t}", matchFields: String = "all",
        windowCommand: String = "wmctrl -i -R {window}", hideActiveWindow: Bool = false,
        closeOnDelete: Bool = true, terminal: String?, runCommand: String = "{cmd}",
        runShellCommand: String = "{terminal} -e {cmd}", launcher: @escaping CommandLauncher,
        writeScript: @escaping ScriptWriter
    ) {
        listWindows = windows
        self.raise = raise
        self.close = close
        self.format = format
        enabledFields = parseMatchFields(matchFields)
        self.windowCommand = windowCommand
        self.hideActiveWindow = hideActiveWindow
        self.closeOnDelete = closeOnDelete
        self.terminal = terminal
        self.runCommand = runCommand
        self.runShellCommand = runShellCommand
        self.launcher = launcher
        self.writeScript = writeScript
    }

    public var message: String? { failure ?? listFailure }
    /// The MARKUP state bit (window.c:964).
    public var markupRows: Bool { true }

    public func iconPath(at row: Int) -> String? {
        listed.indices.contains(row) ? listed[row].bundlePath : nil
    }

    /// `window_match` (window.c:427-470) on the enabled raw fields.
    public func matches(_ row: Row, at index: Int, matcher: Matcher) -> Bool {
        guard listed.indices.contains(index) else { return false }
        let window = listed[index]
        let fields = [window.title, window.app, "", window.title, ""]
        return matcher.matches(fields: zip(fields, enabledFields).map { $1 ? $0 : "" })
    }

    /// `window_mode_result` (window.c:775-862).
    public func result(_ action: MenuAction, alt: Bool, input: inout String?, selectedRow: Int?) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            return .switchTo(key)
        case .ok:
            guard let row = selectedRow, listed.indices.contains(row) else { return .reload }
            if alt { return actOnWindow(listed[row]) }
            raise(listed[row])
            return .exit
        case .deleteEntry:
            guard let row = selectedRow, listed.indices.contains(row) else { return .reload }
            close(listed[row])
            if closeOnDelete { return .exit }
            // ponytail: upstream keeps the closed row; re-reading drops it.
            load()
            return .reload
        case .customInput:
            guard let input, !input.isEmpty else { return .exit }
            failure = executeCommand(
                input, inTerminal: alt, terminal: terminal, runCommand: runCommand,
                runShellCommand: runShellCommand, launcher: launcher, writeScript: writeScript)
            return failure == nil ? .exit : .reload
        }
    }

    /// `act_on_window` (window.c:745-773): `-window-command` with `{window}`.
    private func actOnWindow(_ window: WindowRecord) -> ModeResult {
        let reason: String
        do {
            let argv = try parseCommandTemplate(windowCommand, values: ["window": window.id])
            guard case .failure(let error) = launcher(argv) else { return .exit }
            reason = error.reason
        } catch let error as CommandTemplateError {
            reason = error.message
        } catch {
            reason = "\(error)"
        }
        failure = "Failed to execute action for window: '\(window.id)'\nError: '\(reason)'"
        return .reload
    }

    /// `_window_mode_load_data` (window.c:541-700): column widths count every
    /// window (613-616) before hide-active-window drops the active one
    /// (689-691).
    private func load() {
        loaded = true
        let windows: [WindowRecord]
        do {
            windows = try listWindows()
            listFailure = nil
        } catch {
            windows = []
            listFailure = (error as? WindowListFailure)?.message ?? "\(error)"
        }
        let titleWidth = windows.map(\.title.count).max() ?? 0
        let widths: [Character: Int] = ["c": windows.map(\.app.count).max() ?? 0, "t": titleWidth, "n": titleWidth]
        shown = hideActiveWindow ? windows.filter { !$0.active } : windows
        loadedRows = shown.map { window in
            var row = Row(parsing: displayString(window, widths: widths))
            row.active = window.active
            return row
        }
    }

    /// `_generate_display_string` (window.c:938-944) with `helper_eval_cb`
    /// (906-936): the first letter names the field, unknown fields vanish.
    private func displayString(_ window: WindowRecord, widths: [Character: Int]) -> String {
        let source = format as NSString
        var output = ""
        var last = 0
        for match in fieldPattern.matches(in: format, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let token = Array(source.substring(with: match.range))
            let width = token[2] == ":" ? Int(String(token[3..<(token.count - 1)])) ?? 0 : 0
            let value: String? =
                switch token[1] {
                case "c": window.app
                case "t", "n": window.title
                case "w", "r": ""
                default: nil
                }
            if let value { output += field(value, width: width, columnWidth: widths[token[1]] ?? 0) }
        }
        output += source.substring(from: last)
        // g_strchomp.
        while let end = output.last, end.isWhitespace { output.removeLast() }
        return output
    }
}

/// `{name}` or `{name:width}` (window.c:713).
private let fieldPattern = try! NSRegularExpression(pattern: "\\{[-\\w]+(:-?[0-9]+)?\\}")

/// `helper_eval_add_str` (window.c:881-905): a positive width truncates or
/// pads, 0 pads to the column's widest value, a negative one adds the value
/// alone. ponytail: every value is escaped; upstream escapes only the
/// positive-width case, so a title with `&` breaks its markup there.
private func field(_ value: String, width: Int, columnWidth: Int) -> String {
    if width > 0 {
        if value.count > width { return escapeMarkup(String(value.prefix(width))) }
        return escapeMarkup(value) + String(repeating: " ", count: width - value.count)
    }
    let padding = width == 0 ? max(0, columnWidth - value.count) : 0
    return escapeMarkup(value) + String(repeating: " ", count: padding)
}

/// `window_mode_parse_fields` (window.c:481-510): title, class, role, name and
/// desktop flags. ponytail: an unknown name is ignored; upstream also warns.
private func parseMatchFields(_ list: String) -> [Bool] {
    let names = ["title", "class", "role", "name", "desktop"]
    var enabled = Array(repeating: false, count: names.count)
    for token in list.split(whereSeparator: { $0 == "," || $0 == "#" }) {
        if token == "all" { return Array(repeating: true, count: names.count) }
        if let index = names.firstIndex(of: String(token)) { enabled[index] = true }
    }
    return enabled
}
