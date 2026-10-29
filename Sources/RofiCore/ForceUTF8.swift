/// Decodes bytes the way rofi's `rofi_force_utf8` does
/// (source/helper.c:862-888): it keeps the longest valid prefix, adds one
/// U+FFFD, then skips exactly one byte. So every invalid byte gets its own
/// replacement, unlike `String(decoding:)`, which uses one per maximal subpart.
public func forceUTF8<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var rest = bytes[...]
    var out = String.UnicodeScalarView()
    while true {
        var iterator = rest.makeIterator()
        var parser = Unicode.UTF8.ForwardParser()
        switch parser.parseScalar(from: &iterator) {
        case .valid(let encoded):
            out.append(Unicode.UTF8.decode(encoded))
            rest = rest.dropFirst(encoded.count)
        case .error:
            out.append("\u{FFFD}")
            rest = rest.dropFirst()
        case .emptyInput:
            return String(out)
        }
    }
}
