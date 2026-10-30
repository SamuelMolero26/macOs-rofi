import Foundation
import RofiCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rofi: \(message)\n".utf8))
    exit(1)
}

let args = Arguments(CommandLine.arguments)

// The UI, script mode and the rest of the CLI arrive in later features.
guard args.has("-dmenu"), args.has("-dump") else { fail("not implemented yet") }

let dump: DmenuPipeline
do {
    dump = try DmenuPipeline(arguments: args)
} catch {
    fail("\(error)")
}

// `-dump` reads synchronously; `-input` is opened as given
// (source/modes/dmenu.c:536-542, 639-656).
var input = STDIN_FILENO
if let path = args.string("-input") {
    input = open(path, O_RDONLY | O_CLOEXEC)
    if input == -1 { fail("Failed to open file: \(path): \(String(cString: strerror(errno)))") }
}

let rows = readRows(fileDescriptor: input, separator: dump.separator)
FileHandle.standardOutput.write(Data(dump.dump(rows: rows).joined().utf8))
exit(0)
