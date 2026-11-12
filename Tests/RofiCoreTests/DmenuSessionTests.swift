import RofiCore
import Testing

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

    // Upstream cycles by default; `-no-cycle` restores the clamp (config/config.c:115).
    @Test func singleStepMovementWrapsByDefault() throws {
        var session = try makeSession()
        session.moveSelection(by: -1)
        #expect(session.selectedVisibleIndex == 2)
        session.moveSelection(by: 1)
        #expect(session.selectedVisibleIndex == 0)
    }

    @Test func selectionMovementClampsAndSelectionCanBeExplicit() throws {
        var session = try makeSession(["-no-cycle"])

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

    // Interactive auto-select fires MENU_OK (source/view.c:934-940), and
    // dmenu_finalize refuses a nonselectable row without finishing
    // (source/modes/dmenu.c:883-886, 913-916): nothing prints, the dialog stays.
    @Test func autoSelectInitialFilterRefusesUniqueNonselectableRow() throws {
        var heading = Row(parsing: "cherry")
        heading.nonselectable = true
        let pipeline = try pipeline(["-auto-select", "-filter", "err"])

        guard case .session(let session) = pipeline.start(rows: [fruit[0], fruit[1], heading]) else {
            Issue.record("Expected the session to stay open on a nonselectable unique match")
            return
        }
        #expect(session.matches.map(\.sourceIndex) == [2])
    }

    @Test func queryUpdateAutoSelectRefusesNonselectableButNotLaterSelectableRow() throws {
        var heading = Row(parsing: "cherry")
        heading.nonselectable = true
        var session = try makeSession(["-auto-select", "-format", "i:s"], rows: [fruit[0], fruit[1], heading])

        #expect(session.updateQuery("err") == nil)
        #expect(session.updateQuery("Ban")?.output == "1:Banana\n")
    }

    // The pre-UI shortcut prints cmd_list[0] with no nonselectable check
    // (source/modes/dmenu.c:995-998), so a single-row input still completes.
    @Test func autoSelectSingleRowInputIgnoresNonselectable() throws {
        var only = Row(parsing: "only")
        only.nonselectable = true
        let pipeline = try pipeline(["-auto-select"])

        guard case .completed(let completion) = pipeline.start(rows: [only]) else {
            Issue.record("Expected the pre-UI auto-select shortcut to complete")
            return
        }
        #expect(completion.output == "only\n")
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

    @Test func appendedRowsRerankTheCompleteMatchSet() throws {
        var session = try makeSession(
            ["-sort", "-sorting-method", "levenshtein", "-filter", "foo"],
            rows: [Row(parsing: "food")])

        session.appendRows([Row(parsing: "foo")])

        #expect(session.matches.map(\.sourceIndex) == [1, 0])
        #expect(session.matches.map(\.row.text) == ["foo", "food"])
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
    @Test(
        arguments: [
            ([], 2, 2),
            (["-filter", "e"], 2, 1),  // visible rows are apple, cherry
            (["-filter", "e"], 1, 0),  // Banana is filtered out
            ([], 9, 0),  // out of range
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

        #expect(
            session.matches.map { session.state(of: $0) } == [
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

    // MARK: -multi-select, kb-accept-alt (Shift+Return, source/keyb.c:127-130)
    // in dmenu_finalize (source/modes/dmenu.c:833-952).

    @Test func rowsShowTheirTextWithoutMultiSelect() throws {
        let session = try makeSession()

        #expect(session.matches.map { session.displayText(for: $0) } == ["apple", "Banana", "cherry"])
    }

    // Contract: dmenu_format_output_string (source/modes/dmenu.c:365-376).
    @Test func multiSelectPrefixesEveryRowWithItsBallot() throws {
        var session = try makeSession(["-multi-select", "-ballot-selected-str", "[x] "])
        #expect(session.acceptAlternate() == nil)

        #expect(session.matches.map { session.displayText(for: $0) } == ["[x] apple", "☐ Banana", "☐ cherry"])
    }

    @Test func toggleMovesToTheNextVisibleRowAndStopsAtTheLast() throws {
        var session = try makeSession(["-multi-select"])
        #expect(session.acceptAlternate() == nil)
        #expect(session.selectedVisibleIndex == 1)

        session.selectVisibleIndex(2)
        #expect(session.acceptAlternate() == nil)

        #expect(session.selectedVisibleIndex == 2)
        #expect(session.matches.map { session.state(of: $0) } == [.selected, [], .selected])
    }

    // The overlay counts toggled rows against every loaded row
    // (source/modes/dmenu.c:936-943).
    @Test func toggleCountsSelectionsInTheOverlayAndUntoggles() throws {
        var session = try makeSession(["-multi-select"])
        #expect(session.selectionOverlay == nil)

        #expect(session.acceptAlternate() == nil)
        #expect(session.selectionOverlay == "1/3")
        #expect(session.acceptAlternate() == nil)
        #expect(session.selectionOverlay == "2/3")

        session.selectVisibleIndex(0)
        #expect(session.acceptAlternate() == nil)

        #expect(session.selectionOverlay == "1/3")
        #expect(session.matches.map { session.state(of: $0) } == [[], .selected, []])
        session.selectVisibleIndex(1)
        #expect(session.acceptAlternate() == nil)
        #expect(session.selectionOverlay == nil)
    }

    // Contract: dmenu_print_results prints every toggled row in input order,
    // whatever is highlighted, and only falls back to the highlighted row or
    // custom input when nothing is toggled (source/modes/dmenu.c:808-826).
    @Test func acceptPrintsToggledRowsInInputOrder() throws {
        var session = try makeSession(["-multi-select", "-format", "i:s:f"])
        session.selectVisibleIndex(2)
        #expect(session.acceptAlternate() == nil)
        session.selectVisibleIndex(0)
        #expect(session.acceptAlternate() == nil)
        #expect(session.updateQuery("an") == nil)

        #expect(session.accept() == DmenuCompletion(output: "0:apple:an\n2:cherry:an\n", outcome: .accepted))
    }

    @Test func customInputPrintsToggledRowsInstead() throws {
        var session = try makeSession(["-multi-select", "-format", "s:f"])
        #expect(session.acceptAlternate() == nil)
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.accept()?.output == "apple:zzz\n")
        #expect(session.acceptAlternate()?.output == "apple:zzz\n")
    }

    @Test func untoggledRowsFallBackToTheHighlightedRow() throws {
        var session = try makeSession(["-multi-select", "-format", "i:s"])
        #expect(session.acceptAlternate() == nil)
        session.selectVisibleIndex(0)
        #expect(session.acceptAlternate() == nil)

        #expect(session.accept()?.output == "1:Banana\n")
    }

    // Without -multi-select, Shift+Return prints like Return
    // (source/modes/dmenu.c:880-892, 944-946).
    @Test(arguments: [[], ["-no-custom"]])
    func acceptAlternateWithoutMultiSelectAccepts(flags: [String]) throws {
        var session = try makeSession(flags + ["-format", "i:s"])
        session.selectVisibleIndex(1)

        #expect(session.acceptAlternate() == DmenuCompletion(output: "1:Banana\n", outcome: .accepted))
        #expect(session.selectionOverlay == nil)
    }

    @Test func acceptAlternateWithNoMatchIsCustomInput() throws {
        var session = try makeSession(["-multi-select", "-format", "i:s"])
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.acceptAlternate()?.output == "-1:zzz\n")
    }

    @Test func noCustomAcceptAlternateWithNoMatchKeepsTheSessionOpen() throws {
        var session = try makeSession(["-multi-select", "-no-custom"])
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.acceptAlternate() == nil)
        #expect(session.selectionOverlay == nil)
    }

    // The #21 rule: Return on a highlighted nonselectable row prints nothing,
    // even with toggled rows (source/modes/dmenu.c:910-916).
    @Test func nonselectableHighlightBlocksAcceptAndToggle() throws {
        var heading = Row(parsing: "heading")
        heading.nonselectable = true
        var session = try makeSession(["-multi-select"], rows: [Row(parsing: "apple"), heading])
        #expect(session.acceptAlternate() == nil)
        #expect(session.selectedVisibleIndex == 1)

        #expect(session.acceptAlternate() == nil)
        #expect(session.accept() == nil)
        #expect(session.selectionOverlay == "1/2")
        #expect(session.matches.map { session.state(of: $0) } == [.selected, []])
    }

    // Upstream's -no-custom/-only-match branch toggles before it checks
    // nonselectable (source/modes/dmenu.c:853 before 883).
    @Test(arguments: ["-no-custom", "-only-match"])
    func customDisabledModesToggleNonselectableRows(flag: String) throws {
        var heading = Row(parsing: "heading")
        heading.nonselectable = true
        var session = try makeSession(["-multi-select", flag, "-format", "s"], rows: [heading, Row(parsing: "apple")])

        #expect(session.acceptAlternate() == nil)

        #expect(session.selectionOverlay == "1/2")
        #expect(session.selectedVisibleIndex == 1)
        // Return still refuses a highlighted nonselectable row.
        session.selectVisibleIndex(0)
        #expect(session.accept() == nil)
        session.selectVisibleIndex(1)
        #expect(session.accept()?.output == "heading\n")
    }

    @Test func togglesSurviveAppendedRows() throws {
        var session = try makeSession(["-multi-select", "-format", "i"])
        #expect(session.acceptAlternate() == nil)
        session.appendRows([Row(parsing: "date")])
        session.selectVisibleIndex(3)
        #expect(session.acceptAlternate() == nil)

        #expect(session.selectionOverlay == "2/4")
        #expect(session.accept()?.output == "0\n3\n")
    }

    // MARK: Keymap actions: source/view.c:1148-1199, 1280-1306 set the return
    // value, dmenu_finalize acts on it (source/modes/dmenu.c:839-965).

    // MENU_CUSTOM_COMMAND prints the highlighted row and exits 10 + N - 1
    // (source/modes/dmenu.c:957-961, 796-799).
    @Test func customKeyPrintsTheHighlightedRowWithItsExitCode() throws {
        var session = try makeSession(["-format", "i:s"])
        session.selectVisibleIndex(1)

        let completion = session.perform(.customKey(1))

        #expect(completion == DmenuCompletion(output: "1:Banana\n", outcome: .customKey(1)))
        #expect(completion?.outcome.exitCode == 10)
        let last = session.perform(.customKey(19))
        #expect(last?.outcome.exitCode == 28)
    }

    // With no row, dmenu_print_results falls back to the input
    // (source/modes/dmenu.c:817-825, view.c:1194-1198).
    @Test func customKeyWithoutARowPrintsTheQuery() throws {
        var session = try makeSession(["-format", "i:s"])
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.perform(.customKey(2)) == DmenuCompletion(output: "-1:zzz\n", outcome: .customKey(2)))
    }

    // Normal mode does not check nonselectable rows for MENU_CUSTOM_COMMAND
    // (source/modes/dmenu.c:957-961); -no-custom does (883-886).
    @Test func customKeyOnANonselectableRowOnlyCompletesInNormalMode() throws {
        var row = Row(parsing: "heading")
        row.nonselectable = true
        var normal = try makeSession(rows: [row])
        var noCustom = try makeSession(["-no-custom"], rows: [row])

        #expect(normal.perform(.customKey(3)) == DmenuCompletion(output: "heading\n", outcome: .customKey(3)))
        #expect(noCustom.perform(.customKey(3)) == nil)
    }

    // -no-custom/-only-match restart without a row (source/modes/dmenu.c:847-899).
    @Test(arguments: ["-no-custom", "-only-match"])
    func customKeyWithoutARowKeepsOnlyMatchOpen(flag: String) throws {
        var session = try makeSession([flag])
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.perform(.customKey(1)) == nil)
    }

    @Test func customKeyPrintsToggledRows() throws {
        var session = try makeSession(["-multi-select", "-format", "i"])
        #expect(session.acceptAlternate() == nil)
        #expect(session.acceptAlternate() == nil)

        #expect(session.perform(.customKey(4)) == DmenuCompletion(output: "0\n1\n", outcome: .customKey(4)))
    }

    // kb-accept-custom and kb-accept-custom-alt drop the selection and return
    // MENU_CUSTOM_INPUT (view.c:1295-1306); dmenu prints the input
    // (source/modes/dmenu.c:951-955).
    @Test(arguments: [KeyAction.acceptCustom, .acceptCustomAlt])
    func acceptCustomPrintsTheQueryOverTheHighlightedRow(action: KeyAction) throws {
        var session = try makeSession(["-format", "i:s"])
        #expect(session.updateQuery("a") == nil)
        #expect(session.selectedVisibleIndex == 0)

        #expect(session.perform(action) == DmenuCompletion(output: "-1:a\n", outcome: .accepted))
    }

    @Test(arguments: [KeyAction.acceptCustom, .acceptCustomAlt], ["-no-custom", "-only-match"])
    func acceptCustomIsRefusedWithoutCustomInput(action: KeyAction, flag: String) throws {
        var session = try makeSession([flag])

        #expect(session.perform(action) == nil)
    }

    @Test func acceptCustomPrintsToggledRows() throws {
        var session = try makeSession(["-multi-select", "-format", "s"])
        #expect(session.acceptAlternate() == nil)
        #expect(session.updateQuery("zzz") == nil)

        let completion = session.perform(.acceptCustom)
        #expect(completion?.output == "apple\n")
    }

    @Test func acceptAltIsAcceptAlternate() throws {
        var session = try makeSession(["-multi-select"])

        #expect(session.perform(.acceptAlt) == nil)
        #expect(session.selectionOverlay == "1/3")
    }

    // MENU_ENTRY_DELETE matches no branch in normal mode, so dmenu finishes
    // with FALSE: no output, exit 1 (source/modes/dmenu.c:896-965, 796-797).
    // Without a visible row view.c:1148-1155 ignores the key.
    @Test func deleteEntryEndsNormalModeLikeCancel() throws {
        var session = try makeSession()

        #expect(session.perform(.deleteEntry) == DmenuCompletion(output: nil, outcome: .cancelled))
        #expect(session.updateQuery("zzz") == nil)
        #expect(session.perform(.deleteEntry) == nil)
    }

    // -no-custom/-only-match restart on it (source/modes/dmenu.c:893-899).
    @Test(arguments: ["-no-custom", "-only-match"])
    func deleteEntryKeepsOnlySelectedModeOpen(flag: String) throws {
        var session = try makeSession([flag])

        #expect(session.perform(.deleteEntry) == nil)
    }

    // kb-mode-complete quits the view with MENU_COMPLETE, with or without a
    // visible row (source/view.c:1128-1136). dmenu has no branch for it, so
    // normal mode finishes with FALSE: no output, exit 1
    // (source/modes/dmenu.c:906-964, 796-797).
    @Test func modeCompleteEndsNormalModeLikeCancel_dmenu_c_964() throws {
        var session = try makeSession()

        #expect(session.perform(.modeComplete) == DmenuCompletion(output: nil, outcome: .cancelled))
        #expect(session.updateQuery("zzz") == nil)
        #expect(session.perform(.modeComplete) == DmenuCompletion(output: nil, outcome: .cancelled))
    }

    // -no-custom/-only-match restart on it (source/modes/dmenu.c:843-902).
    @Test(arguments: ["-no-custom", "-only-match"])
    func modeCompleteKeepsOnlySelectedModeOpen_dmenu_c_897(flag: String) throws {
        var session = try makeSession([flag])

        #expect(session.perform(.modeComplete) == nil)
    }
}

extension DmenuStart {
    /// The session when `start` did not resolve a command-line shortcut.
    fileprivate var session: DmenuSession? {
        if case .session(let session) = self { return session }
        return nil
    }
}
