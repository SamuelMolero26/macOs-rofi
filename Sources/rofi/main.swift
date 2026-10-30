import Foundation
import RofiAppKit
import RofiCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rofi: \(message)\n".utf8))
    exit(1)
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

// `-dump` reads synchronously; `-input` is opened as given
// (source/modes/dmenu.c:536-542, 639-656).
var input = STDIN_FILENO
if let path = args.string("-input") {
    input = open(path, O_RDONLY | O_CLOEXEC)
    if input == -1 { fail("Failed to open file: \(path): \(String(cString: strerror(errno)))") }
}

let rows = pipeline.isAsync ? [] : readRows(fileDescriptor: input, separator: pipeline.separator)
if args.has("-dump") {
    FileHandle.standardOutput.write(Data(pipeline.dump(rows: rows).joined().utf8))
    exit(0)
}

switch pipeline.start(rows: rows) {
case .completed(let completion):
    finish(completion)
case .session(let session):
    // The reader dies with the process when `finish` exits.
    finish(runDmenuPanel(session: session, streaming: pipeline.isAsync ? (input, pipeline.separator) : nil))
}
