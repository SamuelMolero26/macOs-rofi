import Testing
import RofiCore

// Contract: dmenu startup and completion in rofi source/modes/dmenu.c:780-891
// and 989-1034; formatted output in source/helper.c:1693-1731.
@Suite struct DmenuSessionTests {
    private func pipeline(_ argv: [String] = []) throws -> DmenuPipeline {
        try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
    }

    private let fruit = ["apple", "Banana", "cherry"].map { Row(parsing: $0) }

    // `start` is the only supported way to obtain a session, so the seeding
    // rule (query comes from `-filter`) stays owned by production code and is
    // never restated here.
    private func makeSession(_ argv: [String] = [], rows: [Row]? = nil) throws -> DmenuSession {
        let pipeline = try pipeline(argv)
        return try #require(
            pipeline.start(rows: rows ?? fruit).session,
            "Expected an interactive dmenu session"
        )
    }

    @Test func interactiveEmptyQueryIsARealFilterForCapitalF() throws {
        let session = try makeSession(["-format", "[F]"], rows: [Row(parsing: "entry")])
        #expect(session.query == "")
        #expect(session.accept()?.output == "['']\n")
    }

    @Test func startMatchesTheInitialFilterAndSelectsFirstVisibleRow() throws {
        let pipeline = try pipeline(["-filter", "an", "-i"])

        guard case .session(let session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.query == "an")
        #expect(session.matches.map(\.sourceIndex) == [1])
        #expect(session.selectedVisibleIndex == 0)
    }

    @Test func queryUpdateKeepsInputOrderAndResetsSelectionToFirstMatch() throws {
        var session = try makeSession(["-matching", "prefix", "-i"])
        session.selectVisibleIndex(2)

        #expect(session.updateQuery("ban") == nil)

        #expect(session.query == "ban")
        #expect(session.matches.map(\.sourceIndex) == [1])
        #expect(session.selectedVisibleIndex == 0)

        #expect(session.updateQuery("") == nil)
        #expect(session.matches.map(\.sourceIndex) == [0, 1, 2])
        #expect(session.selectedVisibleIndex == 0)
    }

    @Test func selectionMovementClampsAndSelectionCanBeExplicit() throws {
        var session = try makeSession()

        session.moveSelection(by: -1)
        #expect(session.selectedVisibleIndex == 0)
        session.moveSelection(by: 99)
        #expect(session.selectedVisibleIndex == 2)
        session.moveSelection(by: -1)
        #expect(session.selectedVisibleIndex == 1)
        session.selectVisibleIndex(2)
        #expect(session.selectedVisibleIndex == 2)
        session.selectVisibleIndex(nil)
        #expect(session.selectedVisibleIndex == nil)
        session.selectVisibleIndex(99)
        #expect(session.selectedVisibleIndex == nil)
    }

    @Test func acceptFormatsSelectedRowWithItsOriginalIndexAndLiveQuery() throws {
        var session = try makeSession(["-format", "i:s:f"])
        #expect(session.updateQuery("err") == nil)

        let completion = session.accept()

        #expect(completion?.output == "2:cherry:err\n")
        #expect(completion?.outcome == .accepted)
        #expect(completion?.outcome.exitCode == 0)
    }

    @Test func noSelectionDoesNotComplete() throws {
        var session = try makeSession(["-no-custom"])
        session.selectVisibleIndex(nil)

        #expect(session.accept() == nil)
    }

    @Test func nonselectableRowsStayVisibleButDoNotComplete() throws {
        var row = Row(parsing: "heading")
        row.nonselectable = true
        var session = try makeSession(rows: [row])
        #expect(session.updateQuery("head") == nil)

        #expect(session.matches.map(\.row.text) == ["heading"])
        #expect(session.selectedVisibleIndex == 0)
        #expect(session.accept() == nil)
    }

    @Test func noCustomCancelCompletesWithoutOutputAndUsesExitOne() throws {
        let session = try makeSession(["-no-custom"])

        let completion = session.cancel()

        #expect(completion?.output == nil)
        #expect(completion?.outcome == .cancelled)
        #expect(completion?.outcome.exitCode == 1)
    }

    @Test func onlyMatchCancelKeepsTheSessionOpen() throws {
        let session = try makeSession(["-only-match"])

        #expect(session.cancel() == nil)
    }

    @Test func customInputUsesLiveQueryForEntryAndFilter() throws {
        var session = try makeSession(["-format", "i:d:s:f"])
        #expect(session.updateQuery("zzz") == nil)

        let completion = session.accept()

        #expect(completion?.output == "-1:0:zzz:zzz\n")
        #expect(completion?.outcome == .accepted)
    }

    @Test(arguments: ["-only-match", "-no-custom"])
    func flagsDisableCustomInput(flag: String) throws {
        var session = try makeSession([flag])
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.accept() == nil)
    }

    @Test func selectedRowWinsOverCustomInput() throws {
        var session = try makeSession(["-format", "i:d:s:f"])
        #expect(session.updateQuery("app") == nil)

        #expect(session.accept()?.output == "0:1:apple:app\n")
    }

    @Test func autoSelectSingleUnmatchedRowCompletesWithoutSession() throws {
        let pipeline = try pipeline(["-auto-select", "-filter", "zzz", "-format", "i:s:f"])

        guard case .completed(let completion) = pipeline.start(rows: [Row(parsing: "only")]) else {
            Issue.record("Expected immediate auto-select completion")
            return
        }
        #expect(completion.output == "0:only:zzz\n")
        #expect(completion.outcome == .accepted)
    }

    @Test func autoSelectInitialUniqueFilteredRowCompletesWithoutSession() throws {
        let pipeline = try pipeline(["-auto-select", "-filter", "err", "-format", "i:s:f"])

        guard case .completed(let completion) = pipeline.start(rows: fruit) else {
            Issue.record("Expected immediate filtered auto-select completion")
            return
        }
        #expect(completion.output == "2:cherry:err\n")
        #expect(completion.outcome == .accepted)
    }

    @Test func queryUpdateAutoSelectsAUniqueFilteredRow() throws {
        let pipeline = try pipeline(["-auto-select", "-format", "i:s:f"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }

        let completion = session.updateQuery("err")

        #expect(completion?.output == "2:cherry:err\n")
        #expect(completion?.outcome == .accepted)
    }

    @Test(arguments: ["-only-match", "-no-custom"])
    func emptyCustomDisabledModeCompletesSuccessfullyWithoutOutput(flag: String) throws {
        let pipeline = try pipeline([flag])

        guard case .completed(let completion) = pipeline.start(rows: []) else {
            Issue.record("Expected immediate only-match completion")
            return
        }
        #expect(completion.output == nil)
        #expect(completion.outcome == .accepted)
        #expect(completion.outcome.exitCode == 0)
    }

    @Test func appendedMatchesContinueSourceIndicesAndFilterByTheLiveQuery() throws {
        let pipeline = try pipeline(["-i"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.updateQuery("an") == nil)

        session.appendRows(["mango", "kiwi", "orange"].map { Row(parsing: $0) })

        #expect(session.matches.map(\.sourceIndex) == [1, 3, 5])
        #expect(session.matches.map(\.row.text) == ["Banana", "mango", "orange"])
    }

    @Test func appendKeepsTheCurrentSelection() throws {
        let pipeline = try pipeline()
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        session.selectVisibleIndex(1)

        session.appendRows([Row(parsing: "date")])

        #expect(session.selectedVisibleIndex == 1)
    }

    @Test func appendSelectsTheFirstMatchOnceOneExists() throws {
        let pipeline = try pipeline(["-filter", "an"])
        guard case .session(var session) = pipeline.start(rows: []) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.selectedVisibleIndex == nil)

        session.appendRows([Row(parsing: "apple")])
        #expect(session.selectedVisibleIndex == nil)

        session.appendRows([Row(parsing: "Banana")])
        #expect(session.matches.map(\.sourceIndex) == [1])
        #expect(session.selectedVisibleIndex == 0)
    }

    @Test func queryUpdateRematchesEveryAppendedRow() throws {
        let pipeline = try pipeline(["-filter", "an"])
        guard case .session(var session) = pipeline.start(rows: []) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        session.appendRows(fruit)

        #expect(session.updateQuery("") == nil)

        #expect(session.matches.map(\.sourceIndex) == [0, 1, 2])
    }

    @Test func acceptOfAnAppendedRowFormatsItsOriginalIndex() throws {
        let pipeline = try pipeline(["-format", "i:s:f"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        session.appendRows([Row(parsing: "date")])
        #expect(session.updateQuery("dat") == nil)

        #expect(session.accept()?.output == "3:date:dat\n")
    }

    // Contract: rofi_view_set_selected_line maps a source row to its visible
    // position, or the first visible row when it is filtered out or out of
    // range (source/view.c:369-383, source/modes/dmenu.c:1056).
    @Test(arguments: [
        ([], 2, 2),
        (["-filter", "e"], 2, 1),    // visible rows are apple, cherry
        (["-filter", "e"], 1, 0),    // Banana is filtered out
        ([], 9, 0),                  // out of range
    ] as [([String], Int, Int)])
    func selectedRowSelectsItsVisiblePosition(flags: [String], row: Int, visible: Int) throws {
        let session = try makeSession(flags + ["-selected-row", String(row)])

        #expect(session.selectedVisibleIndex == visible)
    }

    @Test func selectChoosesTheFirstMatchingRowForAccept() throws {
        let session = try makeSession(["-select", "rr", "-format", "i:s"])

        #expect(session.selectedVisibleIndex == 2)
        #expect(session.accept()?.output == "2:cherry\n")
    }

    @Test func queryUpdatesStillResetToTheFirstMatch() throws {
        var session = try makeSession(["-selected-row", "2"])
        #expect(session.updateQuery("a") == nil)

        #expect(session.selectedVisibleIndex == 0)
    }

    // Contract: get_display_data ORs the -a/-u range membership with the row's
    // own active/urgent extras (source/modes/dmenu.c:436-466).
    @Test func activeAndUrgentCombineRangesWithRowExtras() throws {
        var flagged = Row(parsing: "date")
        flagged.urgent = true
        let rows = fruit + [flagged]
        let session = try makeSession(["-a", "0,2", "-u", "1"], rows: rows)

        #expect(session.matches.map { session.state(of: $0) } == [
            .active, .urgent, .active, .urgent,
        ])
    }

    // Negative ranges resolve against the rows loaded so far, as upstream
    // reads cmd_list_length on every redraw (source/modes/dmenu.c:441-443).
    @Test func negativeRangesFollowAppendedRows() throws {
        var session = try makeSession(["-a", "-1"])
        #expect(session.matches.map { session.state(of: $0) } == [[], [], .active])

        session.appendRows([Row(parsing: "date")])

        #expect(session.matches.map { session.state(of: $0) } == [[], [], [], .active])
    }
}

private extension DmenuStart {
    /// The session when `start` did not resolve a command-line shortcut.
    var session: DmenuSession? {
        if case .session(let session) = self { return session }
        return nil
    }
}
