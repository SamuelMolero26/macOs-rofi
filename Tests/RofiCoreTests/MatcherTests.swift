import Testing
import RofiCore

// Contract: helper_tokenize, create_regex, glob/fuzzy/prefix_to_regex and
// helper_token_match (rofi source/helper.c:154-322, 541-560), plus
// parse_case_sensitivity (source/helper.c:1672-1691).
@Suite struct MatcherTests {
    private func matches(_ query: String, _ text: String, _ options: MatchOptions = MatchOptions()) -> Bool {
        Matcher(query: query, options: options).matches(text)
    }

    private func using(_ method: MatchingMethod) -> MatchOptions {
        var options = MatchOptions()
        options.method = method
        return options
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(matches("", "anything"))
        #expect(matches("   ", "anything"))
    }

    @Test func everySpaceSeparatedTokenMustMatch() {
        #expect(matches("fi fox", "firefox"))
        #expect(matches("fox  fi", "firefox"))
        #expect(!matches("fi zz", "firefox"))
    }

    @Test func onlySpacesSplitTokens() {
        #expect(!matches("a\tb", "a b"))
        #expect(matches("a\tb", "xa\tbx"))
    }

    @Test func noTokenizeKeepsTheWholeQuery() {
        var options = MatchOptions()
        options.tokenize = false
        #expect(!matches("fox fi", "firefox", options))
        #expect(matches("e f", "fire fox", options))
    }

    @Test func leadingNegateCharInvertsAToken() {
        #expect(!matches("-fox", "firefox"))
        #expect(matches("fire -zz", "firefox"))
        #expect(!matches("-", "firefox"), "a lone negate char inverts an empty, always-matching pattern")
        var options = MatchOptions()
        options.negateChar = "!"
        #expect(!matches("!fox", "firefox", options))
        #expect(matches("-fox", "x-foxy", options))
    }

    @Test func negationComparesAndRemovesOnlyTheFirstUTF8Byte() {
        let query = "-\u{0301}foo"
        #expect(!matches(query, "\u{0301}foo"))
        #expect(!matches(query, query))
        #expect(matches(query, "foo"))
    }

    @Test func negationAppliesWithoutTokenizing() {
        var options = MatchOptions()
        options.tokenize = false
        #expect(!matches("-fire fox", "my fire fox", options))
    }

    @Test func normalIsAnEscapedUnanchoredSubstring() {
        #expect(matches("a.c", "xa.cx"))
        #expect(!matches("a.c", "abc"))
        #expect(matches("(+)", "a(+)b"))
    }

    @Test func regexMethodAndInvalidRegexFallsBackToLiteral() {
        #expect(matches("^fi", "firefox", using(.regex)))
        #expect(!matches("^fi", "wifi", using(.regex)))
        #expect(matches("a(b", "xa(b", using(.regex)))
    }

    @Test func globStarAndQuestionMark() {
        #expect(matches("f*x", "firefox", using(.glob)))
        #expect(matches("re*", "firefox", using(.glob)), "globs are unanchored")
        #expect(matches("a?c", "abc", using(.glob)))
        #expect(!matches("a?c", "a c", using(.glob)), "? becomes \\S")
        #expect(!matches("a.c", "abc", using(.glob)))
    }

    @Test func fuzzyMatchesCharactersInOrder() {
        #expect(matches("ffx", "firefox", using(.fuzzy)))
        #expect(!matches("xff", "firefox", using(.fuzzy)))
        #expect(matches("f.x", "f.ax", using(.fuzzy)))
        #expect(!matches("f.x", "fax", using(.fuzzy)), "escaped characters stay literal")
    }

    @Test func prefixMatchesAtAWordBoundary() {
        #expect(matches("fox", "fire fox", using(.prefix)))
        #expect(!matches("fox", "firefox", using(.prefix)))
    }

    @Test func caseInsensitiveByDefaultAndSensitiveOnRequest() {
        #expect(matches("FIRE", "firefox"))
        var options = MatchOptions()
        options.caseSensitive = true
        #expect(!matches("FIRE", "firefox", options))
    }

    @Test func smartCaseTurnsSensitiveOnlyForUppercaseQueries() {
        var options = MatchOptions()
        options.caseSmart = true
        options.caseSensitive = true
        #expect(matches("fire", "Firefox", options), "smart case overrides case-sensitive")
        #expect(matches("Fire", "Firefox", options))
        #expect(!matches("Fire", "firefox", options))
        #expect(!isCaseSensitive(query: "fire", options: options))
        #expect(isCaseSensitive(query: "Ünicode", options: options))
    }

    @Test func normalizeStripsMarksFromQueryAndText() {
        var options = MatchOptions()
        options.normalize = true
        #expect(matches("cafe", "Café", options))
        #expect(matches("café", "cafe", options))
        #expect(!matches("cafe", "café"))
    }
}
