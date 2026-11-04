// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

/// An in-memory set of application folders: `contents` lists the readable
/// directories, `infos` the Info.plist of each bundle.
private final class FakeApps: AppBundleSource {
    var contents: [String: [FileBrowserEntry]] = [:]
    var infos: [String: AppBundleInfo] = [:]

    func entries(in path: String) -> [FileBrowserEntry]? { contents[path] }

    func info(ofBundle path: String) -> AppBundleInfo { infos[path] ?? AppBundleInfo() }
}

private func dir(_ name: String, link: Bool = false) -> FileBrowserEntry {
    FileBrowserEntry(name: name, kind: .directory, isLink: link)
}

private func file(_ name: String) -> FileBrowserEntry {
    FileBrowserEntry(name: name, kind: .file, isLink: false)
}

// Contract: rofi's drun mode, source/modes/drun.c (walk_dir 818-877, history
// 883-910, sort 912-930, setup 1241-1244, result 1360-1449), with `.app`
// bundles in place of .desktop files.
@Suite final class DrunModeTests {
    private let apps = FakeApps()
    private var opened: [String] = []
    /// What the injected opener answers.
    private var openResult: Result<Void, FileBrowserOpenFailure> = .success(())

    init() {
        apps.contents["/Applications"] = [
            dir("Zeta.app"), dir("alpha.app"), dir("Folder"), dir(".Hidden.app"), file("readme.txt"),
            dir("Linked.app", link: true), dir("linked-folder", link: true), dir("Utilities"),
        ]
        apps.contents["/Applications/Folder"] = [dir("Nested.app")]
        apps.contents["/Applications/Zeta.app"] = [dir("Inner.app")]
        apps.contents["/Applications/linked-folder"] = [dir("Loop.app")]
        apps.contents["/Applications/Utilities"] = [dir("Terminal.app")]
        apps.contents["/System/Applications"] = [dir("Beta.app"), dir("Dup.app")]
        apps.contents["/Users/u/Applications"] = [dir("Dup.app")]
        apps.infos["/Applications/Zeta.app"] = AppBundleInfo(identifier: "z", displayName: "Zeta", name: "Z")
        apps.infos["/Applications/alpha.app"] = AppBundleInfo(identifier: "a", displayName: "", name: "alpha")
        apps.infos["/Applications/Folder/Nested.app"] = AppBundleInfo(identifier: "n")
        apps.infos["/Applications/Utilities/Terminal.app"] = AppBundleInfo(identifier: "t", name: "Terminal")
        apps.infos["/System/Applications/Beta.app"] = AppBundleInfo(identifier: "b", name: "Beta")
        apps.infos["/System/Applications/Dup.app"] = AppBundleInfo(identifier: "d", name: "Dup System")
        apps.infos["/Users/u/Applications/Dup.app"] = AppBundleInfo(identifier: "d", name: "Dup Home")
    }

    private func make(history: History? = nil) -> DrunMode {
        DrunMode(
            home: "/Users/u", history: history, source: apps,
            opener: { [unowned self] path, _ in
                opened.append(path)
                return openResult
            })
    }

    private func names(_ mode: DrunMode) -> [String] { mode.rows.map(\.text) }

    private func row(_ mode: DrunMode, _ name: String) -> Int {
        mode.rows.firstIndex { $0.text == name }!
    }

    private func act(_ mode: DrunMode, _ action: MenuAction, input: String? = nil, row: Int? = nil) -> ModeResult {
        var input = input
        return mode.result(action, input: &input, selectedRow: row)
    }

    /// A history file in a fresh directory, seeded with `contents`.
    private func withHistory(_ contents: String? = nil, _ body: (History) throws -> Void) throws {
        let name = "rofi-drun-\(UInt64.random(in: .min ... .max))/rofi3.druncache"
        let history = History(url: .temporaryDirectory.appending(path: name))
        let dir = history.url.deletingLastPathComponent().path(percentEncoded: false)
        let file = history.url.path(percentEncoded: false)
        try #require(mkdir(dir, 0o700) == 0)
        defer {
            unlink(file)
            rmdir(dir)
        }
        if let contents {
            let fd = try #require(fopen(file, "w"))
            fputs(contents, fd)
            fclose(fd)
        }
        try body(history)
    }

    @Test func nameIsDrun_drun_c_1693() {
        #expect(make().name == "drun")
    }

    // drun.c:818-877: every application folder is walked, plain folders
    // recursively; hidden names and plain files are skipped. A bundle is
    // never descended into, and a linked folder is not followed.
    @Test func scansFoldersButNotBundles_drun_c_818() {
        #expect(names(make()) == ["alpha", "Beta", "Dup System", "Linked", "Nested", "Terminal", "Zeta"])
    }

    // CFBundleDisplayName, then CFBundleName, then the bundle's file name;
    // empty values count as missing.
    @Test func displayNameFallsBackToBundleNameThenFileName() {
        let mode = make()
        #expect(names(mode).contains("Zeta"))
        #expect(names(mode).contains("alpha"))
        #expect(names(mode).contains("Nested"))
        #expect(mode.rows.allSatisfy { $0.display == nil })
    }

    // drun.c:519-523 skips a desktop id already seen; the bundle id plays
    // that part, so the first folder wins.
    @Test func duplicateBundleIdsKeepTheFirstFolder_drun_c_519() {
        let mode = make()
        #expect(names(mode).filter { $0.hasPrefix("Dup") } == ["Dup System"])
        #expect(act(mode, .ok, row: row(mode, "Dup System")) == .exit)
        #expect(opened == ["/System/Applications/Dup.app"])
    }

    // drun.c:1390-1397 launches the entry; here `open` launches the bundle
    // and the switcher closes.
    @Test func enterOpensTheBundleAndExits_drun_c_1390() {
        let mode = make()
        #expect(act(mode, .ok, row: row(mode, "Nested")) == .exit)
        #expect(opened == ["/Applications/Folder/Nested.app"])
        #expect(mode.message == nil)
    }

    // helper.c:1426-1434 shows an error dialog; as in the file browser the
    // failure is the message and the view stays open until the next action.
    @Test func failedLaunchIsShownAndKeepsTheViewOpen_helper_c_1426() {
        openResult = .failure(FileBrowserOpenFailure(command: "/usr/bin/open 'x'", reason: "boom"))
        let mode = make()
        #expect(act(mode, .ok, row: row(mode, "Zeta")) == .reload)
        #expect(mode.message == "Failed to execute: '/usr/bin/open 'x''\nError: 'boom'")
        #expect(act(mode, .deleteEntry, row: row(mode, "Zeta")) == .reload)
        #expect(mode.message == nil)
    }

    @Test func enterWithoutARowReloads() {
        let mode = make()
        #expect(act(mode, .ok, row: nil) == .reload)
        #expect(act(mode, .ok, row: 99) == .reload)
        #expect(opened.isEmpty)
    }

    // drun.c:476-481: a launch bumps the bundle id in the history.
    @Test func launchRecordsTheBundleIdInHistory_drun_c_476() throws {
        try withHistory { history in
            let mode = make(history: history)
            _ = act(mode, .ok, row: row(mode, "Beta"))
            #expect(history.list() == ["b"])
        }
    }

    @Test func failedLaunchRecordsNothing_drun_c_476() throws {
        openResult = .failure(FileBrowserOpenFailure(command: "c", reason: "r"))
        try withHistory { history in
            let mode = make(history: history)
            _ = act(mode, .ok, row: row(mode, "Beta"))
            #expect(history.list() == [])
        }
    }

    // drun.c:889-930, 1241-1244: history entries come first in history order,
    // the rest by name.
    @Test func historyEntriesSortFirst_drun_c_912() throws {
        try withHistory("3 t\n1 z\n0 gone\n") { history in
            #expect(
                names(make(history: history)) == [
                    "Terminal", "Zeta", "alpha", "Beta", "Dup System", "Linked", "Nested",
                ])
        }
    }

    // drun.c:1411-1423: deleting an entry in the history removes it from the
    // history and the list; any other entry stays.
    @Test func deleteRemovesHistoryEntries_drun_c_1411() throws {
        try withHistory("1 t\n0 z\n") { history in
            let mode = make(history: history)
            #expect(act(mode, .deleteEntry, row: row(mode, "Terminal")) == .reload)
            #expect(history.list() == ["z"])
            #expect(!names(mode).contains("Terminal"))
            #expect(act(mode, .deleteEntry, row: row(mode, "Beta")) == .reload)
            #expect(names(mode).contains("Beta"))
            #expect(history.list() == ["z"])
            #expect(act(mode, .ok, row: row(mode, "Zeta")) == .exit)
            #expect(opened == ["/Applications/Zeta.app"])
        }
    }

    @Test func deleteWithoutHistoryKeepsTheRow_drun_c_1411() {
        let mode = make()
        #expect(act(mode, .deleteEntry, row: row(mode, "Zeta")) == .reload)
        #expect(names(mode).contains("Zeta"))
    }

    // drun.c:1362, 1424-1425: cancel exits, a custom key switches modes.
    @Test func cancelExitsAndCustomKeysSwitch_drun_c_1424() {
        #expect(act(make(), .cancel) == .exit)
        #expect(act(make(), .customKey(3)) == .switchTo(3))
    }

    // drun.c:1402-1410: typed text is run as a command; here that is not
    // supported, so it says so and stays. No text exits.
    @Test func customInputIsReportedNotRun_drun_c_1402() {
        let mode = make()
        #expect(act(mode, .customInput, input: "firefox") == .reload)
        #expect(mode.message == "Failed to execute: 'firefox'\nError: 'drun cannot run typed commands'")
        #expect(opened.isEmpty)
        #expect(act(mode, .customInput, input: nil) == .exit)
        #expect(act(mode, .customInput, input: "") == .exit)
    }
}
