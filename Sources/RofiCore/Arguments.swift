import Foundation

/// The command line, looked up the way rofi's `find_arg*` helpers do
/// (source/helper.c:325-342, 373-380, 431-439). Like rofi, `argv` includes argv[0].
public struct Arguments: Sendable {
    public let argv: [String]
    private let rawArgv: [[UInt8]]

    public init(_ argv: [String]) {
        self.init(rawArgv: argv.map { Array($0.utf8) })
    }

    /// Builds an argument list without requiring its C bytes to be valid UTF-8.
    public init(rawArgv: [[UInt8]]) {
        self.rawArgv = rawArgv
        argv = rawArgv.map { String(decoding: $0, as: UTF8.self) }
    }

    /// `find_arg`: the first exact, ASCII case-insensitive match over every
    /// argument, values included.
    public func has(_ key: String) -> Bool {
        index(of: key) != nil
    }

    /// `find_arg_str`: the argument after the first occurrence, or nil when
    /// that occurrence is argv[0] or the last argument.
    public func string(_ key: String) -> String? {
        bytes(key).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `find_arg_str` without decoding, for values used as C strings.
    public func bytes(_ key: String) -> [UInt8]? {
        guard let i = index(of: key), i > 0, i < rawArgv.count - 1 else { return nil }
        return rawArgv[i + 1]
    }

    /// `find_arg_char`: the value parsed by `helper_parse_char`.
    public func char(_ key: String) -> UInt8? {
        bytes(key).map(parseSeparator)
    }

    /// `find_arg_uint`: `strtoul` narrowed to an unsigned int, so garbage is 0
    /// and a sign or overflow wraps.
    public func uint(_ key: String) -> UInt32? {
        string(key).map { UInt32(truncatingIfNeeded: strtoul($0, nil, 10)) }
    }

    /// A boolean option (source/xrmoptions.c:760-771): `-name` sets true;
    /// only when it is absent does `-no-name` set false.
    public func bool(_ name: String, default value: Bool) -> Bool {
        if has("-" + name) { return true }
        if has("-no-" + name) { return false }
        return value
    }

    private func index(of key: String) -> Int? {
        rawArgv.firstIndex { asciiCaseInsensitiveEqual($0, key) }
    }
}

/// `strcasecmp`: byte-wise, folding only ASCII letters.
private func asciiCaseInsensitiveEqual(_ a: [UInt8], _ b: String) -> Bool {
    a.elementsEqual(b.utf8) { lower($0) == lower($1) }
}

private func lower(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
}
