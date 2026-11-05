import Foundation

public struct RasiResolver {
    public typealias Loader = (RasiLoadRequest) throws -> RasiSource?

    private let loader: Loader

    public init(loader: @escaping Loader = { _ in nil }) {
        self.loader = loader
    }

    public func resolve(_ source: RasiSource) throws -> RasiResolution {
        var evaluator = Evaluator(loader: loader)
        try evaluator.process(source, stack: [], depth: 0)
        return evaluator.finish()
    }
}

private struct PendingDeclaration {
    let selector: RasiSelector
    let property: RasiProperty
    let rawValue: String
    let point: RasiPoint
    let sourceOrder: Int
}

private struct VariableDefinition {
    let rawValue: String
    let point: RasiPoint
}

private struct Evaluator {
    private static let maximumSourceBytes = 1_048_576
    private static let maximumSources = 128
    private static let maximumImportDepth = 32

    let loader: RasiResolver.Loader
    var parser = RasiParser()
    var documents: [String: RasiDocument] = [:]
    var loadedSources: [String] = []
    var configuration: [PendingDeclaration] = []
    var visual: [PendingDeclaration] = []
    var variables: [String: VariableDefinition] = [:]
    var warnings: [RasiDiagnostic] = []
    var sourceOrder = 0

    mutating func process(_ source: RasiSource, stack: [String], depth: Int) throws {
        guard source.text.utf8.count <= Self.maximumSourceBytes else {
            throw fatal(.resourceLimit, "source exceeds the 1 MiB limit", at: point(for: source))
        }
        guard depth <= Self.maximumImportDepth else {
            throw fatal(.resourceLimit, "import depth exceeds 32", at: point(for: source))
        }
        if stack.contains(source.identity) {
            throw fatal(.importCycle, "import cycle includes '\(source.identity)'", at: point(for: source))
        }
        if !loadedSources.contains(source.identity) {
            guard loadedSources.count < Self.maximumSources else {
                throw fatal(.resourceLimit, "resolution exceeds 128 distinct sources", at: point(for: source))
            }
            loadedSources.append(source.identity)
        }

        let document: RasiDocument
        if let cached = documents[source.identity] {
            document = cached
        } else {
            document = try parser.parse(source)
            documents[source.identity] = document
        }

        let nextStack = stack + [source.identity]
        for statement in document.statements {
            switch statement {
            case .load(let target, let kind, let directivePoint):
                try processLoad(target: target, kind: kind, point: directivePoint, stack: nextStack, depth: depth)
            case .block(let selectors, let declarations):
                collect(selectors: selectors, declarations: declarations)
            }
        }
    }

    mutating func processLoad(
        target: String,
        kind: RasiLoadKind,
        point: RasiPoint,
        stack: [String],
        depth: Int
    ) throws {
        if case .replaceTheme = kind {
            visual.removeAll(keepingCapacity: true)
            variables.removeAll(keepingCapacity: true)
        }
        let request = RasiLoadRequest(target: target, kind: kind, includingSource: point.source)
        let loaded: RasiSource?
        do {
            loaded = try loader(request)
        } catch let failure as RasiFailure {
            throw failure
        } catch {
            throw fatal(.missingImport, "could not load '\(target)': \(error)", at: point)
        }
        guard let loaded else {
            if case .importTheme(optional: true) = kind {
                warn(.missingOptionalImport, "optional import '\(target)' was not found", at: point)
                return
            }
            throw fatal(.missingImport, "required theme source '\(target)' was not found", at: point)
        }
        if stack.contains(loaded.identity) {
            throw fatal(.importCycle, "import cycle includes '\(loaded.identity)'", at: point)
        }
        try process(loaded, stack: stack, depth: depth + 1)
    }

    mutating func collect(selectors: [RasiSelector], declarations: [RasiRawDeclaration]) {
        for selector in selectors {
            let selectorSupported = isSupported(selector)
            for declaration in declarations {
                sourceOrder += 1
                if selector == .global {
                    variables[declaration.name] = VariableDefinition(
                        rawValue: declaration.value,
                        point: declaration.point
                    )
                }
                guard let property = RasiProperty(rawValue: declaration.name) else {
                    if selector != .global {
                        warn(
                            .unsupportedProperty,
                            "property '\(declaration.name)' is not supported for '\(selectorLabel(selector))'",
                            at: declaration.point
                        )
                    }
                    continue
                }
                guard selectorSupported else {
                    warn(
                        .unsupportedSelector,
                        "selector '\(selectorLabel(selector))' is not supported",
                        at: declaration.point
                    )
                    continue
                }
                guard supports(property, on: selector) else {
                    warn(
                        .unsupportedProperty,
                        "property '\(property.rawValue)' is not supported for '\(selectorLabel(selector))'",
                        at: declaration.point
                    )
                    continue
                }
                let pending = PendingDeclaration(
                    selector: selector,
                    property: property,
                    rawValue: declaration.value,
                    point: declaration.point,
                    sourceOrder: sourceOrder
                )
                if selector == .configuration {
                    configuration.append(pending)
                } else {
                    visual.append(pending)
                }
            }
        }
    }

    mutating func finish() -> RasiResolution {
        let pending = (configuration + visual).sorted { $0.sourceOrder < $1.sourceOrder }
        var resolved: [RasiResolvedDeclaration] = []
        for declaration in pending {
            if let value = resolve(declaration, referenceStack: []) {
                resolved.append(
                    RasiResolvedDeclaration(
                        selector: declaration.selector,
                        property: declaration.property,
                        value: value,
                        source: declaration.point.source,
                        line: declaration.point.line,
                        column: declaration.point.column,
                        sourceOrder: declaration.sourceOrder
                    )
                )
            }
        }
        return RasiResolution(declarations: resolved, warnings: warnings, loadedSources: loadedSources)
    }

    mutating func resolve(
        _ declaration: PendingDeclaration,
        referenceStack: [String]
    ) -> RasiResolvedValue? {
        resolveRaw(
            declaration.rawValue,
            property: declaration.property,
            selector: declaration.selector,
            point: declaration.point,
            referenceStack: referenceStack
        )
    }

    mutating func resolveRaw(
        _ raw: String,
        property: RasiProperty,
        selector: RasiSelector,
        point: RasiPoint,
        referenceStack: [String]
    ) -> RasiResolvedValue? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "inherit" {
            guard selector != .global,
                let inherited = visual.last(where: { $0.selector == .global && $0.property == property })
            else {
                warn(.missingReference, "inherit has no global '\(property.rawValue)' value", at: point)
                return nil
            }
            return resolve(inherited, referenceStack: referenceStack)
        }
        if value.hasPrefix("@"), isIdentifier(String(value.dropFirst())) {
            return resolveVariable(
                String(value.dropFirst()),
                property: property,
                selector: selector,
                usePoint: point,
                stack: referenceStack
            )
        }
        if let variable = parseVariableFunction(value) {
            if variables[variable.name] != nil {
                return resolveVariable(
                    variable.name,
                    property: property,
                    selector: selector,
                    usePoint: point,
                    stack: referenceStack
                )
            }
            if let fallback = variable.fallback {
                return resolveRaw(
                    fallback,
                    property: property,
                    selector: selector,
                    point: point,
                    referenceStack: referenceStack
                )
            }
            warn(.missingReference, "variable '\(variable.name)' was not found", at: point)
            return nil
        }

        switch property {
        case .backgroundColor, .textColor, .borderColor:
            guard let color = parseColor(value) else {
                warn(.invalidValue, "invalid color '\(value)'", at: point)
                return nil
            }
            return .color(color)
        case .font:
            guard let string = parseQuotedString(value) else {
                warn(.unsupportedValue, "font requires a quoted string", at: point)
                return nil
            }
            return .font(string)
        case .width:
            guard let dimension = parseDimension(value, point: point), dimension.value >= 0 else {
                if dimensionWithoutWarning(value)?.value ?? 0 < 0 {
                    warn(.invalidValue, "width cannot be negative", at: point)
                }
                return nil
            }
            return .dimension(dimension)
        case .padding:
            guard let insets = parseInsets(value, point: point), dimensions(of: insets).allSatisfy({ $0.value >= 0 })
            else {
                if parseDimensionTokens(value).contains(where: { $0.value < 0 }) {
                    warn(.invalidValue, "padding cannot be negative", at: point)
                }
                return nil
            }
            return .insets(insets)
        case .border:
            return parseBorder(value, point: point).map(RasiResolvedValue.border)
        case .lines:
            guard let integer = Int(value), integer >= 0 else {
                warn(.invalidValue, "lines requires a nonnegative integer", at: point)
                return nil
            }
            return .integer(integer)
        case .location:
            guard let location = parseLocation(value, allowNumeric: selector == .configuration) else {
                warn(.invalidValue, "invalid location '\(value)'", at: point)
                return nil
            }
            return .location(location)
        }
    }

    mutating func resolveVariable(
        _ name: String,
        property: RasiProperty,
        selector: RasiSelector,
        usePoint: RasiPoint,
        stack: [String]
    ) -> RasiResolvedValue? {
        let normalized = asciiLowercased(name)
        if stack.contains(normalized) {
            warn(.referenceCycle, "reference cycle includes '@\(normalized)'", at: usePoint)
            return nil
        }
        guard let definition = variables[normalized] else {
            warn(.missingReference, "variable '@\(normalized)' was not found", at: usePoint)
            return nil
        }
        return resolveRaw(
            definition.rawValue,
            property: property,
            selector: selector,
            point: definition.point,
            referenceStack: stack + [normalized]
        )
    }

    mutating func parseDimension(_ raw: String, point: RasiPoint) -> RasiDimension? {
        guard let parsed = splitDimension(raw) else {
            warn(.unsupportedValue, "expected a dimension, got '\(raw)'", at: point)
            return nil
        }
        guard let unit = parsed.unit else {
            warn(.unsupportedUnit, "dimension unit '\(parsed.suffix)' is not supported", at: point)
            return nil
        }
        return RasiDimension(value: parsed.value, unit: unit)
    }

    mutating func parseInsets(_ raw: String, point: RasiPoint) -> RasiInsets? {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...4).contains(tokens.count) else {
            warn(.unsupportedValue, "insets require one through four dimensions", at: point)
            return nil
        }
        var values: [RasiDimension] = []
        for token in tokens {
            guard let dimension = parseDimension(token, point: point) else { return nil }
            values.append(dimension)
        }
        switch values.count {
        case 1:
            return .all(values[0])
        case 2:
            return RasiInsets(top: values[0], right: values[1], bottom: values[0], left: values[1])
        case 3:
            return RasiInsets(top: values[0], right: values[1], bottom: values[2], left: values[1])
        default:
            return RasiInsets(top: values[0], right: values[1], bottom: values[2], left: values[3])
        }
    }

    mutating func parseBorder(_ raw: String, point: RasiPoint) -> RasiBorder? {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var dimensions: [String] = []
        var sawStyle = false
        for token in tokens {
            switch asciiLowercased(token) {
            case "solid":
                sawStyle = true
            case "dash", "dashed":
                sawStyle = true
                warn(.approximation, "dashed border is retained as solid", at: point)
            default:
                dimensions.append(token)
            }
        }
        guard !dimensions.isEmpty, dimensions.count <= 4 else {
            warn(.unsupportedValue, "border requires one through four dimensions", at: point)
            return nil
        }
        guard let widths = parseInsets(dimensions.joined(separator: " "), point: point) else { return nil }
        guard self.dimensions(of: widths).allSatisfy({ $0.value >= 0 }) else {
            warn(.invalidValue, "border cannot be negative", at: point)
            return nil
        }
        _ = sawStyle
        return RasiBorder(widths: widths, style: .solid)
    }

    func parseColor(_ raw: String) -> RasiColor? {
        if let named = rasiNamedColor(raw) { return named }
        if raw.hasPrefix("#") { return parseHexColor(String(raw.dropFirst())) }
        let lower = asciiLowercased(raw)
        if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            return parseFunctionalColor(lower, alphaExpected: false)
        }
        if lower.hasPrefix("rgba(") && lower.hasSuffix(")") {
            return parseFunctionalColor(lower, alphaExpected: true)
        }
        return nil
    }

    func parseHexColor(_ digits: String) -> RasiColor? {
        let expanded: String
        switch digits.count {
        case 3, 4:
            expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = digits
        default:
            return nil
        }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let redShift = hasAlpha ? 24 : 16
        let greenShift = hasAlpha ? 16 : 8
        let blueShift = hasAlpha ? 8 : 0
        return RasiColor(
            red: Double((value >> redShift) & 0xFF) / 255,
            green: Double((value >> greenShift) & 0xFF) / 255,
            blue: Double((value >> blueShift) & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    func parseFunctionalColor(_ raw: String, alphaExpected: Bool) -> RasiColor? {
        guard let open = raw.firstIndex(of: "("), raw.last == ")" else { return nil }
        let arguments = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard arguments.count == (alphaExpected ? 4 : 3) else { return nil }
        var channels: [Double] = []
        for argument in arguments.prefix(3) {
            let channel: Double?
            if argument.hasSuffix("%"), let percent = Double(argument.dropLast()) {
                channel = percent / 100
            } else if let number = Double(argument) {
                channel = number / 255
            } else {
                channel = nil
            }
            guard let channel, (0...1).contains(channel) else { return nil }
            channels.append(channel)
        }
        var alpha = 1.0
        if alphaExpected {
            let argument = arguments[3]
            if argument.hasSuffix("%"), let percent = Double(argument.dropLast()) {
                alpha = percent / 100
            } else if let number = Double(argument) {
                alpha = number
            } else {
                return nil
            }
            guard (0...1).contains(alpha) else { return nil }
        }
        return RasiColor(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    func splitDimension(_ raw: String) -> (value: Double, unit: RasiDimensionUnit?, suffix: String)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var split = value.startIndex
        if split < value.endIndex, value[split] == "+" || value[split] == "-" {
            split = value.index(after: split)
        }
        var sawDigit = false
        var sawDot = false
        while split < value.endIndex {
            let character = value[split]
            if character.isNumber {
                sawDigit = true
            } else if character == ".", !sawDot {
                sawDot = true
            } else {
                break
            }
            split = value.index(after: split)
        }
        guard sawDigit, let number = Double(value[..<split]) else { return nil }
        let suffix = asciiLowercased(String(value[split...]))
        let unit: RasiDimensionUnit?
        switch suffix {
        case "", "px":
            unit = .pixels
        case "em":
            unit = .em
        case "ch":
            unit = .ch
        case "%":
            unit = .percent
        default:
            unit = nil
        }
        return (number, unit, suffix)
    }

    func dimensionWithoutWarning(_ raw: String) -> RasiDimension? {
        guard let parsed = splitDimension(raw), let unit = parsed.unit else { return nil }
        return RasiDimension(value: parsed.value, unit: unit)
    }

    func parseDimensionTokens(_ raw: String) -> [RasiDimension] {
        raw.split(whereSeparator: \.isWhitespace).compactMap { dimensionWithoutWarning(String($0)) }
    }

    func dimensions(of insets: RasiInsets) -> [RasiDimension] {
        [insets.top, insets.right, insets.bottom, insets.left]
    }

    func parseLocation(_ raw: String, allowNumeric: Bool) -> RasiLocation? {
        let normalized = asciiLowercased(raw).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let location = RasiLocation(rawValue: normalized) { return location }
        guard allowNumeric, let number = Int(normalized) else { return nil }
        return [
            .center, .northWest, .north, .northEast, .east, .southEast, .south, .southWest, .west,
        ][safe: number]
    }

    func parseVariableFunction(_ raw: String) -> (name: String, fallback: String?)? {
        let lower = asciiLowercased(raw)
        guard lower.hasPrefix("var("), raw.hasSuffix(")") else { return nil }
        let start = raw.index(raw.startIndex, offsetBy: 4)
        let body = String(raw[start..<raw.index(before: raw.endIndex)])
        let parts = splitTopLevelComma(body)
        guard (1...2).contains(parts.count) else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed = name.hasPrefix("@") ? String(name.dropFirst()) : name
        guard isIdentifier(unprefixed) else { return nil }
        return (asciiLowercased(unprefixed), parts.count == 2 ? parts[1] : nil)
    }

    func splitTopLevelComma(_ value: String) -> [String] {
        var depth = 0
        for index in value.indices {
            if value[index] == "(" {
                depth += 1
            } else if value[index] == ")" {
                depth -= 1
            } else if value[index] == ",", depth == 0 {
                return [String(value[..<index]), String(value[value.index(after: index)...])]
            }
        }
        return [value]
    }

    func parseQuotedString(_ raw: String) -> String? {
        guard raw.count >= 2, let first = raw.first, first == raw.last, first == "\"" || first == "'" else {
            return nil
        }
        var result = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
    }

    func isSupported(_ selector: RasiSelector) -> Bool {
        switch selector.name {
        case "*", "configuration", "window", "mainbox", "listview":
            return selector.states.isEmpty
        case "entry", "prompt", "message", "button", "mode-switcher":
            return selector.states.allSatisfy { $0 == "selected" }
        case "element":
            let allowed = Set(["normal", "alternate", "selected", "active", "urgent"])
            let states = Set(selector.states)
            return states.isSubset(of: allowed)
                && !states.isEmpty
                && !(states.contains("selected") && states.contains("alternate"))
                && !(states.contains("active") && states.contains("urgent"))
        default:
            return false
        }
    }

    func supports(_ property: RasiProperty, on selector: RasiSelector) -> Bool {
        switch selector.name {
        case "*":
            return ![.lines, .location].contains(property)
        case "configuration":
            return [.lines, .location].contains(property)
        case "window":
            return property != .lines
        case "mainbox":
            return [.borderColor, .padding, .border].contains(property)
        case "listview":
            return property == .lines
        case "element":
            return [.backgroundColor, .textColor].contains(property)
        case "entry", "prompt", "message", "button", "mode-switcher":
            return [.backgroundColor, .textColor, .borderColor].contains(property)
        default:
            return false
        }
    }

    func selectorLabel(_ selector: RasiSelector) -> String {
        ([selector.name] + selector.states).joined(separator: " ")
    }

    mutating func warn(_ code: RasiDiagnosticCode, _ message: String, at point: RasiPoint) {
        warnings.append(
            RasiDiagnostic(
                severity: .warning,
                code: code,
                message: message,
                source: point.source,
                line: point.line,
                column: point.column
            )
        )
    }

    func fatal(_ code: RasiDiagnosticCode, _ message: String, at point: RasiPoint) -> RasiFailure {
        RasiFailure(
            diagnostic: RasiDiagnostic(
                severity: .error,
                code: code,
                message: message,
                source: point.source,
                line: point.line,
                column: point.column
            )
        )
    }

    func point(for source: RasiSource) -> RasiPoint {
        RasiPoint(source: source.identity, line: 1, column: 1)
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
