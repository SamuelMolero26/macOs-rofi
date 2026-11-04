import Foundation
import RofiAppKit
import RofiCore

func fail(_ message: String, status: Int32 = EXIT_FAILURE) -> Never {
    FileHandle.standardError.write(Data("rofi: \(message)\n".utf8))
    exit(status)
}

/// The path is decoded for display only.
func failToOpen(_ path: [UInt8]) -> Never {
    fail("Failed to open file: \(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(errno)))")
}

/// `path` as a C string: rofi passes argv bytes to fopen as they are.
func cString(_ path: [UInt8]) -> [CChar] {
    path.map { CChar(bitPattern: $0) } + [0]
}

/// Blocks on a FIFO with no writer. O_NONBLOCK would avoid that, but its
/// read() returns 0 with no writer, which looks like end of input.
func openInput(_ path: [UInt8]?) -> Int32 {
    guard let path else { return STDIN_FILENO }
    let input = open(cString(path), O_RDONLY | O_CLOEXEC)
    if input == -1 { failToOpen(path) }
    return input
}

func finish(_ completion: DmenuCompletion) -> Never {
    if let output = completion.output {
        FileHandle.standardOutput.write(Data(output.utf8))
    }
    exit(completion.outcome.exitCode)
}

func rawCommandLineArguments() -> [[UInt8]] {
    (0..<Int(CommandLine.argc)).map { index in
        guard let pointer = CommandLine.unsafeArgv[index] else { return [] }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: strlen(pointer)))
    }
}

/// Writes `text` on stderr as rofi's dialogs would show it.
func report(_ text: String) {
    FileHandle.standardError.write(Data("rofi: \(text)".utf8))
}

/// Script modes that could not start, worded as their error dialogs.
func reportFailedModes(_ modes: [any Mode]) -> Bool {
    let errors = modes.compactMap { ($0 as? ScriptMode)?.error }
    for error in errors { report(error + "\n") }
    return !errors.isEmpty
}

/// Everything outside dmenu: startup errors, then `-show`
/// (source/rofi.c:1243-1250, 869-958). Only dmenu sets a return code, so
/// accepting and cancelling both exit 0 (source/rofi.c:151).
/// ponytail: `-e`, `-help` and the other actions are not implemented and
/// leave rofi unsure what to show.
@MainActor func runShow(_ args: Arguments) -> Never {
    let options: ShowOptions
    do {
        options = try ShowOptions(arguments: args)
    } catch {
        fail("\(error)", status: (error as? InvalidModeConfiguration)?.exitStatus ?? EXIT_FAILURE)
    }
    if isatty(STDOUT_FILENO) == 1 {
        for warning in options.warnings { FileHandle.standardError.write(Data(warning.utf8)) }
    }
    guard let start = options.startIndex else {
        report(options.unsureWhatToShow)
        exit(EXIT_SUCCESS)
    }
    let modes = makeModes(options.modes)
    // run_mode_index: a script that cannot start shows an error dialog in
    // place of the view (source/rofi.c:201-216, source/modes/script.c:242-246).
    if reportFailedModes(modes) { exit(EXIT_SUCCESS) }
    let switcher = ModeSwitcher(modes: modes, displayNames: options.displayNames, start: start, match: options.match)
    runModePanel(switcher: switcher, sidebar: options.sidebarMode)
    // A later run that cannot start ends its mode with no rows; its dialog
    // would show after the view closes.
    _ = reportFailedModes(modes)
    exit(EXIT_SUCCESS)
}

let args = Arguments(rawArgv: rawCommandLineArguments())

// source/rofi.c:1043-1057.
let invokedAsDmenu = args.argv.first?.split(separator: "/").last == "dmenu"
guard args.has("-dmenu") || invokedAsDmenu else { runShow(args) }

let pipeline: DmenuPipeline
do {
    pipeline = try DmenuPipeline(arguments: args)
} catch {
    fail("\(error)", status: (error as? InvalidMatchingConfiguration)?.exitStatus ?? EXIT_FAILURE)
}

// `-dump` reads synchronously here; async input is opened on the reader thread,
// and `-input` is opened as given (source/modes/dmenu.c:536-542, 609-638, 639-656).
// `access` reports failures before the panel: opening a FIFO just to probe it
// would release a blocked writer and then leave it with no reader.
// ponytail: a path that stops being readable after this check fails with the
// panel already up.
let path = args.bytes("-input")
if pipeline.isAsync, let path, access(cString(path), R_OK) != 0 { failToOpen(path) }

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
