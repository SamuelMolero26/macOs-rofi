import Foundation

public struct RasiConfigurationEnvironment: @unchecked Sendable {
    public typealias FileLoader = @Sendable (String) throws -> RasiSource?

    public let homeDirectory: String
    public let currentDirectory: String
    public let variables: [String: String]
    public let bundledThemeDirectories: [String]
    public let loadFile: FileLoader

    public init(
        homeDirectory: String,
        currentDirectory: String,
        variables: [String: String],
        bundledThemeDirectories: [String],
        loadFile: @escaping FileLoader
    ) {
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
        self.variables = variables
        self.bundledThemeDirectories = bundledThemeDirectories
        self.loadFile = loadFile
    }

    public static var live: RasiConfigurationEnvironment {
        let resources = Bundle.main.resourceURL.map { [$0.appendingPathComponent("themes").path] } ?? []
        return RasiConfigurationEnvironment(
            homeDirectory: NSHomeDirectory(),
            currentDirectory: FileManager.default.currentDirectoryPath,
            variables: ProcessInfo.processInfo.environment,
            bundledThemeDirectories: resources,
            loadFile: loadLocalRasiFile
        )
    }
}

public struct RasiConfiguration: Sendable {
    public let resolution: RasiResolution
    public let warnings: [RasiDiagnostic]

    public var canonicalRasi: String {
        CanonicalRasi(resolution: resolution).text
    }
}

public struct RasiConfigurationLoader: Sendable {
    private let environment: RasiConfigurationEnvironment

    public init(environment: RasiConfigurationEnvironment = .live) {
        self.environment = environment
    }

    public func load(arguments: Arguments) throws -> RasiConfiguration {
        let paths = PathPolicy(environment: environment)
        let store = SourceStore(environment: environment, paths: paths)
        var loaderWarnings: [RasiDiagnostic] = []
        var rootStatements: [String] = []

        let explicitConfig = arguments.string("-config")
        let noConfig = arguments.has("-no-config")
        var configurationSource: RasiSource?
        if noConfig {
            if arguments.has("-config") {
                loaderWarnings.append(
                    diagnostic(
                        .ignoredOption,
                        "-config was ignored because -no-config was provided",
                        source: "<command line>"
                    ))
            }
        } else if let explicitConfig {
            let path = try paths.commandLinePath(explicitConfig)
            configurationSource = try store.required(path, description: "configuration")
        } else {
            configurationSource = try store.optional(paths.defaultConfiguration)
        }

        let activeConfigurationDirectory =
            configurationSource.map { directory(of: $0.identity) }
            ?? paths.defaultConfigurationDirectory
        store.activeConfigurationDirectory = activeConfigurationDirectory
        if let configurationSource {
            store.register(configurationSource, token: SourceToken.configuration)
            rootStatements.append("@import \"\(SourceToken.configuration)\"")
        }

        if let theme = arguments.string("-theme") {
            let source = try store.requiredTheme(theme)
            store.register(source, token: SourceToken.commandLineTheme)
            rootStatements.append("@theme \"\(SourceToken.commandLineTheme)\"")
        }

        for (index, text) in arguments.strings("-theme-str").enumerated() {
            let token = SourceToken.themeString(index)
            store.register(RasiSource(identity: "<theme-str:\(index + 1)>", text: text), token: token)
            rootStatements.append("@import \"\(token)\"")
        }

        if let declaration = overrideBlock(arguments) {
            rootStatements.append(declaration)
        }

        let root = RasiSource(identity: "<configuration>", text: rootStatements.joined(separator: "\n"))
        let resolution = try RasiResolver(loader: store.load).resolveComposite(root)
        let warnings = loaderWarnings + resolution.warnings
        return RasiConfiguration(resolution: resolution, warnings: warnings)
    }
}

private enum SourceToken {
    static let configuration = "__rofi_configuration__"
    static let commandLineTheme = "__rofi_command_line_theme__"

    static func themeString(_ index: Int) -> String {
        "__rofi_theme_string_\(index)__"
    }
}

private final class SourceStore: @unchecked Sendable {
    private let environment: RasiConfigurationEnvironment
    private let paths: PathPolicy
    private var virtualSources: [String: RasiSource] = [:]
    var activeConfigurationDirectory: String

    init(environment: RasiConfigurationEnvironment, paths: PathPolicy) {
        self.environment = environment
        self.paths = paths
        activeConfigurationDirectory = paths.defaultConfigurationDirectory
    }

    func register(_ source: RasiSource, token: String) {
        virtualSources[token] = source
    }

    func optional(_ path: String) throws -> RasiSource? {
        try environment.loadFile(path)
    }

    func required(_ path: String, description: String) throws -> RasiSource {
        guard let source = try optional(path) else {
            throw failure(.missingImport, "\(description) file '\(path)' was not found", source: path)
        }
        return source
    }

    func requiredTheme(_ target: String) throws -> RasiSource {
        let candidates = try paths.candidates(
            target: target,
            includingSource: "<command line>",
            activeConfigurationDirectory: activeConfigurationDirectory
        )
        for candidate in candidates {
            if let source = try optional(candidate) { return source }
        }
        throw failure(.missingImport, "theme '\(target)' was not found", source: target)
    }

    func load(_ request: RasiLoadRequest) throws -> RasiSource? {
        if let source = virtualSources[request.target] { return source }
        let candidates = try paths.candidates(
            target: request.target,
            includingSource: request.includingSource,
            activeConfigurationDirectory: activeConfigurationDirectory
        )
        for candidate in candidates {
            if let source = try optional(candidate) { return source }
        }
        return nil
    }
}

private struct PathPolicy: Sendable {
    let environment: RasiConfigurationEnvironment
    let configRoot: String
    let dataRoot: String

    init(environment: RasiConfigurationEnvironment) {
        self.environment = environment
        configRoot =
            Self.absoluteVariable("XDG_CONFIG_HOME", in: environment)
            ?? Self.join(environment.homeDirectory, ".config")
        dataRoot =
            Self.absoluteVariable("XDG_DATA_HOME", in: environment)
            ?? Self.join(environment.homeDirectory, ".local/share")
    }

    var defaultConfigurationDirectory: String { Self.join(configRoot, "rofi") }
    var defaultConfiguration: String { Self.join(defaultConfigurationDirectory, "config.rasi") }

    func commandLinePath(_ value: String) throws -> String {
        try expand(value, relativeTo: environment.currentDirectory)
    }

    func candidates(
        target: String,
        includingSource: String,
        activeConfigurationDirectory: String
    ) throws -> [String] {
        let pathLike = isPathLike(target)
        if pathLike, includingSource == "<command line>" {
            return [try expand(target, relativeTo: environment.currentDirectory)]
        }
        if target.hasPrefix("/") || target.hasPrefix("~") {
            return [try expand(target, relativeTo: environment.currentDirectory)]
        }

        var directories: [String] = []
        if !includingSource.hasPrefix("<") {
            directories.append(directory(of: includingSource))
        }
        directories += [
            Self.join(activeConfigurationDirectory, "themes"),
            activeConfigurationDirectory,
            Self.join(configRoot, "rofi/themes"),
            Self.join(configRoot, "rofi"),
            Self.join(dataRoot, "rofi/themes"),
        ]
        directories += environment.bundledThemeDirectories

        let names = pathLike ? [target] : ["\(target).rasi", "\(target).rasinc"]
        var seen: Set<String> = []
        return try directories.flatMap { directory in
            try names.compactMap { name in
                let candidate = try expand(name, relativeTo: directory)
                return seen.insert(candidate).inserted ? candidate : nil
            }
        }
    }

    private func expand(_ value: String, relativeTo base: String) throws -> String {
        let expanded: String
        if value == "~" {
            expanded = environment.homeDirectory
        } else if value.hasPrefix("~/") {
            expanded = Self.join(environment.homeDirectory, String(value.dropFirst(2)))
        } else if value.hasPrefix("~") {
            throw failure(.invalidValue, "other-user home expansion is not supported", source: value)
        } else if value.hasPrefix("/") {
            expanded = value
        } else {
            expanded = Self.join(base, value)
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func isPathLike(_ value: String) -> Bool {
        value.contains("/") || value.hasPrefix(".") || value.hasPrefix("~")
            || value.hasSuffix(".rasi") || value.hasSuffix(".rasinc")
    }

    private static func absoluteVariable(
        _ name: String,
        in environment: RasiConfigurationEnvironment
    ) -> String? {
        guard let value = environment.variables[name], !value.isEmpty, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    static func join(_ left: String, _ right: String) -> String {
        URL(fileURLWithPath: left, isDirectory: true).appendingPathComponent(right).standardizedFileURL.path
    }
}

private struct DeclarationKey: Hashable {
    let selector: RasiSelector
    let property: RasiProperty
}

private struct CanonicalRasi {
    let text: String

    init(resolution: RasiResolution) {
        var effective: [DeclarationKey: RasiResolvedValue] = [:]
        for declaration in resolution.declarations {
            effective[DeclarationKey(selector: declaration.selector, property: declaration.property)] =
                declaration.value
        }
        func declarations(_ selector: RasiSelector, indent: String) -> [String] {
            RasiProperty.allCases.compactMap { property in
                guard let value = effective[DeclarationKey(selector: selector, property: property)] else { return nil }
                return "\(indent)\(property.rawValue): \(serialize(value));"
            }
        }
        let used = Set(effective.keys.map(\.selector))
        // Sections print nested in configuration, as they are written
        // (lexer/theme-parser.y:485-497).
        let sections = used.filter { $0.name == "configuration" && !$0.states.isEmpty }.sorted { $0.label < $1.label }
        var selectors = used.subtracting(sections)
        if !sections.isEmpty { selectors.insert(.configuration) }
        let blocks = selectors.sorted(by: selectorOrder).map { selector in
            var lines = declarations(selector, indent: "    ")
            if selector == .configuration {
                for section in sections {
                    lines += ["    \(section.states[0]) {"] + declarations(section, indent: "        ") + ["    }"]
                }
            }
            return "\(selector.label) {\n\(lines.joined(separator: "\n"))\n}"
        }
        text = blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }
}

private func overrideBlock(_ arguments: Arguments) -> String? {
    var declarations: [String] = []
    // Like DmenuPipeline: dmenu's default `-l 15` overrides nothing, and the
    // theme value is a signed int, so a negative one shows no rows
    // (source/modes/dmenu.c:575-590).
    if let value = arguments.uint("-l"), value != 15 {
        declarations.append("lines: \(max(0, Int(Int32(truncatingIfNeeded: value))));")
    }
    if let rawLocation = arguments.string("-location") {
        declarations.append("location: \(rawLocation);")
    } else if arguments.has("-b") {
        declarations.append("location: \(RasiLocation.south.rawValue);")
    }
    // `-window-<setting> <value>` (source/xrmoptions.c:849-860).
    let window = [RasiProperty.hideActiveWindow, .closeOnDelete].compactMap { property in
        arguments.string("-window-" + property.rawValue).map { "\(property.rawValue): \($0);" }
    }
    if !window.isEmpty {
        declarations.append("window { \(window.joined(separator: " ")) }")
    }
    return declarations.isEmpty ? nil : "configuration { \(declarations.joined(separator: " ")) }"
}

private func selectorOrder(_ left: RasiSelector, _ right: RasiSelector) -> Bool {
    func rank(_ selector: RasiSelector) -> Int {
        if selector == .configuration { return 0 }
        if selector == .global { return 1 }
        return 2
    }
    return (rank(left), left.label) < (rank(right), right.label)
}

private func serialize(_ value: RasiResolvedValue) -> String {
    switch value {
    case .color(let color):
        return
            "rgba(\(number(color.red * 255)), \(number(color.green * 255)), \(number(color.blue * 255)), \(number(color.alpha)))"
    case .font(let font):
        return "\"\(font.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    case .dimension(let dimension):
        return serialize(dimension)
    case .insets(let insets):
        return [insets.top, insets.right, insets.bottom, insets.left].map(serialize).joined(separator: " ")
    case .border(let border):
        return [border.widths.top, border.widths.right, border.widths.bottom, border.widths.left]
            .map(serialize).joined(separator: " ") + " solid"
    case .integer(let integer):
        return String(integer)
    case .location(let location):
        return location.rawValue
    case .boolean(let boolean):
        return String(boolean)
    }
}

private func serialize(_ dimension: RasiDimension) -> String {
    "\(number(dimension.value))\(dimension.unit.rawValue)"
}

private func number(_ value: Double) -> String {
    if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
        return String(Int(value))
    }
    return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func directory(of path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().path
}

private func diagnostic(_ code: RasiDiagnosticCode, _ message: String, source: String) -> RasiDiagnostic {
    RasiDiagnostic(code: code, message: message, source: source, line: 1, column: 1)
}

private func failure(_ code: RasiDiagnosticCode, _ message: String, source: String) -> RasiFailure {
    RasiFailure(diagnostic: diagnostic(code, message, source: source))
}

/// The size is checked before reading so a huge file is never loaded; the
/// resolver caps every source, theme strings included, at the same 1 MiB.
private func loadLocalRasiFile(_ path: String) throws -> RasiSource? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw failure(.missingImport, "only regular files are supported", source: path)
        }
        guard values.fileSize ?? 0 <= 1_048_576 else {
            throw failure(.resourceLimit, "source exceeds the 1 MiB limit", source: path)
        }
        return try RasiSource(identity: url.path, bytes: Array(Data(contentsOf: url)))
    } catch let known as RasiFailure {
        throw known
    } catch {
        throw failure(.missingImport, error.localizedDescription, source: path)
    }
}
