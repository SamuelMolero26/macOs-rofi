/// Parses a `-sep` value or a script `delim` header the way rofi's
/// `helper_parse_char` does (source/helper.c:383-429): a single character,
/// a backslash escape, or `\xHH`. Anything else falls back to newline.
public func parseSeparator(_ arg: String) -> UInt8 {
    let bytes = Array(arg.utf8)
    let backslash = UInt8(ascii: "\\")
    if bytes.count == 1 {
        return bytes[0]
    }
    if bytes.count == 2, bytes[0] == backslash, let escaped = escapes[bytes[1]] {
        return escaped
    }
    if bytes.count > 2, bytes[0] == backslash, bytes[1] == UInt8(ascii: "x") {
        // ponytail: leading hex digits only, like strtol on plain hex; its
        // whitespace/sign/0x-prefix forms are not supported.
        // Wrapping UInt8 math keeps the low byte, matching C's (char) cast.
        var value: UInt8 = 0
        for byte in bytes.dropFirst(2) {
            guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { break }
            value = value &* 16 &+ UInt8(digit)
        }
        return value
    }
    return UInt8(ascii: "\n")
}

private let escapes: [UInt8: UInt8] = [
    UInt8(ascii: "n"): 0x0A, UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08,
    UInt8(ascii: "t"): 0x09, UInt8(ascii: "v"): 0x0B, UInt8(ascii: "f"): 0x0C,
    UInt8(ascii: "r"): 0x0D, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "0"): 0x00,
]
