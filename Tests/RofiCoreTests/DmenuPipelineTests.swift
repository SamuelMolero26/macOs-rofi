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

    // Contract: one display_name, source/modes/dmenu.c:523, 591-595 and 1035;
    // the window title around it in source/view.c:1892-1894.
    @Test func promptAndTitleDefaultToTheModeName() throws {
        let pipeline = try pipeline()

        #expect(pipeline.prompt == "dmenu")
        #expect(pipeline.windowTitle == "rofi - dmenu")
    }

    @Test func promptFlagAlsoNamesTheWindow() throws {
        let pipeline = try pipeline(["-p", "Pick"])

        #expect(pipeline.prompt == "Pick")
        #expect(pipeline.windowTitle == "rofi - Pick")
    }

    @Test func windowTitleFlagAlsoSetsThePrompt() throws {
        let pipeline = try pipeline(["-window-title", "Files"])

        #expect(pipeline.prompt == "Files")
        #expect(pipeline.windowTitle == "rofi - Files")
    }

    @Test func promptFlagWinsOverWindowTitleFlag() throws {
        let pipeline = try pipeline(["-window-title", "Files", "-p", "Pick"])

        #expect(pipeline.prompt == "Pick")
        #expect(pipeline.windowTitle == "rofi - Pick")
    }

    @Test func emptyPromptStaysEmpty() throws {
        #expect(try pipeline(["-p", ""]).prompt == "")
    }

    @Test func promptFlagWithoutAValueKeepsTheDefault() throws {
        #expect(try pipeline(["-p"]).prompt == "dmenu")
    }

    // Contract: source/modes/dmenu.c:550 and 710-716; source/view.c:230-263.
    @Test func messageIsAbsentByDefault() throws {
        #expect(try pipeline().message == nil)
        #expect(try pipeline(["-mesg"]).message == nil)
    }

    @Test(arguments: ["line one\nline two", "<b>raw</b>", ""])
    func messageIsTheFlagValueUnchanged(value: String) throws {
        #expect(try pipeline(["-mesg", value]).message == value)
    }

    // Contract: source/modes/dmenu.c:575-590 and DEFAULT_MENU_LINES,
    // include/settings.h:231.
    @Test(arguments: [[], ["-l"], ["-l", "15"]])
    func linesStayUnsetWithoutARealOverride(flags: [String]) throws {
        #expect(try pipeline(flags).lines == nil)
    }

    @Test func linesTakeTheFlagValue() throws {
        #expect(try pipeline(["-l", "3"]).lines == 3)
        #expect(try pipeline(["-l", "4294967299"]).lines == 3)
    }

    // A count of zero hides the rows (source/widgets/listview.c:1121-1127).
    @Test(arguments: ["0", "abc", ""])
    func unparsableLinesCountAsZero(value: String) throws {
        #expect(try pipeline(["-l", value]).lines == 0)
    }

    // `lines` lands in a theme int, so these are negative upstream too.
    @Test(arguments: ["-1", "-5", "3000000000"])
    func negativeLinesShowNoRows(value: String) throws {
        #expect(try pipeline(["-l", value]).lines == 0)
    }

    // Contract: source/modes/dmenu.c:601-603.
    @Test func bottomIsOffByDefault() throws {
        #expect(try !pipeline().atBottom)
    }

    @Test func bottomFlagIsFoundAnywhereInTheArguments() throws {
        #expect(try pipeline(["-b"]).atBottom)
        #expect(try pipeline(["-filter", "-b"]).atBottom)
    }

    @Test func sessionExposesItsPipelineToTheUI() throws {
        guard case .session(let session) = try pipeline(["-p", "Pick"]).start(rows: fruit) else {
            Issue.record("expected an interactive session")
            return
        }

        #expect(session.pipeline.prompt == "Pick")
    }
}
