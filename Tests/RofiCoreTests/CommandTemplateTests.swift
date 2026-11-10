import Testing

@testable import RofiCore

// Contract: helper_parse_setup, rofi source/helper.c:102-144;
// helper_string_replace_if_exists_v and helper_eval_cb2, source/helper.c:1733-1839;
// default templates, config/config.c:68,70,74.
@Suite struct CommandTemplateTests {
    static let sshTemplate = "{terminal} -e {ssh-client} {host} [-p {port}]"

    @Test func substitutesPlaceholdersThenSplits() throws {
        let argv = try parseCommandTemplate("{terminal} -e {cmd}", values: ["terminal": "xterm", "cmd": "htop"])
        #expect(argv == ["xterm", "-e", "htop"])
    }

    @Test func defaultSshTemplateWithPort() throws {
        let values = ["terminal": "xterm", "ssh-client": "ssh", "host": "example.org", "port": "2222"]
        #expect(
            try parseCommandTemplate(Self.sshTemplate, values: values)
                == ["xterm", "-e", "ssh", "example.org", "-p", "2222"])
    }

    @Test func optionalGroupIsDroppedWhenThePlaceholderIsMissing() throws {
        let values = ["terminal": "xterm", "ssh-client": "ssh", "host": "example.org"]
        #expect(try parseCommandTemplate(Self.sshTemplate, values: values) == ["xterm", "-e", "ssh", "example.org"])
    }

    @Test func emptyValueKeepsTheGroupBecauseUpstreamOnlyDropsMissingKeys() throws {
        // helper_eval_cb2 tests the lookup for NULL (helper.c:1756-1757), not for "".
        let argv = try parseCommandTemplate("a [-p {port}] b", values: ["port": ""])
        #expect(argv == ["a", "-p", "b"])
    }

    @Test func defaultRunShellTemplate() throws {
        let argv = try parseCommandTemplate("{terminal} -e {cmd}", values: ["terminal": "ghostty", "cmd": "ls"])
        #expect(argv == ["ghostty", "-e", "ls"])
    }

    @Test func defaultRunTemplateIsTheCommandItself() throws {
        #expect(try parseCommandTemplate("{cmd}", values: ["cmd": "firefox --private"]) == ["firefox", "--private"])
    }

    @Test func unknownPlaceholderIsRemoved() throws {
        #expect(try parseCommandTemplate("echo {nope} x", values: [:]) == ["echo", "x"])
    }

    @Test func valueIsSplitAfterSubstitutionLikeUpstream() throws {
        // Upstream substitutes first and splits second (helper.c:125-129), so an
        // unquoted value with blanks becomes several words.
        let argv = try parseCommandTemplate("run {cmd}", values: ["cmd": "a b"])
        #expect(argv == ["run", "a", "b"])
    }

    @Test func quotedPlaceholderKeepsASpacedValueAsOneArgument() throws {
        let argv = try parseCommandTemplate("run \"{cmd}\"", values: ["cmd": "a b $HOME"])
        #expect(argv == ["run", "a b $HOME"])
    }

    @Test func dollarSignsAreNeverExpanded() throws {
        #expect(try parseCommandTemplate("echo {v}", values: ["v": "$HOME"]) == ["echo", "$HOME"])
    }

    @Test func singleQuotesInTheTemplateGroupWords() throws {
        #expect(try parseCommandTemplate("sh -c 'echo {v}'", values: ["v": "hi"]) == ["sh", "-c", "echo hi"])
    }

    @Test func unbalancedQuoteReportsTheUpstreamMessage() {
        let error = #expect(throws: CommandTemplateError.self) {
            try parseCommandTemplate("echo \"{v}", values: ["v": "x"])
        }
        let prefix = "Failed to parse: 'echo \"{v}'\nError: 'Text ended before matching quote"
        #expect(error?.message.hasPrefix(prefix) == true)
    }

    @Test func emptyTemplateIsAnError() {
        let error = #expect(throws: CommandTemplateError.self) {
            try parseCommandTemplate("", values: [:])
        }
        #expect(error?.message == "Failed to parse: ''\nError: 'Text was empty (or contained only whitespace)'")
    }

    @Test func optionalGroupWithOnlyMissingKeysVanishesEntirely() throws {
        #expect(try parseCommandTemplate("x [-t {title}] y", values: [:]) == ["x", "y"])
    }
}
