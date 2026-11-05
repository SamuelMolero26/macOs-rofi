import Darwin
import RofiCore
import Testing

@Suite struct RasiParserTests {
    @Test func parsesCommentsSelectorsCascadeAndSupportedValues() throws {
        let source = RasiSource(
            identity: "inline.rasi",
            text: """
                /* outer /* nested */ comment */
                * { background-color: ReD; text-color: #1234; }
                window, #mainbox { padding: 1px 2em 3ch 4%; border: 2px solid; }
                window { background-color: rgba(10, 20, 30, 50%); width: 40em; }
                configuration { lines: 0; location: 3; }
                element.normal.selected { text-color: rgb(255, 128, 0); }
                """
        )

        let result = try RasiResolver().resolve(source)

        #expect(result.color(selector: .global, property: .backgroundColor) == .init(red: 1, green: 0, blue: 0))
        #expect(
            result.color(selector: .global, property: .textColor)
                == .init(red: 1.0 / 15, green: 2.0 / 15, blue: 3.0 / 15, alpha: 4.0 / 15))
        #expect(
            result.color(selector: .window, property: .backgroundColor)
                == .init(red: 10.0 / 255, green: 20.0 / 255, blue: 30.0 / 255, alpha: 0.5))
        #expect(result.value(selector: .window, property: .width) == .dimension(.init(value: 40, unit: .em)))
        #expect(
            result.value(selector: .window, property: .padding)
                == .insets(
                    .init(
                        top: .pixels(1), right: .init(value: 2, unit: .em), bottom: .init(value: 3, unit: .ch),
                        left: .init(value: 4, unit: .percent))))
        #expect(
            result.value(selector: .mainbox, property: .border)
                == .border(.init(widths: .all(.pixels(2)), style: .solid)))
        #expect(result.value(selector: .configuration, property: .lines) == .integer(0))
        #expect(result.value(selector: .configuration, property: .location) == .location(.northEast))
        #expect(
            result.color(selector: .element(states: ["selected", "normal"]), property: .textColor)
                == .init(red: 1, green: 128.0 / 255, blue: 0))
        #expect(result.warnings.isEmpty)
    }

    @Test func resolvesForwardReferencesFallbacksAndInheritLazily() throws {
        let source = RasiSource(
            identity: "references.rasi",
            text: """
                * {
                    background-color: @late;
                    text-color: var(missing, #abcdef);
                    late: @base;
                    base: rgba(1, 2, 3, 0.25);
                }
                element normal { text-color: inherit; }
                """
        )

        let result = try RasiResolver().resolve(source)

        #expect(
            result.color(selector: .global, property: .backgroundColor)
                == .init(red: 1.0 / 255, green: 2.0 / 255, blue: 3.0 / 255, alpha: 0.25))
        #expect(
            result.color(selector: .global, property: .textColor)
                == .init(red: 171.0 / 255, green: 205.0 / 255, blue: 239.0 / 255))
        #expect(
            result.color(selector: .element(states: ["normal"]), property: .textColor)
                == .init(red: 171.0 / 255, green: 205.0 / 255, blue: 239.0 / 255))
        #expect(result.warnings.isEmpty)
    }

    @Test func warnsWithoutDroppingSupportedDeclarations() throws {
        let source = RasiSource(
            identity: "warnings.rasi",
            text: """
                * { background-color: #112233; }
                window {
                    children: [ mainbox, inputbar ];
                    transparency: "real";
                    width: 12mm;
                    padding: -1px;
                }
                unknown-widget { text-color: blue; }
                """
        )

        let result = try RasiResolver().resolve(source)

        #expect(
            result.color(selector: .global, property: .backgroundColor)
                == .init(red: 17.0 / 255, green: 34.0 / 255, blue: 51.0 / 255))
        #expect(result.value(selector: .window, property: .width) == nil)
        #expect(result.value(selector: .window, property: .padding) == nil)
        #expect(result.warnings.map(\.code).contains(.unsupportedProperty))
        #expect(result.warnings.map(\.code).contains(.unsupportedUnit))
        #expect(result.warnings.map(\.code).contains(.invalidValue))
        #expect(result.warnings.map(\.code).contains(.unsupportedSelector))
    }

    @Test func importsAtDirectivePositionAndThemeResetsOnlyVisualState() throws {
        let root = RasiSource(
            identity: "/themes/root.rasi",
            text: """
                configuration { lines: 7; }
                window { text-color: red; }
                @import "merge"
                window { background-color: blue; }
                @theme "replacement"
                """
        )
        let sources = [
            "merge": RasiSource(identity: "/themes/merge.rasi", text: "window { text-color: green; }"),
            "replacement": RasiSource(
                identity: "/themes/replacement.rasi", text: "window { background-color: #010203; }"),
        ]
        let resolver = RasiResolver { request in sources[request.target] }

        let result = try resolver.resolve(root)

        #expect(result.value(selector: .configuration, property: .lines) == .integer(7))
        #expect(result.color(selector: .window, property: .textColor) == nil)
        #expect(
            result.color(selector: .window, property: .backgroundColor)
                == .init(red: 1.0 / 255, green: 2.0 / 255, blue: 3.0 / 255))
        #expect(result.loadedSources == ["/themes/root.rasi", "/themes/merge.rasi", "/themes/replacement.rasi"])
    }

    @Test func optionalMissingImportWarnsButRequiredMissingImportFails() throws {
        let optional = try RasiResolver(loader: { _ in nil }).resolve(
            RasiSource(identity: "optional.rasi", text: "?import \"missing\"\nwindow { width: 20px; }")
        )
        #expect(optional.value(selector: .window, property: .width) == .dimension(.pixels(20)))
        #expect(optional.warnings.map(\.code) == [.missingOptionalImport])

        #expect(throws: RasiFailure.self) {
            try RasiResolver(loader: { _ in nil }).resolve(
                RasiSource(identity: "required.rasi", text: "@import \"missing\"")
            )
        }
    }

    @Test func importCyclesAreFatal() throws {
        let a = RasiSource(identity: "a.rasi", text: "@import \"b\"")
        let b = RasiSource(identity: "b.rasi", text: "@import \"a\"")
        let resolver = RasiResolver { request in request.target == "a" ? a : b }

        do {
            _ = try resolver.resolve(a)
            Issue.record("Expected an import cycle")
        } catch let failure as RasiFailure {
            #expect(failure.diagnostic.code == .importCycle)
            #expect(failure.diagnostic.source == "b.rasi")
        }
    }

    @Test(arguments: [
        "window { width 10px; }",
        "window { width: 10px }",
        "window { width: 10px;",
        "window { font: \"unterminated; }",
        "/* unterminated",
        "@import missing",
    ])
    func malformedStructureIsTransactional(_ text: String) {
        #expect(throws: RasiFailure.self) {
            try RasiResolver().resolve(RasiSource(identity: "malformed.rasi", text: text))
        }
    }

    @Test func invalidUTF8HasTypedDiagnostic() {
        do {
            _ = try RasiSource(identity: "invalid.rasi", bytes: [0xFF])
            Issue.record("Expected invalid UTF-8")
        } catch let failure as RasiFailure {
            #expect(failure.diagnostic.code == .invalidUTF8)
            #expect(failure.diagnostic.source == "invalid.rasi")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func referenceCyclesAndMissingReferencesWarnPerDeclaration() throws {
        let result = try RasiResolver().resolve(
            RasiSource(
                identity: "bad-references.rasi",
                text: """
                    * { a: @b; b: @a; background-color: @a; text-color: @missing; border-color: #123456; }
                    """
            )
        )

        #expect(result.color(selector: .global, property: .backgroundColor) == nil)
        #expect(result.color(selector: .global, property: .textColor) == nil)
        #expect(result.color(selector: .global, property: .borderColor) != nil)
        #expect(result.warnings.map(\.code).contains(.referenceCycle))
        #expect(result.warnings.map(\.code).contains(.missingReference))
    }

    @Test func representativeUpstreamDerivedFixturesResolveSupportedSubset() throws {
        let fixtures = try FixtureCorpus.load()
        let resolver = RasiResolver { request in fixtures[request.target] }

        let gruvbox = try resolver.resolve(try #require(fixtures["gruvbox-dark"] as RasiSource?))
        #expect(
            gruvbox.color(selector: .window, property: .backgroundColor)
                == .init(red: 40.0 / 255, green: 40.0 / 255, blue: 40.0 / 255))
        #expect(
            gruvbox.value(selector: .window, property: .border)
                == .border(.init(widths: .all(.pixels(2)), style: .solid)))

        let sidebar = try resolver.resolve(try #require(fixtures["sidebar"] as RasiSource?))
        #expect(sidebar.value(selector: .window, property: .width) == .dimension(.init(value: 30, unit: .em)))
        #expect(sidebar.value(selector: .listview, property: .lines) == .integer(0))

        let material = try resolver.resolve(try #require(fixtures["material"] as RasiSource?))
        #expect(material.color(selector: .window, property: .backgroundColor)?.alpha == 0.8)
        #expect(!material.warnings.isEmpty)
    }
}

private enum FixtureCorpus {
    static func load() throws -> [String: RasiSource] {
        let names = ["gruvbox-dark", "gruvbox-common", "sidebar", "material"]
        return try Dictionary(
            uniqueKeysWithValues: names.map { name in
                let directory = String(#filePath.dropLast("RasiParserTests.swift".count)) + "Fixtures/Rasi/"
                let path = directory + name + ".rasi"
                let file = try #require(fopen(path, "r"))
                defer { fclose(file) }
                var bytes: [UInt8] = []
                while case let byte = fgetc(file), byte != EOF { bytes.append(UInt8(byte)) }
                return (name, RasiSource(identity: path, text: String(decoding: bytes, as: UTF8.self)))
            })
    }
}
