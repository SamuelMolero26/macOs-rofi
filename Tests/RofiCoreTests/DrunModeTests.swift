// Not Foundation: see HistoryTests.swift.
import Darwin
import RofiCore
import Testing

// Contract: rofi's drun mode, source/modes/drun.c (history 883-910, sort
// 912-930, setup 1241-1244, result 1360-1449), with native application
// records in place of .desktop files.
@Suite final class DrunModeTests {
    private let applications = [
        ApplicationRecord(
            identifier: "z", localizedDisplayName: "Zeta", bundleName: "Z",
            bundlePath: "/Applications/Zeta.app"),
        ApplicationRecord(
            identifier: "a", localizedDisplayName: "", bundleName: "alpha",
            bundlePath: "/Applications/alpha.app"),
        ApplicationRecord(
            identifier: "n", localizedDisplayName: nil, bundleName: nil,
            bundlePath: "/Applications/Folder/Nested.app", iconPath: "/icons/Nested.icns"),
        ApplicationRecord(
            identifier: "t", localizedDisplayName: nil, bundleName: "Terminal",
            bundlePath: "/Applications/Utilities/Terminal.app"),
        ApplicationRecord(
            identifier: "b", localizedDisplayName: nil, bundleName: "Beta",
            bundlePath: "/System/Applications/Beta.app"),
        ApplicationRecord(
            identifier: "d", localizedDisplayName: nil, bundleName: "Dup System",
            bundlePath: "/System/Applications/Dup.app"),
        ApplicationRecord(
            identifier: "d", localizedDisplayName: nil, bundleName: "Dup Home",
            bundlePath: "/Users/u/Applications/Dup.app"),
    ]
    private var launched: [ApplicationRecord] = []
    /// What the injected launcher answers.
    private var launchResult: Result<Void, ApplicationLaunchFailure> = .success(())

    private func make(history: History? = nil) -> DrunMode {
        DrunMode(
            applications: applications, history: history,
            launcher: { [unowned self] application in
                launched.append(application)
                return launchResult
            })
    }

    private func names(_ mode: DrunMode) -> [String] { mode.rows.map(\.text) }

    private func row(_ mode: DrunMode, _ name: String) -> Int {
        mode.rows.firstIndex { $0.text == name }!
    }

    private func act(
        _ mode: DrunMode, _ action: MenuAction, input: String? = nil, row: Int? = nil
    ) -> ModeResult {
        var input = input
        return mode.result(action, input: &input, selectedRow: row)
    }

    /// A history file in a fresh directory, seeded with `contents`.
    private func withHistory(_ contents: String? = nil, _ body: (History) throws -> Void) throws {
        let name = "rofi-drun-\(UInt64.random(in: .min ... .max))/rofi3.druncache"
        let history = History(url: .temporaryDirectory.appending(path: name))
        let directory = history.url.deletingLastPathComponent().path(percentEncoded: false)
        let file = history.url.path(percentEncoded: false)
        try #require(mkdir(directory, 0o700) == 0)
        defer {
            unlink(file)
            rmdir(directory)
        }
        if let contents {
            let handle = try #require(fopen(file, "w"))
            fputs(contents, handle)
            fclose(handle)
        }
        try body(history)
    }

    @Test func applicationRecordsPreferDisplayNameThenBundleNameThenFileName() {
        #expect(applications[0].displayName == "Zeta")
        #expect(applications[1].displayName == "alpha")
        #expect(applications[2].displayName == "Nested")

        let fallback = ApplicationRecord(
            identifier: "", localizedDisplayName: "", bundleName: "",
            bundlePath: "/Applications/Fallback.app")
        #expect(fallback.identifier == "/Applications/Fallback.app")
        #expect(fallback.displayName == "Fallback")
        #expect(fallback.iconPath == "/Applications/Fallback.app")
    }

    @Test func nameIsDrun_drun_c_1693() {
        #expect(make().name == "drun")
    }

    @Test func recordsAreDeduplicatedByIdentifierAndSortedByName_drun_c_519() {
        let mode = make()
        #expect(names(mode) == ["alpha", "Beta", "Dup System", "Nested", "Terminal", "Zeta"])
        #expect(act(mode, .ok, row: row(mode, "Dup System")) == .exit)
        #expect(launched.map(\.bundlePath) == ["/System/Applications/Dup.app"])
    }

    // drun.c:1390-1397 launches the entry and closes the switcher.
    @Test func enterLaunchesTheApplicationRecordAndExits_drun_c_1390() {
        let mode = make()
        #expect(act(mode, .ok, row: row(mode, "Nested")) == .exit)
        #expect(launched.map(\.identifier) == ["n"])
        #expect(mode.message == nil)
    }

    // helper.c:1426-1434 shows an error dialog; the failure is the message and
    // the view stays open until the next action.
    @Test func failedLaunchIsShownAndKeepsTheViewOpen_helper_c_1426() {
        launchResult = .failure(
            ApplicationLaunchFailure(command: "/usr/bin/open 'x'", reason: "boom"))
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
        #expect(launched.isEmpty)
    }

    // drun.c:476-481: a launch bumps the application identifier in history.
    @Test func launchRecordsTheApplicationIdentifierInHistory_drun_c_476() throws {
        try withHistory { history in
            let mode = make(history: history)
            _ = act(mode, .ok, row: row(mode, "Beta"))
            #expect(history.list() == ["b"])
        }
    }

    @Test func failedLaunchRecordsNothing_drun_c_476() throws {
        launchResult = .failure(ApplicationLaunchFailure(command: "c", reason: "r"))
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
                    "Terminal", "Zeta", "alpha", "Beta", "Dup System", "Nested",
                ])
        }
    }

    // drun.c:1411-1423: deleting an entry in history removes it from the
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
        }
    }

    @Test func deleteWithoutHistoryKeepsTheRow_drun_c_1411() {
        let mode = make()
        #expect(act(mode, .deleteEntry, row: row(mode, "Zeta")) == .reload)
        #expect(names(mode).contains("Zeta"))
    }

    @Test func cancelExitsAndCustomKeysSwitch_drun_c_1424() {
        #expect(act(make(), .cancel) == .exit)
        #expect(act(make(), .customKey(3)) == .switchTo(3))
    }

    @Test func customInputIsReportedNotRun_drun_c_1402() {
        let mode = make()
        #expect(act(mode, .customInput, input: "firefox") == .reload)
        #expect(mode.message == "Failed to execute: 'firefox'\nError: 'drun cannot run typed commands'")
        #expect(launched.isEmpty)
        #expect(act(mode, .customInput, input: nil) == .exit)
        #expect(act(mode, .customInput, input: "") == .exit)
    }

    @Test func iconPathComesFromTheApplicationRecord() {
        let mode = make()
        #expect(mode.iconPath(at: row(mode, "Nested")) == "/icons/Nested.icns")
        #expect(mode.iconPath(at: mode.rows.count) == nil)
    }
}
