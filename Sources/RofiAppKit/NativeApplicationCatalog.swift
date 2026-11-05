import AppKit
import CoreServices
import RofiCore

enum MetadataDiscoveryState: Equatable {
    case completed
    case timedOut
    case failed
}

struct MetadataDiscovery: Equatable {
    let state: MetadataDiscoveryState
    let urls: [URL]
}

protocol ApplicationMetadataQuery: AnyObject {
    var notificationObject: AnyObject { get }

    func start() -> Bool
    func disableUpdates()
    func stop()
    func resultPaths() -> [String]
}

typealias MetadataCompletionWaiter = (_ finished: () -> Bool, _ timeout: TimeInterval) -> Bool

struct BoundedMetadataQueryDiscovery {
    let makeQuery: () -> any ApplicationMetadataQuery
    let notificationCenter: NotificationCenter
    let waitForCompletion: MetadataCompletionWaiter

    init(
        makeQuery: @escaping () -> any ApplicationMetadataQuery = { SystemApplicationMetadataQuery() },
        notificationCenter: NotificationCenter = .default,
        waitForCompletion: @escaping MetadataCompletionWaiter = waitForMetadataQueryCompletion
    ) {
        self.makeQuery = makeQuery
        self.notificationCenter = notificationCenter
        self.waitForCompletion = waitForCompletion
    }

    func discover(timeout: TimeInterval) -> MetadataDiscovery {
        let query = makeQuery()
        let completion = MetadataQueryCompletion()
        let observer = notificationCenter.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query.notificationObject,
            queue: nil
        ) { _ in
            completion.finish()
        }
        defer { notificationCenter.removeObserver(observer) }

        guard query.start() else {
            return MetadataDiscovery(state: .failed, urls: [])
        }

        let completed = waitForCompletion(completion.isFinished, max(0, timeout))
        query.disableUpdates()
        let urls = query.resultPaths().compactMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        query.stop()
        return MetadataDiscovery(state: completed ? .completed : .timedOut, urls: urls)
    }
}

private final class MetadataQueryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class SystemApplicationMetadataQuery: ApplicationMetadataQuery {
    private let query: NSMetadataQuery

    init() {
        query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(
            format: "%K == %@", kMDItemContentType as String, "com.apple.application-bundle")
    }

    var notificationObject: AnyObject { query }

    func start() -> Bool { query.start() }
    func disableUpdates() { query.disableUpdates() }
    func stop() { query.stop() }

    func resultPaths() -> [String] {
        (0..<query.resultCount).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem else { return nil }
            return metadataItemPath { item.value(forAttribute: $0) }
        }
    }
}

func metadataItemPath(valueForAttribute: (String) -> Any?) -> String? {
    valueForAttribute(kMDItemPath as String) as? String
}

private func waitForMetadataQueryCompletion(
    _ finished: () -> Bool, timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !finished() {
        let now = Date()
        guard now < deadline else { return false }
        let nextTurn = min(deadline, now.addingTimeInterval(0.01))
        RunLoop.current.run(mode: .default, before: nextTurn)
    }
    return true
}

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
    func icon(forFile path: String) -> NSImage
    func open(_ url: URL) -> Bool
}

/// Native macOS application discovery and behavior behind the core catalog seam.
///
/// Spotlight broadens discovery beyond standard folders, while the fixed roots
/// remain a deterministic fallback for unavailable or incomplete indexes.
public final class NativeApplicationCatalog: ApplicationCatalog {
    private let discover: () -> MetadataDiscovery
    private let fallbackRoots: [URL]
    private let scanRoots: ([URL]) -> [URL]
    private let readMetadata: (URL) -> ApplicationBundleMetadata?
    private let canonicalize: (URL) -> URL
    private let workspace: any NativeApplicationWorkspace

    public convenience init(
        discoveryTimeout: TimeInterval = 1,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let metadataDiscovery = BoundedMetadataQueryDiscovery()
        self.init(
            discover: { metadataDiscovery.discover(timeout: discoveryTimeout) },
            fallbackRoots: Self.applicationRoots(homeDirectory: homeDirectory),
            scanRoots: scanApplicationRoots,
            readMetadata: readApplicationBundleMetadata,
            canonicalize: canonicalApplicationURL,
            workspace: SystemApplicationWorkspace())
    }

    init(
        discover: @escaping () -> MetadataDiscovery,
        fallbackRoots: [URL],
        scanRoots: @escaping ([URL]) -> [URL],
        readMetadata: @escaping (URL) -> ApplicationBundleMetadata?,
        canonicalize: @escaping (URL) -> URL,
        workspace: any NativeApplicationWorkspace
    ) {
        self.discover = discover
        self.fallbackRoots = fallbackRoots
        self.scanRoots = scanRoots
        self.readMetadata = readMetadata
        self.canonicalize = canonicalize
        self.workspace = workspace
    }

    public func applications() -> [ApplicationRecord] {
        let candidates = discover().urls + scanRoots(fallbackRoots)
        var applications: [ApplicationRecord] = []
        var seenPaths: Set<String> = []
        var seenIdentifiers: Set<String> = []

        for candidate in candidates {
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

    /// Loads the Finder icon through the same `NSWorkspace` behavior used by
    /// the existing panel's path-based icon renderer.
    public func icon(for application: ApplicationRecord) -> NSImage {
        workspace.icon(forFile: resolvedURL(for: application).path)
    }

    /// Opens an application through public `NSWorkspace` behavior.
    public func launch(
        _ application: ApplicationRecord
    ) -> Result<Void, ApplicationLaunchFailure> {
        let url = resolvedURL(for: application)
        guard workspace.open(url) else {
            return .failure(
                ApplicationLaunchFailure(
                    command: "open application '\(shellQuoted(url.path))'",
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

    func icon(forFile path: String) -> NSImage { workspace.icon(forFile: path) }
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

private func shellQuoted(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}
