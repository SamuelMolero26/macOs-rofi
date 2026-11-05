import Foundation

public struct RasiDocument: Sendable {
    public let source: RasiSource
    let statements: [RasiStatement]

    public var statementCount: Int { statements.count }
}

public struct RasiParser: Sendable {
    public init() {}

    public func parse(_ source: RasiSource) throws -> RasiDocument {
        var parser = ParserState(source: source)
        return RasiDocument(source: source, statements: try parser.parse())
    }
}

struct RasiPoint: Equatable, Sendable {
    let source: String
    let line: Int
    let column: Int
}

struct RasiRawDeclaration: Sendable {
    let name: String
    let value: String
    let point: RasiPoint
}

enum RasiStatement: Sendable {
    case block(selectors: [RasiSelector], declarations: [RasiRawDeclaration])
    case load(target: String, kind: RasiLoadKind, point: RasiPoint)
}

private struct ParserState {
    private let source: RasiSource
    private let scalars: [UnicodeScalar]
    private var index = 0
    private var line = 1
    private var column = 1

    init(source: RasiSource) {
        self.source = source
        scalars = Array(source.text.unicodeScalars)
    }

    mutating func parse() throws -> [RasiStatement] {
        var statements: [RasiStatement] = []
        while true {
            try skipTrivia()
            guard !isAtEnd else { return statements }
            if current == "@" || current == "?" {
                statements.append(try parseDirective())
            } else {
                statements.append(try parseBlock())
            }
        }
    }

    private mutating func parseDirective() throws -> RasiStatement {
        let point = currentPoint
        let optional = current == "?"
        advance()
        let name = readIdentifier()
        let kind: RasiLoadKind
        switch (optional, name) {
        case (false, "import"):
            kind = .importTheme(optional: false)
        case (true, "import"):
            kind = .importTheme(optional: true)
        case (false, "theme"):
            kind = .replaceTheme
        default:
            throw failure(.malformedDirective, "expected @import, ?import, or @theme", at: point)
        }
        try skipTrivia()
        guard current == "\"" || current == "'" else {
            throw failure(.malformedDirective, "theme directive requires a quoted target", at: currentPoint)
        }
        let target = try parseString()
        try skipTrivia()
        if current == ";" { advance() }
        return .load(target: target, kind: kind, point: point)
    }

    private mutating func parseBlock() throws -> RasiStatement {
        let point = currentPoint
        var rawSelectors = ""
        while !isAtEnd && current != "{" {
            if current == "/", peek() == "/" {
                try skipLineComment()
                rawSelectors += " "
                continue
            }
            if current == "/", peek() == "*" {
                try skipBlockComment()
                rawSelectors += " "
                continue
            }
            if current == "}" || current == ";" {
                throw failure(.malformedStructure, "expected '{' after selector", at: currentPoint)
            }
            rawSelectors.unicodeScalars.append(current)
            advance()
        }
        guard current == "{" else {
            throw failure(.malformedStructure, "unterminated selector block", at: point)
        }
        let selectors = try parseSelectors(rawSelectors, at: point)
        advance()

        var declarations: [RasiRawDeclaration] = []
        while true {
            try skipTrivia()
            guard !isAtEnd else {
                throw failure(.malformedStructure, "unbalanced '{'", at: point)
            }
            if current == "}" {
                advance()
                return .block(selectors: selectors, declarations: declarations)
            }
            declarations.append(try parseDeclaration())
        }
    }

    private mutating func parseDeclaration() throws -> RasiRawDeclaration {
        let point = currentPoint
        let name = readIdentifier()
        guard !name.isEmpty else {
            throw failure(.malformedStructure, "expected declaration name", at: point)
        }
        try skipTrivia()
        guard current == ":" else {
            throw failure(.malformedStructure, "declaration '\(name)' is missing ':'", at: currentPoint)
        }
        advance()
        try skipTrivia()
        let value = try readDeclarationValue(start: currentPoint)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(.malformedStructure, "declaration '\(name)' has no value", at: point)
        }
        return RasiRawDeclaration(name: asciiLowercased(name), value: value, point: point)
    }

    private mutating func readDeclarationValue(start: RasiPoint) throws -> String {
        var result = ""
        var parentheses = 0
        var brackets = 0
        while !isAtEnd {
            if current == "\"" || current == "'" {
                result += try consumeRawString()
                continue
            }
            if current == "/", peek() == "/" {
                try skipLineComment()
                result += " "
                continue
            }
            if current == "/", peek() == "*" {
                try skipBlockComment()
                result += " "
                continue
            }
            switch current {
            case "(":
                parentheses += 1
            case ")":
                parentheses -= 1
                if parentheses < 0 {
                    throw failure(.malformedStructure, "unbalanced ')'", at: currentPoint)
                }
            case "[":
                brackets += 1
            case "]":
                brackets -= 1
                if brackets < 0 {
                    throw failure(.malformedStructure, "unbalanced ']'", at: currentPoint)
                }
            case ";" where parentheses == 0 && brackets == 0:
                advance()
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            case "}" where parentheses == 0 && brackets == 0:
                throw failure(.malformedStructure, "declaration is missing ';'", at: currentPoint)
            case "{":
                throw failure(.malformedStructure, "unexpected '{' in declaration", at: currentPoint)
            default:
                break
            }
            result.unicodeScalars.append(current)
            advance()
        }
        if parentheses != 0 || brackets != 0 {
            throw failure(.malformedStructure, "unbalanced value delimiter", at: start)
        }
        throw failure(.malformedStructure, "declaration is missing ';'", at: start)
    }

    private func parseSelectors(_ raw: String, at point: RasiPoint) throws -> [RasiSelector] {
        try raw.split(separator: ",", omittingEmptySubsequences: false).map { part in
            let normalized = part.replacingOccurrences(of: ".", with: " ")
            let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first, !name.isEmpty else {
                throw failure(.malformedStructure, "empty selector", at: point)
            }
            guard tokens.allSatisfy(isSelectorToken) else {
                throw failure(.malformedStructure, "malformed selector", at: point)
            }
            return RasiSelector(name: name, states: Array(tokens.dropFirst()))
        }
    }

    private func isSelectorToken(_ token: String) -> Bool {
        let body = token.hasPrefix("#") ? token.dropFirst() : token[...]
        return !body.isEmpty
            && body.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "*"
            }
    }

    private mutating func skipTrivia() throws {
        while true {
            while !isAtEnd && current.properties.isWhitespace { advance() }
            if current == "/", peek() == "/" {
                try skipLineComment()
            } else if current == "/", peek() == "*" {
                try skipBlockComment()
            } else {
                return
            }
        }
    }

    private mutating func skipLineComment() throws {
        advance()
        advance()
        while !isAtEnd && current != "\n" { advance() }
    }

    private mutating func skipBlockComment() throws {
        let point = currentPoint
        advance()
        advance()
        var depth = 1
        while !isAtEnd {
            if current == "/", peek() == "*" {
                depth += 1
                advance()
                advance()
            } else if current == "*", peek() == "/" {
                depth -= 1
                advance()
                advance()
                if depth == 0 { return }
            } else {
                advance()
            }
        }
        throw failure(.malformedStructure, "unterminated block comment", at: point)
    }

    private mutating func parseString() throws -> String {
        let raw = try consumeRawString()
        return String(raw.dropFirst().dropLast())
    }

    private mutating func consumeRawString() throws -> String {
        let point = currentPoint
        let quote = current
        var result = String(quote)
        advance()
        var escaped = false
        while !isAtEnd {
            let scalar = current
            result.unicodeScalars.append(scalar)
            advance()
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == quote {
                return result
            } else if scalar == "\n" {
                throw failure(.malformedStructure, "unterminated string", at: point)
            }
        }
        throw failure(.malformedStructure, "unterminated string", at: point)
    }

    private mutating func readIdentifier() -> String {
        let start = index
        while !isAtEnd,
            CharacterSet.alphanumerics.contains(current) || current == "-" || current == "_"
        {
            advance()
        }
        return text(from: start, to: index)
    }

    private var currentPoint: RasiPoint {
        RasiPoint(source: source.identity, line: line, column: column)
    }

    private var isAtEnd: Bool { index >= scalars.count }
    private var current: UnicodeScalar { isAtEnd ? "\0" : scalars[index] }

    private func peek() -> UnicodeScalar {
        index + 1 < scalars.count ? scalars[index + 1] : "\0"
    }

    private mutating func advance() {
        guard !isAtEnd else { return }
        if scalars[index] == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    private func text(from start: Int, to end: Int) -> String {
        String(scalars[start..<end].map(Character.init))
    }

    private func failure(_ code: RasiDiagnosticCode, _ message: String, at point: RasiPoint) -> RasiFailure {
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
}

func asciiLowercased(_ value: String) -> String {
    String(
        value.unicodeScalars.map { scalar in
            if scalar.value >= 65 && scalar.value <= 90 {
                return Character(UnicodeScalar(scalar.value + 32)!)
            }
            return Character(scalar)
        })
}
