import Foundation

public struct RasiSource: Equatable, Sendable {
    public let identity: String
    public let text: String

    public init(identity: String, text: String) {
        self.identity = identity
        self.text = text
    }

    public init(identity: String, bytes: [UInt8]) throws {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw RasiFailure(
                diagnostic: RasiDiagnostic(
                    severity: .error,
                    code: .invalidUTF8,
                    message: "source is not valid UTF-8",
                    source: identity,
                    line: 1,
                    column: 1
                )
            )
        }
        self.init(identity: identity, text: text)
    }
}

public enum RasiDiagnosticSeverity: Sendable {
    case warning
    case error
}

public enum RasiDiagnosticCode: String, Equatable, Sendable {
    case invalidUTF8
    case malformedStructure
    case malformedDirective
    case missingImport
    case missingOptionalImport
    case importCycle
    case resourceLimit
    case unsupportedSelector
    case unsupportedProperty
    case unsupportedValue
    case unsupportedUnit
    case invalidValue
    case missingReference
    case referenceCycle
    case approximation
}

public struct RasiDiagnostic: Equatable, Sendable {
    public let severity: RasiDiagnosticSeverity
    public let code: RasiDiagnosticCode
    public let message: String
    public let source: String
    public let line: Int
    public let column: Int

    public init(
        severity: RasiDiagnosticSeverity,
        code: RasiDiagnosticCode,
        message: String,
        source: String,
        line: Int,
        column: Int
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.source = source
        self.line = line
        self.column = column
    }
}

public struct RasiFailure: Error, Equatable, CustomStringConvertible, Sendable {
    public let diagnostic: RasiDiagnostic

    public init(diagnostic: RasiDiagnostic) {
        self.diagnostic = diagnostic
    }

    public var description: String {
        "\(diagnostic.source):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)"
    }
}

public struct RasiSelector: Hashable, Sendable {
    public let name: String
    public let states: [String]

    public init(name: String, states: [String] = []) {
        let normalizedName = Self.normalize(name.hasPrefix("#") ? String(name.dropFirst()) : name)
        var normalizedStates = Array(Set(states.map(Self.normalize))).sorted()
        if normalizedName == "element",
            normalizedStates.contains("selected") || normalizedStates.contains("alternate"),
            !normalizedStates.contains("normal"),
            !normalizedStates.contains("active"),
            !normalizedStates.contains("urgent")
        {
            normalizedStates.append("normal")
            normalizedStates.sort()
        }
        self.name = normalizedName
        self.states = normalizedStates
    }

    public static let global = RasiSelector(name: "*")
    public static let configuration = RasiSelector(name: "configuration")
    public static let window = RasiSelector(name: "window")
    public static let mainbox = RasiSelector(name: "mainbox")
    public static let listview = RasiSelector(name: "listview")

    public static func element(states: [String]) -> RasiSelector {
        RasiSelector(name: "element", states: states)
    }

    private static func normalize(_ value: String) -> String {
        String(
            value.unicodeScalars.map { scalar in
                if scalar.value >= 65 && scalar.value <= 90 {
                    return Character(UnicodeScalar(scalar.value + 32)!)
                }
                return Character(scalar)
            })
    }
}

public enum RasiProperty: String, CaseIterable, Sendable {
    case backgroundColor = "background-color"
    case textColor = "text-color"
    case borderColor = "border-color"
    case font
    case width
    case lines
    case location
    case padding
    case border
}

public struct RasiColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum RasiDimensionUnit: String, Equatable, Sendable {
    case pixels = "px"
    case em
    case ch
    case percent = "%"
}

public struct RasiDimension: Equatable, Sendable {
    public let value: Double
    public let unit: RasiDimensionUnit

    public init(value: Double, unit: RasiDimensionUnit = .pixels) {
        self.value = value
        self.unit = unit
    }

    public static func pixels(_ value: Double) -> RasiDimension {
        RasiDimension(value: value)
    }
}

public struct RasiInsets: Equatable, Sendable {
    public let top: RasiDimension
    public let right: RasiDimension
    public let bottom: RasiDimension
    public let left: RasiDimension

    public init(top: RasiDimension, right: RasiDimension, bottom: RasiDimension, left: RasiDimension) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public static func all(_ value: RasiDimension) -> RasiInsets {
        RasiInsets(top: value, right: value, bottom: value, left: value)
    }
}

public enum RasiBorderStyle: Equatable, Sendable {
    case solid
}

public struct RasiBorder: Equatable, Sendable {
    public let widths: RasiInsets
    public let style: RasiBorderStyle

    public init(widths: RasiInsets, style: RasiBorderStyle = .solid) {
        self.widths = widths
        self.style = style
    }
}

public enum RasiLocation: String, Equatable, Sendable {
    case center
    case north
    case northEast = "north east"
    case east
    case southEast = "south east"
    case south
    case southWest = "south west"
    case west
    case northWest = "north west"
}

public enum RasiResolvedValue: Equatable, Sendable {
    case color(RasiColor)
    case font(String)
    case dimension(RasiDimension)
    case insets(RasiInsets)
    case border(RasiBorder)
    case integer(Int)
    case location(RasiLocation)
}

public struct RasiResolvedDeclaration: Equatable, Sendable {
    public let selector: RasiSelector
    public let property: RasiProperty
    public let value: RasiResolvedValue
    public let source: String
    public let line: Int
    public let column: Int
    public let sourceOrder: Int
}

public struct RasiResolution: Equatable, Sendable {
    public let declarations: [RasiResolvedDeclaration]
    public let warnings: [RasiDiagnostic]
    public let loadedSources: [String]

    public init(
        declarations: [RasiResolvedDeclaration],
        warnings: [RasiDiagnostic],
        loadedSources: [String]
    ) {
        self.declarations = declarations
        self.warnings = warnings
        self.loadedSources = loadedSources
    }

    public func value(selector: RasiSelector, property: RasiProperty) -> RasiResolvedValue? {
        declarations.last { $0.selector == selector && $0.property == property }?.value
    }

    public func color(selector: RasiSelector, property: RasiProperty) -> RasiColor? {
        guard case .color(let color) = value(selector: selector, property: property) else { return nil }
        return color
    }
}

public enum RasiLoadKind: Sendable {
    case importTheme(optional: Bool)
    case replaceTheme
}

public struct RasiLoadRequest: Sendable {
    public let target: String
    public let kind: RasiLoadKind
    public let includingSource: String

    public init(target: String, kind: RasiLoadKind, includingSource: String) {
        self.target = target
        self.kind = kind
        self.includingSource = includingSource
    }
}
