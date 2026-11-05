import Foundation

/// One installed application as the Applications mode understands it.
///
/// The record normalizes identity and presentation once, so modes and native
/// catalog adapters do not need to repeat bundle fallback rules.
public struct ApplicationRecord: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let bundlePath: String
    public let iconPath: String

    /// Creates a normalized application record. A localized display name wins
    /// over the bundle name, then the bundle's filename supplies the fallback.
    /// Missing identifiers use the bundle path as a stable local identity.
    public init(
        identifier: String?, localizedDisplayName: String?, bundleName: String?, bundlePath: String,
        iconPath: String? = nil
    ) {
        self.identifier = nonEmptyApplicationValue(identifier) ?? bundlePath
        self.displayName =
            nonEmptyApplicationValue(localizedDisplayName) ?? nonEmptyApplicationValue(bundleName)
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        self.bundlePath = bundlePath
        self.iconPath = nonEmptyApplicationValue(iconPath) ?? bundlePath
    }
}

/// Supplies normalized installed applications. Native discovery adapters can
/// replace the compatibility filesystem catalog without changing `DrunMode`.
public protocol ApplicationCatalog {
    func applications() -> [ApplicationRecord]
}

/// A failed application launch, retaining rofi's user-visible error wording.
public struct ApplicationLaunchFailure: Error, Equatable, Sendable {
    public let command: String
    public let reason: String

    public init(command: String, reason: String) {
        self.command = command
        self.reason = reason
    }

    public var dialogText: String { "Failed to execute: '\(command)'\nError: '\(reason)'" }
}

/// Launches one normalized application record.
public typealias ApplicationLauncher = (ApplicationRecord) -> Result<Void, ApplicationLaunchFailure>

/// Compatibility discovery used until the native AppKit catalog is assembled.
/// It intentionally contains no Spotlight or AppKit behavior.
struct FileSystemApplicationCatalog: ApplicationCatalog {
    let directories: [String]
    private let fileManager: FileManager

    init(home: String, directories: [String]? = nil, fileManager: FileManager = .default) {
        self.directories = directories ?? Self.applicationDirectories(home: home)
        self.fileManager = fileManager
    }

    static func applicationDirectories(home: String) -> [String] {
        [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", home + "/Applications",
        ]
    }

    func applications() -> [ApplicationRecord] {
        var found: [ApplicationRecord] = []
        var seen: Set<String> = []
        for directory in directories {
            walk(directory, into: &found, seen: &seen)
        }
        return found
    }

    /// Hidden entries are skipped, plain folders are walked, and application
    /// bundles are records rather than traversal roots. Linked folders are not
    /// followed, while linked bundles remain launchable records.
    private func walk(
        _ directory: String, into found: inout [ApplicationRecord], seen: inout Set<String>
    ) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names where !name.hasPrefix(".") {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let isApplication = name.lowercased().hasSuffix(".app")
            if !isApplication {
                if !isSymbolicLink(path) { walk(path, into: &found, seen: &seen) }
                continue
            }

            let metadata = bundleMetadata(at: path)
            let application = ApplicationRecord(
                identifier: metadata.identifier, localizedDisplayName: metadata.displayName,
                bundleName: metadata.name, bundlePath: path)
            guard seen.insert(application.identifier).inserted else { continue }
            found.append(application)
        }
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    private func bundleMetadata(at path: String) -> (
        identifier: String?, displayName: String?, name: String?
    ) {
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        return (
            plist?["CFBundleIdentifier"] as? String,
            plist?["CFBundleDisplayName"] as? String,
            plist?["CFBundleName"] as? String
        )
    }
}

/// Compatibility launcher used until the native AppKit launcher is assembled.
/// Unlike the file browser opener, its interface accepts an application record
/// and its failure type belongs to the application module.
func launchApplicationWithSystemOpener(
    _ application: ApplicationRecord
) -> Result<Void, ApplicationLaunchFailure> {
    let path = application.bundlePath
    let command = "/usr/bin/open '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [path]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return .failure(ApplicationLaunchFailure(command: command, reason: error.localizedDescription))
    }
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = text.isEmpty ? "exited with status \(process.terminationStatus)" : text
        return .failure(ApplicationLaunchFailure(command: command, reason: reason))
    }
    return .success(())
}

private func nonEmptyApplicationValue(_ value: String?) -> String? {
    value?.isEmpty == false ? value : nil
}
