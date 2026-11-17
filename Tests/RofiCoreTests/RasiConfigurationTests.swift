import RofiCore
import Testing

@Suite struct RasiConfigurationTests {
    @Test func discoversDefaultConfigWithoutMakingAMissingDefaultAnError() throws {
        let files = FakeFiles([
            "/xdg/rofi/config.rasi": "configuration { lines: 4; }"
        ])
        let loader = RasiConfigurationLoader(
            environment: environment(files: files, variables: ["XDG_CONFIG_HOME": "/xdg"])
        )

        let loaded = try loader.load(arguments: Arguments(["rofi"]))
        #expect(loaded.resolution.value(selector: .configuration, property: .lines) == .integer(4))
        #expect(loaded.warnings.isEmpty)

        let missing = try RasiConfigurationLoader(
            environment: environment(files: FakeFiles(), variables: ["XDG_CONFIG_HOME": "/missing"])
        ).load(arguments: Arguments(["rofi"]))
        #expect(missing.resolution.declarations.isEmpty)
        #expect(missing.warnings.isEmpty)
    }

    @Test func noConfigSkipsExplicitConfigAndWarns() throws {
        let files = FakeFiles(["/work/config.rasi": "configuration { lines: 8; }"])
        let loaded = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments(["rofi", "-config", "config.rasi", "-no-config"])
        )

        #expect(loaded.resolution.value(selector: .configuration, property: .lines) == nil)
        #expect(loaded.warnings.map(\.code) == [.ignoredOption])
        #expect(files.requests.isEmpty)
    }

    @Test func composesThemeStringsAndCLIOverridesInPrecedenceOrder() throws {
        let files = FakeFiles([
            "/work/config.rasi": """
            configuration { lines: 2; location: north; }
            window { background-color: red; }
            @theme "configured"
            """,
            "/work/themes/configured.rasi": "window { background-color: green; text-color: white; }",
            "/work/themes/explicit.rasi": "window { background-color: blue; width: 20em; }",
        ])
        let arguments = Arguments([
            "rofi", "-config", "config.rasi", "-theme", "explicit",
            "-theme-str", "window { background-color: #010203; }",
            "-theme-str", "window { width: 75%; }", "-l", "9", "-b", "-location", "east",
        ])

        let loaded = try RasiConfigurationLoader(environment: environment(files: files)).load(arguments: arguments)

        #expect(
            loaded.resolution.color(selector: .window, property: .backgroundColor)
                == .init(red: 1.0 / 255, green: 2.0 / 255, blue: 3.0 / 255))
        #expect(loaded.resolution.color(selector: .window, property: .textColor) == nil)
        #expect(
            loaded.resolution.value(selector: .window, property: .width) == .dimension(.init(value: 75, unit: .percent))
        )
        #expect(loaded.resolution.value(selector: .configuration, property: .lines) == .integer(9))
        #expect(loaded.resolution.value(selector: .configuration, property: .location) == .location(.east))
    }

    /// dmenu counts `-l 15`, its default, as unset, so the theme's lines win
    /// (source/modes/dmenu.c:575-590); a value that wraps negative is zero.
    @Test func defaultLinesFlagOverridesNothing() throws {
        let files = FakeFiles()
        let defaultLines = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments(["rofi", "-theme-str", "listview { lines: 5; }", "-l", "15"])
        )
        #expect(defaultLines.resolution.value(selector: .configuration, property: .lines) == nil)
        #expect(defaultLines.resolution.value(selector: .listview, property: .lines) == .integer(5))

        let wrapped = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments(["rofi", "-l", "4294967295"])
        )
        #expect(wrapped.resolution.value(selector: .configuration, property: .lines) == .integer(0))
    }

    @Test func resolvesRelativeImports() throws {
        let files = FakeFiles([
            "/work/config.rasi": "@import \"shared.rasi\"\n@import \"shared.rasi\"",
            "/work/shared.rasi": "window { width: 24px; }",
        ])

        let loaded = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments(["rofi", "-config", "/work/config.rasi"])
        )

        #expect(loaded.resolution.value(selector: .window, property: .width) == .dimension(.pixels(24)))
    }

    // A `name { ... }` section inside configuration (lexer/theme-parser.y:
    // 485-497) holds a mode's settings, read by rofi_config_find_widget
    // (source/theme.c:782-788); `-window-<setting> <value>` sets one
    // (source/xrmoptions.c:849-860). An unknown section warns.
    @Test func canonicalDumpContainsOnlyEffectiveSupportedValues() throws {
        let files = FakeFiles([
            "/work/config.rasi": """
            configuration {
                lines: 3; location: 6; ignored: true;
                window { hide-active-window: true; close-on-delete: true; }
                filebrowser { directories-first: true; }
            }
            window { background-color: red; background-color: #112233; width: 640px; hide-active-window: true; }
            """
        ])
        let loaded = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments(["rofi", "-config", "config.rasi", "-window-close-on-delete", "false"])
        )

        #expect(
            loaded.resolution.value(selector: .configurationSection("window"), property: .hideActiveWindow)
                == .boolean(true))
        #expect(
            loaded.canonicalRasi == """
                configuration {
                    lines: 3;
                    location: south;
                    window {
                        hide-active-window: true;
                        close-on-delete: false;
                    }
                }

                window {
                    background-color: rgba(17, 34, 51, 1);
                    width: 640px;
                }
                """ + "\n"
        )
        #expect(loaded.warnings.map(\.code) == [.unsupportedProperty, .unsupportedProperty, .unsupportedProperty])
    }

    @Test func explicitMissingConfigIsFatal() {
        #expect(throws: RasiFailure.self) {
            try RasiConfigurationLoader(environment: environment(files: FakeFiles())).load(
                arguments: Arguments(["rofi", "-config", "missing.rasi"])
            )
        }
    }

    @Test func explicitMissingThemeNamesTheRequestedTheme() {
        do {
            _ = try RasiConfigurationLoader(environment: environment(files: FakeFiles())).load(
                arguments: Arguments(["rofi", "-theme", "missing-theme"])
            )
            Issue.record("Expected a missing explicit theme to fail")
        } catch let failure as RasiFailure {
            #expect(failure.diagnostic.code == .missingImport)
            #expect(failure.diagnostic.source == "missing-theme")
            #expect(failure.diagnostic.message == "theme 'missing-theme' was not found")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func themeStringImportsUseThemeRootsInsteadOfTheWorkingDirectory() throws {
        let files = FakeFiles([
            "/work/config/config.rasi": "configuration { lines: 2; }",
            "/work/config/themes/fragment.rasi": "window { width: 55px; }",
        ])

        let loaded = try RasiConfigurationLoader(environment: environment(files: files)).load(
            arguments: Arguments([
                "rofi", "-config", "/work/config/config.rasi",
                "-theme-str", "@import \"fragment.rasi\"",
            ])
        )

        #expect(loaded.resolution.value(selector: .window, property: .width) == .dimension(.pixels(55)))
        #expect(!files.requests.contains("/work/fragment.rasi"))
    }

    private func environment(
        files: FakeFiles,
        variables: [String: String] = [:]
    ) -> RasiConfigurationEnvironment {
        RasiConfigurationEnvironment(
            homeDirectory: "/home/test",
            currentDirectory: "/work",
            variables: variables,
            bundledThemeDirectories: [],
            loadFile: files.load
        )
    }
}

private final class FakeFiles: @unchecked Sendable {
    private let files: [String: String]
    private(set) var requests: [String] = []

    init(_ files: [String: String] = [:]) {
        self.files = files
    }

    func load(_ path: String) throws -> RasiSource? {
        requests.append(path)
        return files[path].map { RasiSource(identity: path, text: $0) }
    }
}
