import AppKit
import ApplicationServices
import RofiCore

/// The window list and actions for `WindowMode`, through Accessibility.
///
/// A `CGWindowID` cannot be mapped to its AX window with public API (CG
/// titles are truncated and frames collide), so windows are listed from AX
/// and acted on directly. CG only orders the apps. Accessibility is the one
/// permission needed; Screen Recording is not.
///
/// ponytail: with native Spaces, AX only lists the current Space's windows.
/// Within an app, windows keep AX order, assumed front to back.
public final class NativeWindowSystem {
    private var elements: [Int: (window: AXUIElement, app: NSRunningApplication)] = [:]

    public init() {}

    public var system: WindowSystem {
        WindowSystem(
            windows: { [self] in try list() }, raise: { [self] in raise($0) }, close: { [self] in close($0) })
    }

    /// Every standard window of every regular app, apps ordered by their
    /// frontmost on-screen window; apps with none (only minimized windows)
    /// go last.
    private func list() throws -> [WindowRecord] {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            throw WindowListFailure(
                message: "Listing windows needs Accessibility access.\n"
                    + "Allow the app that launched rofi in System Settings → Privacy &amp; Security → "
                    + "Accessibility, then run rofi again.")
        }
        let onScreen =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var order: [pid_t: Int] = [:]
        for info in onScreen where info[kCGWindowLayer as String] as? Int == 0 {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, order[pid] == nil { order[pid] = order.count }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rank = { (app: NSRunningApplication) in order[app.processIdentifier] ?? .max }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)

        elements = [:]
        var records: [WindowRecord] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // One frozen app must not stall the list.
            AXUIElementSetMessagingTimeout(element, 0.25)
            let focused: AXUIElement? =
                app.processIdentifier == front ? attribute(element, kAXFocusedWindowAttribute) : nil
            let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
            for window in windows where attribute(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String {
                let handle = records.count
                elements[handle] = (window, app)
                records.append(
                    WindowRecord(
                        handle: handle, id: windowID(window).map(String.init) ?? "",
                        app: app.localizedName ?? "", title: attribute(window, kAXTitleAttribute) ?? "",
                        bundlePath: app.bundleURL?.path, active: focused.map { CFEqual($0, window) } ?? false))
            }
        }
        return records
    }

    /// Un-minimizes and raises the window, then activates its app, which
    /// brings its main window, now this one, to the front.
    private func raise(_ record: WindowRecord) {
        guard let (window, app) = elements[record.handle] else { return }
        if attribute(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: [])
    }

    /// Presses the window's close button.
    private func close(_ record: WindowRecord) {
        guard let (window, _) = elements[record.handle],
            let button: AXUIElement = attribute(window, kAXCloseButtonAttribute)
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// The private `_AXUIElementGetWindow`, looked up at run time so a release
/// without it leaves `{window}` empty instead of failing to launch.
/// RTLD_DEFAULT is `(void *)-2` (dlfcn.h).
private let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: GetWindow.self) }

/// The `CGWindowID` for `{window}`, which tools such as yabai take.
private func windowID(_ window: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard let getWindow, getWindow(window, &id) == .success else { return nil }
    return id
}
