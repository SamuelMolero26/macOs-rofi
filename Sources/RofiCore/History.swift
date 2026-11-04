import Foundation

/// rofi's usage history file (source/history.c, include/history.h:51-70):
/// one `<count> <entry>` line per entry, sorted by count descending, with
/// counts rebased so the smallest is 0. Settings default as in
/// config/config.c:103-161.
public struct History: Sendable {
    public let url: URL
    /// `max_history_size`: entries kept when writing.
    public var maxSize = 25
    /// `disable_history`: no reads or writes at all.
    public var disabled = false
    /// `ignored_prefixes`: `;`-separated entry prefixes `set` skips.
    public var ignoredPrefixes = ""

    public init(url: URL) { self.url = url }

    /// `history_set` (source/history.c:181-261): bump the first entry equal
    /// byte for byte, or append it with count 1. An unreadable file counts
    /// as empty.
    public func set(_ entry: String) {
        guard !disabled, !isIgnored(entry) else { return }
        var list = read().map { getlines($0).compactMap(parseElement) } ?? []
        let name = Array(entry.utf8)
        if let i = list.firstIndex(where: { $0.name == name }) {
            list[i].index += 1
        } else {
            list.append((1, name))
        }
        write(list)
    }

    /// `history_remove` (source/history.c:263-325): the last entry moves into
    /// the removed slot before sorting. A missing file or entry writes nothing.
    public func remove(_ entry: String) {
        guard !disabled, let data = read() else { return }
        var list = getlines(data).compactMap(parseElement)
        let name = Array(entry.utf8)
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        list.swapAt(i, list.count - 1)
        list.removeLast()
        write(list)
    }

    /// `history_get_list` (source/history.c:327-353): the text after each
    /// line's first space, in file order. A missing file is an empty list.
    public func list() -> [String] {
        guard !disabled, let data = read() else { return [] }
        // ponytail: invalid UTF-8 decodes to U+FFFD; rofi hands back raw bytes.
        return getlines(data).compactMap(parseField).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The `ignored_prefixes` check in `history_set` (source/history.c:188-202).
    /// strtok skips empty tokens; a token of only spaces strips to "" and so
    /// ignores everything. rofi's strtok also truncates the config string
    /// after the first call; that bug is not reproduced.
    private func isIgnored(_ entry: String) -> Bool {
        ignoredPrefixes.split(separator: ";").contains { token in
            entry.utf8.starts(with: Substring(token.unicodeScalars.drop(while: isSpace)).utf8)
        }
    }

    private func read() -> Data? { try? Data(contentsOf: url) }

    /// `__history_write_element_list` (source/history.c:58-77): stable sort
    /// by count descending, take the minimum before capping, then write.
    private func write(_ list: [Element]) {
        let sorted = list.enumerated()
            .sorted {
                $0.element.index != $1.element.index ? $0.element.index > $1.element.index : $0.offset < $1.offset
            }
            .map(\.element)
        var out: [UInt8] = []
        if let min = sorted.last?.index {
            for element in sorted.prefix(maxSize) {
                out += Array("\(element.index - min) ".utf8) + element.name + [0x0A]
            }
        }
        // ponytail: rofi g_warning()s when the write fails; it is dropped here.
        try? Data(out).write(to: url)
    }
}

private typealias Element = (index: Int, name: [UInt8])

/// The file split as `getline` returns it: each line keeps its `\n`, and an
/// unterminated last line has none.
private func getlines(_ data: Data) -> [[UInt8]] {
    var lines: [[UInt8]] = []
    var line: [UInt8] = []
    for byte in data {
        line.append(byte)
        if byte == 0x0A {
            lines.append(line)
            line = []
        }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// `__history_get_element_list` (source/history.c:132-179): a `strtol`
/// count, one skipped byte, then a non-empty name. The last byte is always
/// dropped as the `\n`, even on an unterminated last line.
private func parseElement(_ line: [UInt8]) -> Element? {
    let l = line.count
    guard l > 1 else { return nil }
    let buffer = line.map { CChar(bitPattern: $0) } + [0]
    let (index, end) = buffer.withUnsafeBufferPointer { p in
        var end: UnsafeMutablePointer<CChar>?
        let index = strtol(p.baseAddress, &end, 10)
        return (index, UnsafePointer(end!) - p.baseAddress!)
    }
    guard end > 0, buffer[end] != 0 else { return nil }
    let start = end + 1
    guard l - start >= 2 else { return nil }
    return (index, Array(line[start..<l - 1].prefix { $0 != 0 }))
}

/// `__history_get_element_list_fields` (source/history.c:80-130): everything
/// after the first space, minus the last byte; no count is required.
private func parseField(_ line: [UInt8]) -> [UInt8]? {
    guard let space = line.prefix(while: { $0 != 0 }).firstIndex(of: 0x20) else { return nil }
    let start = space + 1
    return Array(line[start..<max(start, line.count - 1)].prefix { $0 != 0 })
}
