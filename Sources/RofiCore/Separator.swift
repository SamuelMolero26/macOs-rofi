import Darwin

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
        return arg.withCString { pointer in
            // `strtol` supplies whitespace/sign/prefix handling and clamps
            // overflow; truncation retains the low byte of C's `char` cast.
            UInt8(truncatingIfNeeded: strtol(pointer.advanced(by: 2), nil, 16))
        }
    }
    return UInt8(ascii: "\n")
}

private let escapes: [UInt8: UInt8] = [
    UInt8(ascii: "n"): 0x0A, UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08,
    UInt8(ascii: "t"): 0x09, UInt8(ascii: "v"): 0x0B, UInt8(ascii: "f"): 0x0C,
    UInt8(ascii: "r"): 0x0D, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "0"): 0x00,
]
