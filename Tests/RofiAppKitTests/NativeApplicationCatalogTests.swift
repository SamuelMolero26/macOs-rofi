import AppKit
import RofiCore
import Testing

@testable import RofiAppKit

@Suite final class NativeApplicationCatalogTests {
    @Test func catalogDeduplicatesCanonicalPathsAndBundleIdentifiers() {
        let primary = URL(fileURLWithPath: "/Roots/Primary.app")
        let canonicalAlias = URL(fileURLWithPath: "/Roots/Primary Alias.app")
        let identifierDuplicate = URL(fileURLWithPath: "/Roots/Primary Copy.app")
        let other = URL(fileURLWithPath: "/Roots/Other.app")
        let canonicalPrimary = URL(fileURLWithPath: "/Canonical/Primary.app")
        let workspace = FakeWorkspace()
        var scannedRoots: [URL] = []

        let catalog = NativeApplicationCatalog(
            roots: [URL(fileURLWithPath: "/Roots")],
            scanRoots: { roots in
                scannedRoots = roots
                return [primary, canonicalAlias, identifierDuplicate, other]
            },
            readMetadata: { url in
                switch url.path {
                case primary.path, canonicalAlias.path, identifierDuplicate.path:
                    return ApplicationBundleMetadata(
                        identifier: "com.example.primary", localizedDisplayName: url.lastPathComponent,
                        bundleName: nil)
                case other.path:
                    return ApplicationBundleMetadata(
                        identifier: "com.example.other", localizedDisplayName: "Other",
                        bundleName: nil)
                default:
                    return nil
                }
            },
            canonicalize: { url in
                if url == primary || url == canonicalAlias { return canonicalPrimary }
                return url
            },
            workspace: workspace)

        let applications = catalog.applications()

        #expect(scannedRoots.map(\.path) == ["/Roots"])
        #expect(applications.map(\.identifier) == ["com.example.primary", "com.example.other"])
        #expect(applications.map(\.bundlePath) == [canonicalPrimary.path, other.path])
        #expect(applications.first?.displayName == "Primary.app")
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
        #expect(workspace.requestedIdentifiers == ["com.example.app"])
    }

    @Test func successfulLaunchOpensTheBundleWithoutOpeningInTheTest() {
        let workspace = FakeWorkspace()
        workspace.openResult = true
        let catalog = makeCatalog(urls: [], metadata: [:], workspace: workspace)
        let application = ApplicationRecord(
            identifier: "com.example.app", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")

        let result = catalog.launch(application)

        if case .failure(let failure) = result {
            Issue.record("expected success, got \(failure)")
        }
        #expect(workspace.openedURLs.map(\.path) == [application.bundlePath])
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
            roots: [], scanRoots: { _ in urls }, readMetadata: { metadata[$0.path] }, canonicalize: { $0 },
            workspace: workspace)
    }
}

private final class FakeWorkspace: NativeApplicationWorkspace {
    var resolvedApplications: [String: URL] = [:]
    var requestedIdentifiers: [String] = []
    var openResult = false
    var openedURLs: [URL] = []

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        requestedIdentifiers.append(identifier)
        return resolvedApplications[identifier]
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResult
    }
}
