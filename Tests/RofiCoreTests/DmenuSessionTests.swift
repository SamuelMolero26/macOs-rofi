import Testing
import RofiCore

// Contract: dmenu startup and completion in rofi source/modes/dmenu.c:780-891
// and 989-1034; formatted output in source/helper.c:1693-1731.
@Suite struct DmenuSessionTests {
    private func pipeline(_ argv: [String] = []) throws -> DmenuPipeline {
        try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
    }

    private let fruit = ["apple", "Banana", "cherry"].map { Row(parsing: $0) }

    @Test func interactiveEmptyQueryIsARealFilterForCapitalF() throws {
        let pipeline = try pipeline(["-format", "[F]"])
        guard case .session(let session) = pipeline.start(rows: [Row(parsing: "entry")]) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
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
        let pipeline = try pipeline(["-matching", "prefix", "-i"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
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
        let pipeline = try pipeline()
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }

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
        let pipeline = try pipeline(["-format", "i:s:f"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.updateQuery("err") == nil)

        let completion = session.accept()

        #expect(completion?.output == "2:cherry:err\n")
        #expect(completion?.outcome == .accepted)
        #expect(completion?.outcome.exitCode == 0)
    }

    @Test func noSelectionDoesNotComplete() throws {
        let pipeline = try pipeline(["-no-custom"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        session.selectVisibleIndex(nil)

        #expect(session.accept() == nil)
    }

    @Test func nonselectableRowsStayVisibleButDoNotComplete() throws {
        var row = Row(parsing: "heading")
        row.nonselectable = true
        let pipeline = try pipeline(["-no-custom"])
        guard case .session(let session) = pipeline.start(rows: [row]) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }

        #expect(session.matches.map(\.row.text) == ["heading"])
        #expect(session.selectedVisibleIndex == 0)
        #expect(session.accept() == nil)
    }

    @Test func noCustomCancelCompletesWithoutOutputAndUsesExitOne() throws {
        let pipeline = try pipeline(["-no-custom"])
        guard case .session(let session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }

        let completion = session.cancel()

        #expect(completion?.output == nil)
        #expect(completion?.outcome == .cancelled)
        #expect(completion?.outcome.exitCode == 1)
    }

    @Test func onlyMatchCancelKeepsTheSessionOpen() throws {
        let pipeline = try pipeline(["-only-match"])
        guard case .session(let session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }

        #expect(session.cancel() == nil)
    }

    @Test func customInputUsesLiveQueryForEntryAndFilter() throws {
        let pipeline = try pipeline(["-format", "i:d:s:f"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.updateQuery("zzz") == nil)

        let completion = session.accept()

        #expect(completion?.output == "-1:0:zzz:zzz\n")
        #expect(completion?.outcome == .accepted)
    }

    @Test(arguments: ["-only-match", "-no-custom"])
    func flagsDisableCustomInput(flag: String) throws {
        let pipeline = try pipeline([flag])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
        #expect(session.updateQuery("zzz") == nil)

        #expect(session.accept() == nil)
    }

    @Test func selectedRowWinsOverCustomInput() throws {
        let pipeline = try pipeline(["-format", "i:d:s:f"])
        guard case .session(var session) = pipeline.start(rows: fruit) else {
            Issue.record("Expected an interactive dmenu session")
            return
        }
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
}
