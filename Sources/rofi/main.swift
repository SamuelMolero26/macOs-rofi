import Foundation
import RofiAppKit
import RofiCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rofi: \(message)\n".utf8))
    exit(1)
}

func failToOpen(_ path: String) -> Never {
    fail("Failed to open file: \(path): \(String(cString: strerror(errno)))")
}

/// Blocks on a FIFO with no writer. O_NONBLOCK would avoid that, but its
/// read() returns 0 with no writer, which looks like end of input.
func openInput(_ path: String?) -> Int32 {
    guard let path else { return STDIN_FILENO }
    let input = open(path, O_RDONLY | O_CLOEXEC)
    if input == -1 { failToOpen(path) }
    return input
}

func finish(_ completion: DmenuCompletion) -> Never {
    if let output = completion.output {
        FileHandle.standardOutput.write(Data(output.utf8))
    }
    exit(completion.outcome.exitCode)
}

let args = Arguments(CommandLine.arguments)

// Script mode and the rest of the CLI arrive in later features.
guard args.has("-dmenu") else { fail("not implemented yet") }

let pipeline: DmenuPipeline
do {
    pipeline = try DmenuPipeline(arguments: args)
} catch {
    fail("\(error)")
}

// `-dump` reads synchronously here; async input is opened on the reader thread,
// and `-input` is opened as given (source/modes/dmenu.c:536-542, 609-638, 639-656).
// `access` reports failures before the panel: opening a FIFO just to probe it
// would release a blocked writer and then leave it with no reader.
// ponytail: a path that stops being readable after this check fails with the
// panel already up.
let path = args.string("-input")
if pipeline.isAsync, let path, access(path, R_OK) != 0 { failToOpen(path) }

let rows = pipeline.isAsync ? [] : readRows(fileDescriptor: openInput(path), separator: pipeline.separator)
if args.has("-dump") {
    FileHandle.standardOutput.write(Data(pipeline.dump(rows: rows).joined().utf8))
    exit(0)
}

switch pipeline.start(rows: rows) {
case .completed(let completion):
    finish(completion)
case .session(let session):
    // The reader dies with the process when `finish` exits.
    finish(runDmenuPanel(session: session, streaming: pipeline.isAsync ? ({ [path] in openInput(path) }, pipeline.separator) : nil))
}
