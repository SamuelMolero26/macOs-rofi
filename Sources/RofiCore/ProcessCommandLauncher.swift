import Foundation

// ponytail: the only code in the terminal seam without a unit test; it is a thin
// wrapper over Process and FileManager, and tests inject fakes instead.

/// Real `CommandLauncher`: direct argv, no shell, does not wait for the child.
public func launchWithProcess(_ argv: [String]) -> Result<Void, ApplicationLaunchFailure> {
    let command = argv.joined(separator: " ")
    guard let program = argv.first else {
        return .failure(ApplicationLaunchFailure(command: command, reason: "empty command"))
    }
    let process = Process()
    if program.contains("/") {
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(argv.dropFirst())
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
    }
    do {
        try process.run()
        return .success(())
    } catch {
        return .failure(
            ApplicationLaunchFailure(command: command, reason: error.localizedDescription))
    }
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
