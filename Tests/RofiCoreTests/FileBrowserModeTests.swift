import Darwin
import RofiCore
import Testing

/// An in-memory tree: `contents` lists the readable directories, `unreadable`
/// the directories that exist but cannot be opened.
private final class FakeFileSystem: FileBrowserFileSystem {
    var contents: [String: [FileBrowserEntry]] = [:]
    var unreadable: Set<String> = []
    var files: Set<String> = []

    func entries(in path: String) -> [FileBrowserEntry]? { contents[path] }

    func isDirectory(_ path: String) -> Bool { contents[path] != nil || unreadable.contains(path) }

    func exists(_ path: String) -> Bool { isDirectory(path) || files.contains(path) }
}

private func dir(_ name: String, link: Bool = false) -> FileBrowserEntry {
    FileBrowserEntry(name: name, kind: .directory, isLink: link)
}

private func file(_ name: String, link: Bool = false) -> FileBrowserEntry {
    FileBrowserEntry(name: name, kind: .file, isLink: link)
}

private func other(_ name: String) -> FileBrowserEntry {
    FileBrowserEntry(name: name, kind: .other, isLink: false)
}

private struct Opened: Equatable {
    let path: String
    let directory: String
}

// Contract: rofi's file browser, source/modes/filebrowser.c (listing
// 224-348, init 411-450 and 518-535, result 462-546, display 580-598,
// message 648-657).
@Suite final class FileBrowserModeTests {
    private let system = FakeFileSystem()
    private var opened: [Opened] = []
    /// What the injected opener answers.
    private var openResult: Result<Void, FileBrowserOpenFailure> = .success(())

    init() {
        system.contents["/home/u"] = [
            file("zeta.txt"), dir("Docs"), file(".hidden"), dir(".config"), dir("apps"), file("Alpha.md"),
            dir("link-dir", link: true), file("link-file", link: true), other("fifo"),
        ]
        system.contents["/home/u/Docs"] = [file("a.txt")]
        system.contents["/home/u/apps"] = []
        system.contents["/home/u/.config"] = [file("c")]
        system.contents["/home/u/link-dir"] = [file("inside")]
        system.contents["/"] = [dir("home")]
        system.contents["/home"] = [dir("u")]
        system.unreadable = ["/home/u/locked"]
        system.files = ["/home/u/zeta.txt"]
    }

    private func make(directory: String? = nil, showHidden: Bool = false) -> FileBrowserMode {
        FileBrowserMode(
            directory: directory, showHidden: showHidden, home: "/home/u", fileSystem: system,
            opener: { [unowned self] path, directory in
                opened.append(Opened(path: path, directory: directory))
                return openResult
            })
    }

    private func names(_ mode: FileBrowserMode) -> [String] { mode.rows.map(\.text) }

    private func row(_ mode: FileBrowserMode, _ name: String) -> Int {
        mode.rows.firstIndex { $0.text == name }!
    }

    private func act(
        _ mode: FileBrowserMode, _ action: MenuAction, input: String? = nil, row: Int? = nil
    ) -> (ModeResult, String?) {
        var input = input
        let result = mode.result(action, input: &input, selectedRow: row)
        return (result, input)
    }

    @Test func nameIsFilebrowser_filebrowser_c_729() {
        #expect(make().name == "filebrowser")
    }

    // filebrowser.c:422-453: the configured directory when it is one, else
    // the home directory.
    @Test func startsInTheConfiguredDirectory_filebrowser_c_422() {
        #expect(make(directory: "/home/u/Docs").currentDirectory == "/home/u/Docs")
        #expect(make(directory: "/nope").currentDirectory == "/home/u")
        #expect(make(directory: "/home/u/zeta.txt").currentDirectory == "/home/u")
        #expect(make().currentDirectory == "/home/u")
    }

    // filebrowser.c:147-153, 253-309: the up row first, then directories,
    // then files, each by name; `.` entries are hidden; only regular files,
    // directories and links are listed.
    @Test func listsUpThenDirectoriesThenFilesSorted_filebrowser_c_147() {
        #expect(
            names(make()) == ["..", "apps", "Docs", "link-dir", "Alpha.md", "link-file", "zeta.txt"])
    }

    // filebrowser.c:593-597: the up row reads " ..", a link is prefixed with @.
    @Test func displayTextMarksUpAndLinks_filebrowser_c_593() {
        let mode = make()
        #expect(mode.rows[0].display == " ..")
        #expect(mode.rows[row(mode, "link-dir")].display == "@link-dir")
        #expect(mode.rows[row(mode, "link-file")].display == "@link-file")
        #expect(mode.rows[row(mode, "Docs")].display == nil)
    }

    // filebrowser.c:271, 562: hidden entries appear when show-hidden is on.
    @Test func showHiddenListsDotEntries_filebrowser_c_271() {
        let all = names(make(showHidden: true))
        #expect(all.contains(".config"))
        #expect(all.contains(".hidden"))
        #expect(all.firstIndex(of: ".config")! < all.firstIndex(of: "Alpha.md")!)
    }

    // filebrowser.c:249: a directory that cannot be opened lists
    // nothing, not even the up row.
    @Test func unreadableDirectoryHasNoRows_filebrowser_c_249() {
        #expect(make(directory: "/home/u/locked").rows.isEmpty)
    }

    // filebrowser.c:641-647.
    @Test func messageNamesTheCurrentDirectory_filebrowser_c_641() {
        #expect(make().message == "Current directory: /home/u")
    }

    // filebrowser.c:520-529: a directory is entered, the input is reset.
    @Test func enterOnDirectoryDescendsAndResets_filebrowser_c_520() {
        let mode = make()
        let (result, _) = act(mode, .ok, row: row(mode, "Docs"))
        #expect(result == .reset)
        #expect(mode.currentDirectory == "/home/u/Docs")
        #expect(names(mode) == ["..", "a.txt"])
    }

    // filebrowser.c:309-345: a link to a directory is a directory.
    @Test func enterOnLinkedDirectoryDescends_filebrowser_c_309() {
        let mode = make()
        _ = act(mode, .ok, row: row(mode, "link-dir"))
        #expect(mode.currentDirectory == "/home/u/link-dir")
    }

    // filebrowser.c:500-507.
    @Test func enterOnUpGoesToTheParent_filebrowser_c_500() {
        let mode = make()
        let (result, _) = act(mode, .ok, row: 0)
        #expect(result == .reset)
        #expect(mode.currentDirectory == "/home")
        #expect(names(mode) == ["..", "u"])
    }

    // filebrowser.c:500-507, 532: the root has no parent; the view reloads.
    @Test func enterOnUpAtRootReloads_filebrowser_c_500() {
        let mode = make(directory: "/")
        let (result, _) = act(mode, .ok, row: 0)
        #expect(result == .reload)
        #expect(mode.currentDirectory == "/")
    }

    // filebrowser.c:510-519: a file is opened from the current directory,
    // then the switcher exits.
    @Test func enterOnFileOpensItAndExits_filebrowser_c_510() {
        let mode = make()
        let (result, _) = act(mode, .ok, row: row(mode, "zeta.txt"))
        #expect(result == .exit)
        #expect(opened == [Opened(path: "/home/u/zeta.txt", directory: "/home/u")])
    }

    // filebrowser.c:510-519, helper.c:1426-1434: a launch that fails is
    // reported worded as upstream's error dialog; here it is the message and
    // the view stays open on the same directory.
    @Test func failedOpenIsReportedAndStaysOpen_helper_c_1426() {
        openResult = .failure(FileBrowserOpenFailure(command: "/usr/bin/open '/home/u/zeta.txt'", reason: "boom"))
        let mode = make()
        let (result, _) = act(mode, .ok, row: row(mode, "zeta.txt"))
        #expect(result == .reload)
        #expect(mode.message == "Failed to execute: '/usr/bin/open '/home/u/zeta.txt''\nError: 'boom'")
        #expect(mode.currentDirectory == "/home/u")
        // The next action brings the directory message back.
        _ = act(mode, .ok, row: row(mode, "Docs"))
        #expect(mode.message == "Current directory: /home/u/Docs")
    }

    // filebrowser.c:532: no valid selection reloads.
    @Test func enterWithoutValidRowReloads_filebrowser_c_532() {
        let mode = make()
        #expect(act(mode, .ok, row: 99).0 == .reload)
        #expect(act(mode, .ok, row: nil).0 == .reload)
        #expect(opened.isEmpty)
    }

    // filebrowser.c:545-555: custom input that names a directory enters it.
    @Test func customInputDirectoryIsEntered_filebrowser_c_545() {
        let mode = make()
        let (result, _) = act(mode, .customInput, input: "/home/u/Docs")
        #expect(result == .reset)
        #expect(mode.currentDirectory == "/home/u/Docs")
    }

    // filebrowser.c:545: the input is path-expanded first.
    @Test func customInputExpandsTilde_filebrowser_c_545b() {
        let mode = make(directory: "/")
        setenv("HOME", "/home/u", 1)
        _ = act(mode, .customInput, input: "~/Docs")
        #expect(mode.currentDirectory == "/home/u/Docs")
    }

    // filebrowser.c:556-559, 543-544: a file, or a missing path, only reloads; no
    // input at all exits.
    @Test func customInputThatIsNotADirectory_filebrowser_c_556() {
        let mode = make()
        #expect(act(mode, .customInput, input: "/home/u/zeta.txt").0 == .reload)
        #expect(act(mode, .customInput, input: "/missing").0 == .reload)
        #expect(act(mode, .customInput, input: nil).0 == .exit)
        #expect(mode.currentDirectory == "/home/u")
        #expect(opened.isEmpty)
    }

    // filebrowser.c:561-565: delete toggles hidden entries and reloads.
    @Test func deleteEntryTogglesHidden_filebrowser_c_561() {
        let mode = make()
        #expect(act(mode, .deleteEntry, row: 0).0 == .reload)
        #expect(names(mode).contains(".config"))
        #expect(act(mode, .deleteEntry, row: 0).0 == .reload)
        #expect(!names(mode).contains(".config"))
    }

    // filebrowser.c:485-492, 496-497.
    @Test func cancelExitsAndCustomKeySwitchesMode_filebrowser_c_485() {
        let mode = make()
        #expect(act(mode, .cancel).0 == .exit)
        #expect(act(mode, .customKey(2)).0 == .switchTo(2))
    }

    // filebrowser.c:611-620: token matching is on the name.
    @Test func matchesOnTheName_filebrowser_c_611() {
        let mode = make()
        let matcher = Matcher(query: "alpha", options: MatchOptions())
        #expect(mode.matches(mode.rows[row(mode, "Alpha.md")], matcher: matcher))
        #expect(!mode.matches(mode.rows[row(mode, "Docs")], matcher: matcher))
    }

    // filebrowser.c:620-638 fetches an icon per entry by its path; the up row
    // shows the parent folder's, the root's own at the root.
    @Test func iconPathIsTheEntryPath_filebrowser_c_620() {
        let mode = make()
        #expect(mode.iconPath(at: 0) == "/home")
        #expect(mode.iconPath(at: row(mode, "Docs")) == "/home/u/Docs")
        #expect(mode.iconPath(at: row(mode, "zeta.txt")) == "/home/u/zeta.txt")
        #expect(mode.iconPath(at: mode.rows.count) == nil)
        #expect(make(directory: "/").iconPath(at: 0) == "/")
    }
}

// The real tree behind `FileBrowserMode`: readdir's types, links resolved by
// stat (filebrowser.c:253-345).
@Suite final class DiskFileSystemTests {
    private let root: String

    init() {
        let base = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp/"
        var template = Array(((base.hasSuffix("/") ? base : base + "/") + "rofi-fb-XXXXXX").utf8CString)
        root = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        mkdir(root + "/sub", 0o755)
        close(open(root + "/f.txt", O_CREAT | O_WRONLY, 0o644))
        symlink(root + "/sub", root + "/to-sub")
        symlink(root + "/f.txt", root + "/to-f")
        symlink(root + "/missing", root + "/broken")
        mkfifo(root + "/pipe", 0o644)
    }

    deinit {
        for name in ["f.txt", "to-sub", "to-f", "broken", "pipe"] { unlink(root + "/" + name) }
        rmdir(root + "/sub")
        rmdir(root)
    }

    @Test func listsKindsAndResolvesLinks() throws {
        let entries = try #require(DiskFileSystem().entries(in: root))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["sub"] == FileBrowserEntry(name: "sub", kind: .directory, isLink: false))
        #expect(byName["f.txt"] == FileBrowserEntry(name: "f.txt", kind: .file, isLink: false))
        #expect(byName["to-sub"] == FileBrowserEntry(name: "to-sub", kind: .directory, isLink: true))
        #expect(byName["to-f"] == FileBrowserEntry(name: "to-f", kind: .file, isLink: true))
        // filebrowser.c:309-340: a link that cannot be stat'ed stays a file.
        #expect(byName["broken"] == FileBrowserEntry(name: "broken", kind: .file, isLink: true))
        #expect(byName["pipe"]?.kind == .other)
        #expect(byName["."] == nil && byName[".."] == nil)
    }

    // helper.c:1426-1434: the real opener reports a failed `open`, with the
    // command quoted like g_shell_quote, without launching anything.
    @Test func systemOpenerReportsFailure_helper_c_1426() throws {
        let path = root + "/it's-missing"
        let result = openWithSystemOpener(path: path, directory: root)
        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.command == "/usr/bin/open '" + root + "/it'\\''s-missing'")
        #expect(failure.reason.contains("does not exist"))
    }

    @Test func queriesPaths() {
        let system = DiskFileSystem()
        #expect(system.entries(in: root + "/nope") == nil)
        #expect(system.isDirectory(root + "/to-sub"))
        #expect(!system.isDirectory(root + "/f.txt"))
        #expect(system.exists(root + "/f.txt"))
        #expect(!system.exists(root + "/missing"))
    }
}
