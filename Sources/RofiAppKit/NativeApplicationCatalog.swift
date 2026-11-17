import AppKit
import RofiCore

struct ApplicationBundleMetadata: Equatable {
    let identifier: String?
    let localizedDisplayName: String?
    let bundleName: String?
}

func applicationBundleMetadata(
    bundleIdentifier: String?, localizedInfo: [String: Any]?, info: [String: Any]?
) -> ApplicationBundleMetadata {
    ApplicationBundleMetadata(
        identifier: nonEmptyMetadataValue(bundleIdentifier),
        localizedDisplayName: metadataValue("CFBundleDisplayName", in: localizedInfo)
            ?? metadataValue("CFBundleName", in: localizedInfo),
        bundleName: metadataValue("CFBundleDisplayName", in: info)
            ?? metadataValue("CFBundleName", in: info))
}

protocol NativeApplicationWorkspace: AnyObject {
    func applicationURL(forBundleIdentifier identifier: String) -> URL?
    func open(_ url: URL) -> Bool
}

/// Native macOS application discovery and behavior.
///
/// Applications are discovered by scanning the fixed application roots.
public final class NativeApplicationCatalog {
    private let roots: [URL]
    private let scanRoots: ([URL]) -> [URL]
    private let readMetadata: @Sendable (URL) -> ApplicationBundleMetadata?
    private let canonicalize: (URL) -> URL
    private let workspace: any NativeApplicationWorkspace

    public convenience init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.init(
            roots: Self.applicationRoots(homeDirectory: homeDirectory),
            scanRoots: scanApplicationRoots,
            readMetadata: readApplicationBundleMetadata,
            canonicalize: canonicalApplicationURL,
            workspace: SystemApplicationWorkspace())
    }

    init(
        roots: [URL],
        scanRoots: @escaping ([URL]) -> [URL],
        readMetadata: @escaping @Sendable (URL) -> ApplicationBundleMetadata?,
        canonicalize: @escaping (URL) -> URL,
        workspace: any NativeApplicationWorkspace
    ) {
        self.roots = roots
        self.scanRoots = scanRoots
        self.readMetadata = readMetadata
        self.canonicalize = canonicalize
        self.workspace = workspace
    }

    public func applications() -> [ApplicationRecord] {
        var applications: [ApplicationRecord] = []
        var seenPaths: Set<String> = []
        var seenIdentifiers: Set<String> = []
        let candidates = scanRoots(roots)
        // Bundle reads dominate the scan and NSBundle is thread-safe. One slot
        // per candidate keeps the scan order, so deduplication is unchanged.
        var metadata = [ApplicationBundleMetadata?](repeating: nil, count: candidates.count)
        metadata.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let slots = buffer
            let read = readMetadata
            DispatchQueue.concurrentPerform(iterations: candidates.count) { slots[$0] = read(candidates[$0]) }
        }

        for (candidate, metadata) in zip(candidates, metadata) {
            guard let metadata else { continue }
            let workspaceURL = metadata.identifier.flatMap {
                workspace.applicationURL(forBundleIdentifier: $0)
            }
            let applicationURL = canonicalize(workspaceURL ?? candidate)
            let pathKey = applicationURL.path
            let identifierKey = metadata.identifier?.lowercased()
            guard !seenPaths.contains(pathKey) else { continue }
            guard identifierKey.map({ !seenIdentifiers.contains($0) }) ?? true else { continue }

            seenPaths.insert(pathKey)
            if let identifierKey { seenIdentifiers.insert(identifierKey) }
            applications.append(
                ApplicationRecord(
                    identifier: metadata.identifier,
                    localizedDisplayName: metadata.localizedDisplayName,
                    bundleName: metadata.bundleName,
                    bundlePath: applicationURL.path))
        }
        return applications
    }

    /// Opens an application through public `NSWorkspace` behavior.
    public func launch(
        _ application: ApplicationRecord
    ) -> Result<Void, ApplicationLaunchFailure> {
        let url = URL(fileURLWithPath: application.bundlePath)
        guard workspace.open(url) else {
            return .failure(
                ApplicationLaunchFailure(
                    command: "open application \(shellQuote(url.path))",
                    reason: "NSWorkspace could not open the application"))
        }
        return .success(())
    }

    private static func applicationRoots(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
    }
}

private final class SystemApplicationWorkspace: NativeApplicationWorkspace {
    private let workspace = NSWorkspace.shared

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: identifier)
    }

    func open(_ url: URL) -> Bool { workspace.open(url) }
}

private func readApplicationBundleMetadata(at url: URL) -> ApplicationBundleMetadata? {
    guard let bundle = Bundle(url: url) else { return nil }
    return applicationBundleMetadata(
        bundleIdentifier: bundle.bundleIdentifier,
        localizedInfo: bundle.localizedInfoDictionary,
        info: bundle.infoDictionary)
}

/// Depth-first, in directory order: an `.app` is collected and not entered,
/// symlinks and other packages are not followed. `readdir`'s `d_type` avoids a
/// URL and a stat per entry, since a non-app tree in /Applications can hold
/// thousands of files.
/// ponytail: hidden means a dot name; the UF_HIDDEN flag is not checked.
private func scanApplicationRoots(_ roots: [URL]) -> [URL] {
    var applications: [URL] = []
    func walk(_ directory: String) {
        guard let stream = opendir(directory) else { return }
        var subdirectories: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let path = directory + "/" + name
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var status = stat()
                type = lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR ? DT_DIR : DT_REG
            }
            if type == DT_DIR { subdirectories.append(path) }
        }
        closedir(stream)
        for path in subdirectories {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                applications.append(url)
            } else if url.pathExtension.isEmpty
                || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
            {
                walk(path)
            }
        }
    }
    for root in roots { walk(root.path) }
    return applications
}

private func canonicalApplicationURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private func metadataValue(_ key: String, in dictionary: [String: Any]?) -> String? {
    nonEmptyMetadataValue(dictionary?[key] as? String)
}

private func nonEmptyMetadataValue(_ value: String?) -> String? {
    value?.isEmpty == false ? value : nil
}
