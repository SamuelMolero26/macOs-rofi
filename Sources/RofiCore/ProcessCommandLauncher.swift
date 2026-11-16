import Foundation

// ponytail: `launchWithProcess` and `writeTemporaryScript` have no unit test;
// they are thin wrappers over Process and FileManager, and tests inject fakes
// instead. `generateWithProcess` is tested against `/bin/sh`.

/// Real `CommandLauncher`: direct argv, no shell, does not wait for the child.
public func launchWithProcess(_ argv: [String]) -> Result<Void, ApplicationLaunchFailure> {
    let command = argv.joined(separator: " ")
    guard let process = makeProcess(argv) else {
        return .failure(ApplicationLaunchFailure(command: command, reason: "empty command"))
    }
    do {
        try process.run()
        return .success(())
    } catch {
        return .failure(
            ApplicationLaunchFailure(command: command, reason: error.localizedDescription))
    }
}

/// Real `ListGenerator` (`execute_generator`, source/helper.c:562-583): runs
/// `argv` with no shell and returns its stdout split on newlines, read as
/// `getline` does in run.c:194-199; stdin and stderr are inherited and the
/// exit status is ignored.
///
/// ponytail: synchronous, with `timeout` (2 seconds by default) as the ceiling
/// for the whole call; upstream reads the pipe asynchronously, and streaming
/// rows in is the upgrade path. The deadline is on end of file, not on the
/// child's exit, so a background grandchild that keeps stdout open (`sleep 60
/// &`) times out too instead of blocking. On timeout the child is terminated
/// and its output discarded.
public func generateWithProcess(
    _ argv: [String], timeout: TimeInterval = 2
) -> Result<[String], ApplicationLaunchFailure> {
    let command = argv.joined(separator: " ")
    guard let process = makeProcess(argv) else {
        return .failure(ApplicationLaunchFailure(command: command, reason: "empty command"))
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    let reader = pipe.fileHandleForReading
    let output = OutputCollector()
    // Reads on a dispatch queue, so this thread only waits on the deadline.
    reader.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            output.finish()
        } else {
            output.append(chunk)
        }
    }
    do {
        try process.run()
    } catch {
        reader.readabilityHandler = nil
        return .failure(ApplicationLaunchFailure(command: command, reason: error.localizedDescription))
    }
    guard output.wait(seconds: timeout) else {
        // The read end is left to the pipe's deallocation: closing it here could
        // race a handler call already in flight.
        reader.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return .failure(
            ApplicationLaunchFailure(
                command: command, reason: "list command timed out after \(String(format: "%g", timeout)) seconds"))
    }
    return .success(lines(output.data))
}

/// Real `ScriptWriter`: unpredictable name in the temp directory, `.command`.
public func writeTemporaryScript(_ contents: String, mode: Int) -> Result<String, ApplicationLaunchFailure> {
    let path = NSTemporaryDirectory() + "rofi-\(UUID().uuidString).command"
    let created = FileManager.default.createFile(
        atPath: path, contents: Data(contents.utf8), attributes: [.posixPermissions: mode])
    return created
        ? .success(path)
        : .failure(ApplicationLaunchFailure(command: path, reason: "cannot write temporary script"))
}

/// A process for `argv`, nil when it is empty. A bare name goes through
/// `/usr/bin/env`, which searches `$PATH` as G_SPAWN_SEARCH_PATH does.
private func makeProcess(_ argv: [String]) -> Process? {
    guard let program = argv.first else { return nil }
    let process = Process()
    if program.contains("/") {
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(argv.dropFirst())
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
    }
    return process
}

/// `getline` lines: split on `\n`, with no empty line after a final newline;
/// a `\r` stays.
private func lines(_ data: Data) -> [String] {
    var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    if parts.last?.isEmpty == true { parts.removeLast() }
    return parts.map { String(decoding: $0, as: UTF8.self) }
}

/// Stdout gathered by the readability handler, and its end of file.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let ended = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    func finish() { ended.signal() }

    /// Whether end of file arrived within `seconds`.
    func wait(seconds: TimeInterval) -> Bool { ended.wait(timeout: .now() + seconds) == .success }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
