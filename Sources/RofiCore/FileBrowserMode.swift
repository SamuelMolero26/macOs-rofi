import Foundation

/// One directory entry as the browser needs it (source/modes/filebrowser.c:
/// 253-345). `.` and `..` are never entries: the browser adds its own up row.
public struct FileBrowserEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case directory
        case file
        /// Sockets, fifos and devices; skipped (filebrowser.c:276-282).
        case other
    }

    public var name: String
    /// What the entry is once a link is followed (filebrowser.c:339-345).
    public var kind: Kind
    public var isLink: Bool

    public init(name: String, kind: Kind, isLink: Bool) {
        self.name = name
        self.kind = kind
        self.isLink = isLink
    }
}

/// The disk as `FileBrowserMode` sees it, so the mode can run on a fake.
public protocol FileBrowserFileSystem {
    /// The entries of `path`, or nil when it cannot be opened
    /// (filebrowser.c:249).
    func entries(in path: String) -> [FileBrowserEntry]?
    /// `g_file_test(G_FILE_TEST_IS_DIR)`: links are followed.
    func isDirectory(_ path: String) -> Bool
    /// `g_file_test(G_FILE_TEST_EXISTS)`.
    func exists(_ path: String) -> Bool
}

/// The real disk: readdir's types, links resolved with stat.
public struct DiskFileSystem: FileBrowserFileSystem {
    public init() {}

    /// ponytail: DT_UNKNOWN entries are skipped as upstream does
    /// (filebrowser.c:276-282); APFS reports real types, other volumes may not.
    public func entries(in path: String) -> [FileBrowserEntry]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var entries: [FileBrowserEntry] = []
        while let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let full = path.hasSuffix("/") ? path + name : path + "/" + name
            switch Int32(item.pointee.d_type) {
            case Int32(DT_REG): entries.append(.init(name: name, kind: .file, isLink: false))
            case Int32(DT_DIR): entries.append(.init(name: name, kind: .directory, isLink: false))
            case Int32(DT_LNK):
                // A link defaults to a file; stat can make it a directory
                // (filebrowser.c:309-345).
                entries.append(.init(name: name, kind: isDirectory(full) ? .directory : .file, isLink: true))
            default: entries.append(.init(name: name, kind: .other, isLink: false))
            }
        }
        return entries
    }

    public func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    public func exists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }
}

/// A launch that failed: the command as upstream words it and why
/// (source/helper.c:1426-1434).
public struct FileBrowserOpenFailure: Error, Equatable, Sendable {
    public var command: String
    public var reason: String

    public init(command: String, reason: String) {
        self.command = command
        self.reason = reason
    }

    /// The error dialog text (helper.c:1428-1430), its markup rendered away.
    public var dialogText: String { "Failed to execute: '\(command)'\nError: '\(reason)'" }
}

/// Opens `path` the way the browser's `command` does: `path` as the argument,
/// run from `directory` (filebrowser.c:510-519).
public typealias FileBrowserOpener = (_ path: String, _ directory: String) -> Result<Void, FileBrowserOpenFailure>

/// Runs `/usr/bin/open path` from `directory`. Upstream's g_spawn_async only
/// fails when the spawn does (helper.c:1424-1434); `open` hands off to Launch
/// Services and exits at once, so its exit status and stderr are waited for
/// too: a missing file or one no app can open fails here, not silently.
/// ponytail: blocks the caller until `open` exits; it does not wait for the
/// app it launches.
public func openWithSystemOpener(path: String, directory: String) -> Result<Void, FileBrowserOpenFailure> {
    // filebrowser.c:512-513: the command is `command` plus g_shell_quote(path).
    let command = "/usr/bin/open '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [path]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return .failure(FileBrowserOpenFailure(command: command, reason: error.localizedDescription))
    }
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = text.isEmpty ? "exited with status \(process.terminationStatus)" : text
        return .failure(FileBrowserOpenFailure(command: command, reason: reason))
    }
    return .success(())
}

/// The `filebrowser` mode (source/modes/filebrowser.c): one directory at a
/// time, an up row, directories before files, Enter descends into a directory
/// or opens a file.
///
/// ponytail: upstream's theme properties `sorting-method` (time sorts),
/// `directories-first`, `command` and `cancel-returns-1`, the cache file that
/// remembers the last directory (422-453, 523-527) and the alternate accept
/// key (494-495, 511, 534-542) are not implemented; names sort like Finder,
/// not glib's collate keys.
public final class FileBrowserMode: Mode {
    public let name = "filebrowser"
    public private(set) var rows: [Row] = []
    public private(set) var currentDirectory: String

    private enum Kind: Int, Comparable {
        case up, directory, file
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Listing {
        var name: String
        var path: String
        var kind: Kind
        var isLink: Bool
    }

    private let fileSystem: any FileBrowserFileSystem
    private let opener: FileBrowserOpener
    private var showHidden: Bool
    private var listing: [Listing] = []
    /// The last failed launch, worded as upstream's error dialog
    /// (helper.c:1428-1430); cleared by the next action.
    private var failure: String?

    /// `file_browser_mode_init` (filebrowser.c:456-476): the configured
    /// directory when it is one, else the home directory (422-453).
    public init(
        directory: String?, showHidden: Bool, home: String,
        fileSystem: any FileBrowserFileSystem = DiskFileSystem(),
        opener: @escaping FileBrowserOpener = openWithSystemOpener
    ) {
        self.fileSystem = fileSystem
        self.opener = opener
        self.showHidden = showHidden
        if let directory, fileSystem.isDirectory(directory) {
            currentDirectory = normalized(directory)
        } else {
            currentDirectory = normalized(home)
        }
        load()
    }

    /// Upstream shows the markup `<b>Current directory:</b> dir`
    /// (filebrowser.c:641-647), with its markup rendered away.
    /// A failed launch is shown in its place until the next action.
    public var message: String? { failure ?? "Current directory: " + currentDirectory }

    /// `_get_display_value` (filebrowser.c:582-598).
    private func display(_ item: Listing) -> String? {
        if item.kind == .up { return " .." }
        return item.isLink ? "@" + item.name : nil
    }

    /// `_get_icon` (filebrowser.c:620-638) by path: the up row shows the
    /// parent folder, the root itself at the root.
    /// ponytail: Finder icons only; upstream's image and thumbnail previews
    /// are not drawn.
    public func iconPath(at row: Int) -> String? {
        guard listing.indices.contains(row) else { return nil }
        let item = listing[row]
        return item.kind == .up ? parent(of: currentDirectory) ?? currentDirectory : item.path
    }

    /// `get_file_browser` (filebrowser.c:241-358). An unreadable directory
    /// lists nothing, not even the up row, because upstream's `..` comes from
    /// readdir (253-267).
    private func load() {
        listing = []
        defer {
            rows = listing.map {
                var row = Row(parsing: $0.name)
                row.display = display($0)
                return row
            }
        }
        guard let entries = fileSystem.entries(in: currentDirectory) else { return }
        listing.append(Listing(name: "..", path: "", kind: .up, isLink: false))
        var found: [Listing] = []
        for entry in entries {
            if entry.name.hasPrefix(".") && !showHidden { continue }
            switch entry.kind {
            case .other: continue
            case .directory:
                found.append(
                    Listing(
                        name: entry.name, path: join(currentDirectory, entry.name), kind: .directory,
                        isLink: entry.isLink))
            case .file:
                found.append(
                    Listing(
                        name: entry.name, path: join(currentDirectory, entry.name), kind: .file, isLink: entry.isLink))
            }
        }
        // compare_name (filebrowser.c:147-158): directories first, then by name.
        found.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.name < $1.name
            }
        }
        listing += found
    }

    private func enter(_ path: String) -> ModeResult {
        currentDirectory = path
        load()
        return .reset
    }

    /// `file_browser_mode_result` (filebrowser.c:479-570).
    public func result(_ action: MenuAction, input: inout String?, selectedRow: Int?) -> ModeResult {
        failure = nil
        switch action {
        case .cancel:
            return .exit
        case .customKey(let key):
            // filebrowser.c:496-497.
            return .switchTo(key)
        case .ok:
            guard let index = selectedRow, listing.indices.contains(index) else { return .reload }
            let item = listing[index]
            switch item.kind {
            case .up:
                // At the root g_file_get_parent is NULL and the view reloads
                // (500-508, 532).
                guard let parent = parent(of: currentDirectory) else { return .reload }
                return enter(parent)
            case .file:
                // Upstream exits even when the launch fails, behind an error
                // dialog (510-519, helper.c:1426-1434); here the failure is
                // the message and the view stays open.
                if case .failure(let error) = opener(item.path, currentDirectory) {
                    failure = error.dialogText
                    return .reload
                }
                return .exit
            case .directory:
                return enter(item.path)
            }
        case .customInput:
            // No input leaves MODE_EXIT (479-483, 544).
            guard let input else { return .exit }
            return enterDirectory(typed: input)
        case .deleteEntry:
            showHidden.toggle()
            load()
            return .reload
        }
    }

    /// MENU_COMPLETE matches no branch of `file_browser_mode_result`, so the
    /// view exits (filebrowser.c:481).
    public func complete(input: inout String?, selectedRow: Int?) -> ModeResult? {
        failure = nil
        return .exit
    }

    /// `file_browser_mode_completer` (filebrowser.c:672-724), for a mode that
    /// uses the browser as its file completer, as run does (run.c:474-487):
    /// like `result`, but a chosen file is returned as `path`, never opened.
    ///
    /// ponytail: upstream returns `g_strescape(path)` (696), which turns `"`,
    /// `\` and non-ASCII bytes into escapes that stay literal inside the
    /// caller's g_shell_quote; the raw path is returned here.
    public func completerResult(
        _ action: MenuAction, input: inout String?, selectedRow: Int?
    ) -> (result: ModeResult, path: String?) {
        failure = nil
        switch action {
        case .ok:
            // 678-700: no valid row, or up at the root, reloads.
            guard let index = selectedRow, listing.indices.contains(index) else { return (.reload, nil) }
            let item = listing[index]
            switch item.kind {
            case .up:
                guard let parent = parent(of: currentDirectory) else { return (.reload, nil) }
                return (enter(parent), nil)
            case .directory:
                return (enter(item.path), nil)
            case .file:
                return (.exit, item.path)
            }
        case .customInput:
            // 701-716; no input falls through to MODE_EXIT (674).
            guard let input else { return (.exit, nil) }
            return (enterDirectory(typed: input), nil)
        case .deleteEntry:
            // 717-721.
            showHidden.toggle()
            load()
            return (.reload, nil)
        case .cancel, .customKey:
            // 674: every other action exits without a path.
            return (.exit, nil)
        }
    }

    /// The typed path, expanded, entered when it is a directory; else the
    /// view reloads (filebrowser.c:545-559, 701-716).
    private func enterDirectory(typed input: String) -> ModeResult {
        let path = expandPath(input)
        if fileSystem.exists(path), fileSystem.isDirectory(path) { return enter(normalized(path)) }
        return .reload
    }
}

/// Trailing slashes dropped, as `g_file_new_for_path` does; the root stays.
private func normalized(_ path: String) -> String {
    var path = path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}

private func join(_ directory: String, _ name: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
}

/// `g_file_get_parent`: nil for the root.
private func parent(of path: String) -> String? {
    guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
    return slash == path.startIndex ? "/" : String(path[..<slash])
}
