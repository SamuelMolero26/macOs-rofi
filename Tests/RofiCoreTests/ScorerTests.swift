import Testing
import RofiCore

// Contract: levenshtein (rofi source/helper.c:815-853). Lengths are code
// points, as view.c:503 passes g_utf8_strlen. Expected values come from rofi's
// test/helper-test.c:164-184 or a C harness built from the copied function.
@Suite struct LevenshteinTests {
    @Test func rofiReferenceVectors() {
        #expect(levenshtein("aap", "aap", caseSensitive: false) == 0)
        #expect(levenshtein("aap", "aap ", caseSensitive: false) == 1)
        #expect(levenshtein("aap ", "aap", caseSensitive: false) == 1)
        #expect(levenshtein("aap", "aap noot", caseSensitive: false) == 5)
        #expect(levenshtein("aap", "noot aap", caseSensitive: false) == 5)
        #expect(levenshtein("aap", "noot aap mies", caseSensitive: false) == 10)
        #expect(levenshtein("noot aap mies", "aap", caseSensitive: false) == 10)
        #expect(levenshtein("otp", "noot aap", caseSensitive: false) == 5)
        #expect(levenshtein("kitten", "sitting", caseSensitive: false) == 3)
    }

    @Test func emptySidesCostTheOtherLength() {
        #expect(levenshtein("", "abc", caseSensitive: false) == 3)
        #expect(levenshtein("abc", "", caseSensitive: false) == 3)
    }

    @Test func caseFoldsUnlessCaseSensitive() {
        #expect(levenshtein("AAP", "aap", caseSensitive: false) == 0)
        #expect(levenshtein("AAP", "aap", caseSensitive: true) == 3)
        #expect(levenshtein("ÉCOLE", "école", caseSensitive: false) == 0, "g_unichar_tolower folds non-ASCII")
    }

    @Test func distanceCountsCodePointsNotGraphemes() {
        #expect(levenshtein("é", "e\u{301}", caseSensitive: false) == 2, "precomposed vs decomposed: substitute + insert")
        #expect(levenshtein("日本", "日本語", caseSensitive: false) == 1)
    }
}

// Contract: rofi_scorer_fuzzy_evaluate with rofi_scorer_get_character_class
// and rofi_scorer_get_score_for (rofi source/helper.c:888-1025). Lower is
// better. Values from rofi's test/helper-test.c:213-227 or the C harness.
@Suite struct FuzzyScoreTests {
    /// -MIN_SCORE, MIN_SCORE being INT_MIN / 2 (source/helper.c:893).
    let sentinel = 1_073_741_824

    @Test func rofiReferenceVectors() {
        // rofi's test passes plen/slen 12 for "aap noot mies", scoring "aap noot mie".
        #expect(fuzzyScore("aap noot mie", "aap noot mie", caseSensitive: false) == -605)
        #expect(fuzzyScore("anm", "aap noot mie", caseSensitive: false) == -155)
        #expect(fuzzyScore("blu", "aap noot mie", caseSensitive: false) == sentinel)
        #expect(fuzzyScore("Anm", "aap noot mie", caseSensitive: false) == -155)
        #expect(fuzzyScore("aap noot mie", "Anm", caseSensitive: false) == sentinel)
    }

    @Test func wordStartAndCamelCaseBonuses() {
        #expect(fuzzyScore("fb", "fooBar", caseSensitive: false) == -124)
        #expect(fuzzyScore("fb", "foobar", caseSensitive: false) == -80)
        #expect(fuzzyScore("f1", "foo1", caseSensitive: false) == -134)
        #expect(fuzzyScore("ff", "firefox", caseSensitive: false) == -75)
        #expect(fuzzyScore("ff", "fire-fox", caseSensitive: false) == -120)
        #expect(fuzzyScore("fx", "fire fox", caseSensitive: false) == -75)
    }

    @Test func spacesInThePatternStartANewWord() {
        #expect(fuzzyScore("a b", "xa b", caseSensitive: false) == -91)
        #expect(fuzzyScore(" a", "ba", caseSensitive: false) == 4, "leading spaces keep the first-character alignment")
    }

    @Test func noMatchIsTheSentinel() {
        #expect(fuzzyScore("", "abc", caseSensitive: false) == sentinel)
        #expect(fuzzyScore("a", "", caseSensitive: false) == sentinel)
        #expect(fuzzyScore("E", "ecole", caseSensitive: true) == sentinel)
    }

    @Test func outOfOrderMatchesLandJustBelowTheSentinel() {
        // dp carries uleft/ulefts across rows, so a later pattern character
        // can still align before an earlier one at a MIN_SCORE-based value.
        #expect(fuzzyScore("Anm", "aap noot mie", caseSensitive: true) == sentinel - 70)
        #expect(fuzzyScore("ab", "ba", caseSensitive: false) == sentinel - 45)
    }

    @Test func caseFoldingCoversNonASCII() {
        #expect(fuzzyScore("E", "ecole", caseSensitive: false) == -80)
        #expect(fuzzyScore("É", "école", caseSensitive: false) == -80)
        #expect(fuzzyScore("É", "école", caseSensitive: true) == sentinel)
    }

    @Test func textLongerThan256CodePointsIsNotScored() {
        #expect(fuzzyScore("a", String(repeating: "a", count: 256), caseSensitive: false) == 1020)
        #expect(fuzzyScore("a", String(repeating: "a", count: 257), caseSensitive: false) == sentinel)
        // 201 code points but 401 UTF-8 bytes: still scored; 'a' aligns at
        // index 200 with no bonus, so -(LEADING_GAP_SCORE * 200).
        #expect(fuzzyScore("a", String(repeating: "é", count: 200) + "a", caseSensitive: false) == 800,
                "the cap counts code points, not bytes")
    }
}
