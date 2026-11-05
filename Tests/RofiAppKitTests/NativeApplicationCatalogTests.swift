import AppKit
import CoreServices
import RofiCore
import Testing

@testable import RofiAppKit

@Suite final class NativeApplicationCatalogTests {
    @Test func metadataDiscoveryCompletesFromNotificationAndReadsPaths() {
        let center = NotificationCenter()
        let query = FakeMetadataQuery(
            center: center,
            paths: ["/Applications/First.app", "/System/Applications/Second.app"],
            postsCompletion: true)
        var observedTimeout: TimeInterval?
        let discovery = BoundedMetadataQueryDiscovery(
            makeQuery: { query }, notificationCenter: center,
            waitForCompletion: { finished, timeout in
                observedTimeout = timeout
                return finished()
            })

        let result = discovery.discover(timeout: 0.75)

        #expect(result.state == .completed)
        #expect(result.urls.map(\.path) == query.paths)
        #expect(observedTimeout == 0.75)
        #expect(query.didStart)
        #expect(query.didDisableUpdates)
        #expect(query.didStop)
    }

    @Test func metadataDiscoveryTimesOutAndReturnsItsPartialPaths() {
        let center = NotificationCenter()
        let query = FakeMetadataQuery(
            center: center, paths: ["/Applications/Partial.app"], postsCompletion: false)
        let discovery = BoundedMetadataQueryDiscovery(
            makeQuery: { query }, notificationCenter: center,
            waitForCompletion: { finished, _ in
                #expect(!finished())
                return false
            })

        let result = discovery.discover(timeout: 0.01)

        #expect(result.state == .timedOut)
        #expect(result.urls.map(\.path) == query.paths)
        #expect(query.didDisableUpdates)
        #expect(query.didStop)
    }

    @Test func metadataDiscoveryReportsStartFailureWithoutReadingResults() {
        let center = NotificationCenter()
        let query = FakeMetadataQuery(
            center: center, paths: ["/Applications/Ignored.app"], postsCompletion: false,
            starts: false)
        var waited = false
        let discovery = BoundedMetadataQueryDiscovery(
            makeQuery: { query }, notificationCenter: center,
            waitForCompletion: { _, _ in
                waited = true
                return true
            })

        let result = discovery.discover(timeout: 1)

        #expect(result == MetadataDiscovery(state: .failed, urls: []))
        #expect(!waited)
        #expect(!query.didDisableUpdates)
        #expect(!query.didStop)
    }

    @Test func metadataResultReadsThePublicPathAttribute() {
        var requestedAttribute: String?

        let path = metadataItemPath { attribute in
            requestedAttribute = attribute
            return "/Applications/Example.app"
        }

        #expect(requestedAttribute == kMDItemPath as String)
        #expect(path == "/Applications/Example.app")
    }

    @Test func catalogMergesFallbackAndDeduplicatesCanonicalPathsAndBundleIdentifiers() {
        let spotlight = URL(fileURLWithPath: "/Spotlight/Primary.app")
        let canonicalAlias = URL(fileURLWithPath: "/Roots/Primary Alias.app")
        let identifierDuplicate = URL(fileURLWithPath: "/Roots/Primary Copy.app")
        let fallbackOnly = URL(fileURLWithPath: "/Roots/Fallback.app")
        let canonicalPrimary = URL(fileURLWithPath: "/Canonical/Primary.app")
        let workspace = FakeWorkspace()
        var scannedRoots: [URL] = []

        let catalog = NativeApplicationCatalog(
            discover: { MetadataDiscovery(state: .completed, urls: [spotlight]) },
            fallbackRoots: [URL(fileURLWithPath: "/Roots")],
            scanRoots: { roots in
                scannedRoots = roots
                return [canonicalAlias, identifierDuplicate, fallbackOnly]
            },
            readMetadata: { url in
                switch url.path {
                case spotlight.path, canonicalAlias.path, identifierDuplicate.path:
                    return ApplicationBundleMetadata(
                        identifier: "com.example.primary", localizedDisplayName: url.lastPathComponent,
                        bundleName: nil)
                case fallbackOnly.path:
                    return ApplicationBundleMetadata(
                        identifier: "com.example.fallback", localizedDisplayName: "Fallback",
                        bundleName: nil)
                default:
                    return nil
                }
            },
            canonicalize: { url in
                if url == spotlight || url == canonicalAlias { return canonicalPrimary }
                return url
            },
            workspace: workspace)

        let applications = catalog.applications()

        #expect(scannedRoots.map(\.path) == ["/Roots"])
        #expect(applications.map(\.identifier) == ["com.example.primary", "com.example.fallback"])
        #expect(applications.map(\.bundlePath) == [canonicalPrimary.path, fallbackOnly.path])
        #expect(applications.first?.displayName == "Primary.app")
    }

    @Test(arguments: [MetadataDiscoveryState.timedOut, .failed])
    func incompleteOrFailedDiscoveryStillUsesFixedRootFallback(state: MetadataDiscoveryState) {
        let partial = URL(fileURLWithPath: "/Spotlight/Partial.app")
        let fallback = URL(fileURLWithPath: "/Applications/Fallback.app")
        let catalog = NativeApplicationCatalog(
            discover: {
                MetadataDiscovery(state: state, urls: state == .timedOut ? [partial] : [])
            },
            fallbackRoots: [URL(fileURLWithPath: "/Applications")],
            scanRoots: { _ in [fallback] },
            readMetadata: { url in
                ApplicationBundleMetadata(
                    identifier: "id:\(url.path)", localizedDisplayName: url.lastPathComponent,
                    bundleName: nil)
            },
            canonicalize: { $0 }, workspace: FakeWorkspace())

        let applications = catalog.applications()

        #expect(
            applications.map(\.bundlePath)
                == (state == .timedOut ? [partial.path, fallback.path] : [fallback.path]))
    }

    @Test func localizedBundleMetadataUsesNativeNamePrecedence() {
        let localized = applicationBundleMetadata(
            bundleIdentifier: "com.example.localized",
            localizedInfo: [
                "CFBundleDisplayName": "Localized Display",
                "CFBundleName": "Localized Name",
            ],
            info: [
                "CFBundleDisplayName": "Raw Display",
                "CFBundleName": "Raw Name",
            ])
        let localizedName = applicationBundleMetadata(
            bundleIdentifier: nil, localizedInfo: ["CFBundleName": "Localized Name"],
            info: ["CFBundleDisplayName": "Raw Display"])
        let rawDisplay = applicationBundleMetadata(
            bundleIdentifier: nil, localizedInfo: nil,
            info: ["CFBundleDisplayName": "Raw Display", "CFBundleName": "Raw Name"])
        let rawName = applicationBundleMetadata(
            bundleIdentifier: nil, localizedInfo: [:], info: ["CFBundleName": "Raw Name"])

        #expect(localized.identifier == "com.example.localized")
        #expect(localized.localizedDisplayName == "Localized Display")
        #expect(localized.bundleName == "Raw Display")
        #expect(localizedName.localizedDisplayName == "Localized Name")
        #expect(localizedName.bundleName == "Raw Display")
        #expect(rawDisplay.localizedDisplayName == nil)
        #expect(rawDisplay.bundleName == "Raw Display")
        #expect(rawName.bundleName == "Raw Name")
    }

    @Test func workspaceResolutionSuppliesCanonicalRecordAndExistingIconPath() {
        let discovered = URL(fileURLWithPath: "/Volumes/Other/Example.app")
        let resolved = URL(fileURLWithPath: "/Applications/Example.app")
        let workspace = FakeWorkspace()
        workspace.resolvedApplications["com.example.app"] = resolved
        let catalog = makeCatalog(
            urls: [discovered],
            metadata: [
                discovered.path: ApplicationBundleMetadata(
                    identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil)
            ], workspace: workspace)

        let application = catalog.applications().first

        #expect(application?.bundlePath == resolved.path)
        #expect(application?.iconPath == resolved.path)
        #expect(workspace.requestedIdentifiers == ["com.example.app"])
    }

    @Test func iconUsesWorkspaceResolutionWithoutChangingPathBasedRendering() throws {
        let original = URL(fileURLWithPath: "/Volumes/Other/Example.app")
        let resolved = URL(fileURLWithPath: "/Applications/Example.app")
        let workspace = FakeWorkspace()
        workspace.resolvedApplications["com.example.app"] = resolved
        let expectedIcon = NSImage(size: NSSize(width: 24, height: 24))
        workspace.icon = expectedIcon
        let catalog = makeCatalog(urls: [], metadata: [:], workspace: workspace)
        let application = ApplicationRecord(
            identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: original.path)

        let icon = catalog.icon(for: application)

        #expect(icon === expectedIcon)
        #expect(workspace.iconPaths == [resolved.path])
        #expect(application.iconPath == original.path)
    }

    @Test func successfulLaunchUsesResolvedWorkspaceURLWithoutOpeningInTheTest() {
        let original = URL(fileURLWithPath: "/Volumes/Other/Example.app")
        let resolved = URL(fileURLWithPath: "/Applications/Example.app")
        let workspace = FakeWorkspace()
        workspace.resolvedApplications["com.example.app"] = resolved
        workspace.openResult = true
        let catalog = makeCatalog(urls: [], metadata: [:], workspace: workspace)
        let application = ApplicationRecord(
            identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: original.path)

        let result = catalog.launch(application)

        if case .failure(let failure) = result {
            Issue.record("expected success, got \(failure)")
        }
        #expect(workspace.openedURLs == [resolved])
    }

    @Test func failedLaunchMapsWorkspaceRefusalWithoutOpeningInTheTest() {
        let workspace = FakeWorkspace()
        workspace.openResult = false
        let catalog = makeCatalog(urls: [], metadata: [:], workspace: workspace)
        let application = ApplicationRecord(
            identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")

        let result = catalog.launch(application)

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(
            failure
                == ApplicationLaunchFailure(
                    command: "open application '/Applications/Example.app'",
                    reason: "NSWorkspace could not open the application"))
        #expect(workspace.openedURLs.map(\.path) == [application.bundlePath])
    }

    private func makeCatalog(
        urls: [URL], metadata: [String: ApplicationBundleMetadata], workspace: FakeWorkspace
    ) -> NativeApplicationCatalog {
        NativeApplicationCatalog(
            discover: { MetadataDiscovery(state: .completed, urls: urls) }, fallbackRoots: [],
            scanRoots: { _ in [] }, readMetadata: { metadata[$0.path] }, canonicalize: { $0 },
            workspace: workspace)
    }
}

private final class FakeMetadataQuery: ApplicationMetadataQuery {
    let center: NotificationCenter
    let notificationObject: AnyObject = NSObject()
    let paths: [String]
    let postsCompletion: Bool
    let starts: Bool
    var didStart = false
    var didDisableUpdates = false
    var didStop = false

    init(
        center: NotificationCenter, paths: [String], postsCompletion: Bool, starts: Bool = true
    ) {
        self.center = center
        self.paths = paths
        self.postsCompletion = postsCompletion
        self.starts = starts
    }

    func start() -> Bool {
        didStart = true
        if postsCompletion {
            center.post(name: .NSMetadataQueryDidFinishGathering, object: notificationObject)
        }
        return starts
    }

    func disableUpdates() { didDisableUpdates = true }
    func stop() { didStop = true }
    func resultPaths() -> [String] { paths }
}

private final class FakeWorkspace: NativeApplicationWorkspace {
    var resolvedApplications: [String: URL] = [:]
    var requestedIdentifiers: [String] = []
    var icon = NSImage(size: NSSize(width: 16, height: 16))
    var iconPaths: [String] = []
    var openResult = false
    var openedURLs: [URL] = []

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        requestedIdentifiers.append(identifier)
        return resolvedApplications[identifier]
    }

    func icon(forFile path: String) -> NSImage {
        iconPaths.append(path)
        return icon
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResult
    }
}
