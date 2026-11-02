import Testing
import RofiCore

// Contract: dmenu matching and dump projection in rofi
// source/modes/dmenu.c:605-608 and 989-1034; formatted output in
// source/helper.c:1693-1731.
@Suite struct DmenuPipelineTests {
    private func pipeline(_ argv: [String] = []) throws -> DmenuPipeline {
        try DmenuPipeline(arguments: Arguments(["rofi", "-dmenu"] + argv))
    }

    private let fruit = ["apple", "Banana", "cherry"].map { Row(parsing: $0) }

    @Test func matchingRowsExposeOriginalIndicesInInputOrder() throws {
        let pipeline = try pipeline(["-i"])

        let matches = pipeline.matchingRows(in: fruit, query: "an")

        #expect(matches.map(\.sourceIndex) == [1])
        #expect(matches.map(\.row.text) == ["Banana"])
    }

    @Test func formattedOutputUsesOriginalIndexAndSuppliedLiveFilter() throws {
        let pipeline = try pipeline(["-format", "i:d:s:f:F", "-filter", "stale"])
        let match = DmenuMatch(sourceIndex: 4, row: Row(parsing: "entry"))

        #expect(pipeline.formattedOutput(for: match, filter: "live query") == "4:5:entry:live query:'live query'\n")
    }

    @Test func absentFilterDumpKeepsCapitalFEmpty() throws {
        let pipeline = try pipeline(["-format", "[F]"])

        #expect(pipeline.dump(rows: [Row(parsing: "entry")]) == ["[]\n"])
    }

    // Contract: source/modes/dmenu.c:533-542.
    @Test func inputIsAsyncByDefault() throws {
        #expect(try pipeline().isAsync)
    }

    @Test(arguments: [
        ["-sync"], ["-dump"], ["-select", "a"], ["-no-custom"], ["-only-match"],
        ["-selected-row", "1"], ["-auto-select"],
    ])
    func forcingFlagsMakeInputSync(flags: [String]) throws {
        #expect(try !pipeline(flags).isAsync)
    }

    // `-dump` and the interactive path share one shortcut block upstream
    // (source/modes/dmenu.c:988-998), so they must never drift apart.
    @Test(arguments: [[], ["-auto-select"], ["-only-match"], ["-no-custom"], ["-auto-select", "-only-match"]])
    func dumpAndStartResolveTheSameShortcut(args: [String]) throws {
        let pipeline = try pipeline(args)
        let inputs: [[Row]] = [[], [Row(parsing: "only")], fruit]

        for rows in inputs {
            guard let shortcut = pipeline.shortcut(rows: rows) else { continue }

            #expect(pipeline.dump(rows: rows) == (shortcut.output.map { [$0] } ?? []))

            guard case .completed(let completion) = pipeline.start(rows: rows) else {
                Issue.record("Expected the shortcut to bypass the session for \(args)")
                continue
            }
            #expect(completion == shortcut)
        }
    }
}
