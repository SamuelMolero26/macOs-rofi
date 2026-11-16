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
    private let readMetadata: (URL) -> ApplicationBundleMetadata?
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
        readMetadata: @escaping (URL) -> ApplicationBundleMetadata?,
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

        for candidate in scanRoots(roots) {
            guard let metadata = readMetadata(candidate) else { continue }
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
                    bundlePath: applicationURL.path,
                    iconPath: applicationURL.path))
        }
        return applications
    }

    /// Opens an application through public `NSWorkspace` behavior.
    public func launch(
        _ application: ApplicationRecord
    ) -> Result<Void, ApplicationLaunchFailure> {
        let url = resolvedURL(for: application)
        guard workspace.open(url) else {
            return .failure(
                ApplicationLaunchFailure(
                    command: "open application \(shellQuote(url.path))",
                    reason: "NSWorkspace could not open the application"))
        }
        return .success(())
    }

    private func resolvedURL(for application: ApplicationRecord) -> URL {
        let workspaceURL = workspace.applicationURL(forBundleIdentifier: application.identifier)
        return canonicalize(workspaceURL ?? URL(fileURLWithPath: application.bundlePath))
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

private func scanApplicationRoots(_ roots: [URL]) -> [URL] {
    var applications: [URL] = []
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    for root in roots {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { continue }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true else {
                continue
            }
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                applications.append(url)
                enumerator.skipDescendants()
            } else if values.isSymbolicLink == true {
                enumerator.skipDescendants()
            }
        }
    }
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
