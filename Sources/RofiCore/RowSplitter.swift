/// Splits dmenu input into rows on a separator byte, as rofi's
/// `read_input_sync`/`read_input_thread` do (source/modes/dmenu.c:246-346).
/// Feed bytes as they arrive; each row is returned as soon as its separator
/// is seen. Empty rows are kept, and a trailing separator adds no row.
public struct RowSplitter: Sendable {
    public let separator: UInt8
    private var pending: [UInt8] = []

    public init(separator: UInt8 = 0x0A) {
        self.separator = separator
    }

    public mutating func feed<C: Collection>(_ bytes: C) -> [Row] where C.Element == UInt8 {
        var rows: [Row] = []
        for byte in bytes {
            if byte == separator {
                rows.append(Row(parsing: pending))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return rows
    }

    /// At end of input, an unterminated remainder becomes the last row.
    public mutating func finish() -> Row? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return Row(parsing: pending)
    }
}
