import Darwin
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

public struct RasiConfigurationOverrides: Equatable, Sendable {
    public let lines: Int?
    public let location: RasiLocation?

    public init(lines: Int? = nil, location: RasiLocation? = nil) {
        self.lines = lines
        self.location = location
    }
}

public struct RasiConfiguration: Sendable {
    public let resolution: RasiResolution
    public let warnings: [RasiDiagnostic]
    public let overrides: RasiConfigurationOverrides

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

        let overrides = commandLineOverrides(arguments)
        if let declaration = overrideBlock(arguments: arguments, overrides: overrides) {
            rootStatements.append(declaration)
        }

        let root = RasiSource(identity: "<configuration>", text: rootStatements.joined(separator: "\n"))
        let resolution = try RasiResolver(loader: store.load).resolveComposite(root)
        let warnings = loaderWarnings + resolution.warnings
        return RasiConfiguration(resolution: resolution, warnings: warnings, overrides: overrides)
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
    private var sourcesByCandidate: [String: RasiSource] = [:]
    private var sourcesByIdentity: [String: RasiSource] = [:]
    private var missingCandidates: Set<String> = []
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
        if let cached = sourcesByCandidate[path] { return cached }
        if missingCandidates.contains(path) { return nil }
        let canonicalCandidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if let cached = sourcesByIdentity[canonicalCandidate] {
            sourcesByCandidate[path] = cached
            return cached
        }
        guard let source = try environment.loadFile(path) else {
            missingCandidates.insert(path)
            return nil
        }
        sourcesByCandidate[path] = source
        sourcesByIdentity[source.identity] = source
        return source
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
        let selectors = Set(effective.keys.map(\.selector)).sorted(by: selectorOrder)
        let blocks = selectors.map { selector in
            let declarations = RasiProperty.allCases.compactMap { property -> String? in
                guard let value = effective[DeclarationKey(selector: selector, property: property)] else { return nil }
                return "    \(property.rawValue): \(serialize(value));"
            }
            return "\(selectorName(selector)) {\n\(declarations.joined(separator: "\n"))\n}"
        }
        text = blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }
}

private func commandLineOverrides(_ arguments: Arguments) -> RasiConfigurationOverrides {
    let lines = arguments.uint("-l").map(Int.init)
    let location: RasiLocation?
    if let value = arguments.string("-location") {
        location = parseLocation(value)
    } else if arguments.has("-b") {
        location = .south
    } else {
        location = nil
    }
    return RasiConfigurationOverrides(lines: lines, location: location)
}

private func overrideBlock(arguments: Arguments, overrides: RasiConfigurationOverrides) -> String? {
    var declarations: [String] = []
    if let lines = overrides.lines { declarations.append("lines: \(lines);") }
    if let rawLocation = arguments.string("-location") {
        declarations.append("location: \(rawLocation);")
    } else if let location = overrides.location {
        declarations.append("location: \(location.rawValue);")
    }
    return declarations.isEmpty ? nil : "configuration { \(declarations.joined(separator: " ")) }"
}

private func parseLocation(_ value: String) -> RasiLocation? {
    let normalized = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if let location = RasiLocation(rawValue: normalized) { return location }
    guard let index = Int(normalized) else { return nil }
    let locations: [RasiLocation] = [
        .center, .northWest, .north, .northEast, .east, .southEast, .south, .southWest, .west,
    ]
    return locations.indices.contains(index) ? locations[index] : nil
}

private func selectorOrder(_ left: RasiSelector, _ right: RasiSelector) -> Bool {
    func rank(_ selector: RasiSelector) -> Int {
        if selector == .configuration { return 0 }
        if selector == .global { return 1 }
        return 2
    }
    let leftKey = (rank(left), selectorName(left))
    let rightKey = (rank(right), selectorName(right))
    return leftKey < rightKey
}

private func selectorName(_ selector: RasiSelector) -> String {
    ([selector.name] + selector.states).joined(separator: " ")
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

private func diagnostic(
    _ code: RasiDiagnosticCode,
    _ message: String,
    source: String,
    severity: RasiDiagnosticSeverity = .warning
) -> RasiDiagnostic {
    RasiDiagnostic(severity: severity, code: code, message: message, source: source, line: 1, column: 1)
}

private func failure(_ code: RasiDiagnosticCode, _ message: String, source: String) -> RasiFailure {
    RasiFailure(diagnostic: diagnostic(code, message, source: source, severity: .error))
}

private func loadLocalRasiFile(_ path: String) throws -> RasiSource? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    if descriptor == -1 {
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw failure(.missingImport, String(cString: strerror(errno)), source: path)
    }
    defer { close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw failure(.missingImport, String(cString: strerror(errno)), source: path)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
        throw failure(.missingImport, "only regular files are supported", source: path)
    }
    guard status.st_size <= 1_048_576 else {
        throw failure(.resourceLimit, "source exceeds the 1 MiB limit", source: path)
    }

    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw failure(.missingImport, String(cString: strerror(errno)), source: path)
        }
        bytes.append(contentsOf: buffer.prefix(count))
        guard bytes.count <= 1_048_576 else {
            throw failure(.resourceLimit, "source exceeds the 1 MiB limit", source: path)
        }
    }

    // The bytes always come from this descriptor. Canonicalization is used only
    // for source identity and cycle detection; the file is never reopened.
    let identity = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    return try RasiSource(identity: identity, bytes: bytes)
}
