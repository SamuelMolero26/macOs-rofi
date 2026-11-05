// Not Foundation: see HistoryTests.swift.
import Darwin
import Testing

@testable import RofiCore

@Suite final class ApplicationCatalogTests {
    @Test func defaultApplicationDirectoriesKeepCompatibilityOrder() {
        #expect(
            FileSystemApplicationCatalog.applicationDirectories(home: "/Users/example") == [
                "/Applications",
                "/Applications/Utilities",
                "/System/Applications",
                "/System/Applications/Utilities",
                "/Users/example/Applications",
            ])
    }

    @Test func injectedRootRecursesAndAppliesBundleAndSymlinkPolicy() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let root = join(temporaryDirectory, "root")
            let outside = join(temporaryDirectory, "outside")
            try makeDirectory(root)
            try makeDirectory(outside)

            try makeBundle(
                at: join(root, "Outer.app"),
                metadata: [
                    "CFBundleIdentifier": "outer",
                    "CFBundleDisplayName": "Outer Display",
                    "CFBundleName": "Outer Name",
                ])
            try makeBundle(
                at: join(root, "Outer.app/Embedded.app"),
                metadata: ["CFBundleIdentifier": "embedded"])
            try makeBundle(
                at: join(root, "Folder/Nested.app"),
                metadata: [
                    "CFBundleIdentifier": "nested",
                    "CFBundleDisplayName": "Localized Nested",
                    "CFBundleName": "Nested Name",
                ])
            try makeBundle(
                at: join(root, "Folder/NameFallback.app"),
                metadata: [
                    "CFBundleIdentifier": "name-fallback",
                    "CFBundleName": "Name Fallback",
                ])
            try makeBundle(
                at: join(root, ".Hidden.app"),
                metadata: ["CFBundleIdentifier": "hidden"])
            try write("not an application", to: join(root, "readme.txt"))

            let linkedFolderTarget = join(outside, "LinkedFolderTarget")
            try makeBundle(
                at: join(linkedFolderTarget, "Skipped.app"),
                metadata: ["CFBundleIdentifier": "linked-folder-app"])
            try #require(symlink(linkedFolderTarget, join(root, "LinkedFolder")) == 0)

            let linkedBundleTarget = join(outside, "Real.app")
            try makeBundle(
                at: linkedBundleTarget,
                metadata: [
                    "CFBundleIdentifier": "linked-app",
                    "CFBundleDisplayName": "Linked Application",
                ])
            let linkedBundle = join(root, "Linked.app")
            try #require(symlink(linkedBundleTarget, linkedBundle) == 0)

            let applications = FileSystemApplicationCatalog(
                home: "/unused", directories: [root]
            ).applications()
            let byIdentifier = Dictionary(uniqueKeysWithValues: applications.map { ($0.identifier, $0) })

            #expect(Set(byIdentifier.keys) == ["outer", "nested", "name-fallback", "linked-app"])
            #expect(byIdentifier["outer"]?.displayName == "Outer Display")
            #expect(byIdentifier["nested"]?.displayName == "Localized Nested")
            #expect(byIdentifier["name-fallback"]?.displayName == "Name Fallback")
            #expect(byIdentifier["linked-app"]?.bundlePath == linkedBundle)
            #expect(byIdentifier["linked-app"]?.iconPath == linkedBundle)
        }
    }

    @Test func earlierInjectedDirectoryWinsDuplicateIdentifiers() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let first = join(temporaryDirectory, "first")
            let second = join(temporaryDirectory, "second")
            try makeBundle(
                at: join(first, "First.app"),
                metadata: [
                    "CFBundleIdentifier": "duplicate",
                    "CFBundleDisplayName": "First Root",
                ])
            try makeBundle(
                at: join(second, "Second.app"),
                metadata: [
                    "CFBundleIdentifier": "duplicate",
                    "CFBundleDisplayName": "Second Root",
                ])

            let applications = FileSystemApplicationCatalog(
                home: "/unused", directories: [first, second]
            ).applications()

            #expect(applications.count == 1)
            #expect(applications.first?.displayName == "First Root")
            #expect(applications.first?.bundlePath == join(first, "First.app"))
        }
    }

    @Test func systemOpenerMapsSuccessfulRunnerWithoutLaunching() {
        let application = ApplicationRecord(
            identifier: "example", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")
        var receivedPath: String?
        var receivedDirectory: String?

        let result = launchApplicationWithSystemOpener(
            application,
            runner: { path, directory in
                receivedPath = path
                receivedDirectory = directory
                return .terminated(status: 0, standardError: "")
            })

        #expect(receivedPath == application.bundlePath)
        #expect(receivedDirectory?.isEmpty == false)
        if case .failure(let failure) = result {
            Issue.record("expected success, got \(failure)")
        }
    }

    @Test func systemOpenerMapsNonzeroStatusAndStandardErrorWithoutLaunching() {
        let application = ApplicationRecord(
            identifier: "quoted", localizedDisplayName: "Quoted", bundleName: nil,
            bundlePath: "/Applications/O'Brien.app")

        let result = launchApplicationWithSystemOpener(
            application,
            runner: { _, _ in
                .terminated(status: 42, standardError: "  Launch Services refused  \n")
            })

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(
            failure
                == ApplicationLaunchFailure(
                    command: "/usr/bin/open '/Applications/O'\\''Brien.app'",
                    reason: "Launch Services refused"))
    }

    @Test func systemOpenerMapsRunnerFailureWithoutLaunching() {
        let application = ApplicationRecord(
            identifier: "example", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")

        let result = launchApplicationWithSystemOpener(
            application,
            runner: { _, _ in .failed(reason: "spawn denied") })

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(
            failure
                == ApplicationLaunchFailure(
                    command: "/usr/bin/open '/Applications/Example.app'", reason: "spawn denied"))
    }

    @Test func systemOpenerUsesExitStatusWhenStandardErrorIsEmpty() {
        let application = ApplicationRecord(
            identifier: "example", localizedDisplayName: "Example", bundleName: nil,
            bundlePath: "/Applications/Example.app")

        let result = launchApplicationWithSystemOpener(
            application,
            runner: { _, _ in .terminated(status: 7, standardError: " \n") })

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.reason == "exited with status 7")
    }

    private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
        let temporaryRoot = String(cString: try #require(getenv("TMPDIR")))
        let directory = join(
            temporaryRoot, "rofi-application-catalog-\(UInt64.random(in: .min ... .max))")
        try makeDirectory(directory)
        defer { removeRecursively(directory) }
        try body(directory)
    }

    private func makeBundle(at path: String, metadata: [String: String]) throws {
        let contents = join(path, "Contents")
        try makeDirectory(contents)
        let entries = metadata.sorted { $0.key < $1.key }.map {
            "<key>\($0.key)</key><string>\($0.value)</string>"
        }.joined()
        try write(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
                + "<plist version=\"1.0\"><dict>\(entries)</dict></plist>",
            to: join(contents, "Info.plist"))
    }

    private func makeDirectory(_ path: String) throws {
        var current = path.hasPrefix("/") ? "/" : ""
        for component in path.split(separator: "/") {
            current = current == "/" ? current + component : join(current, String(component))
            try #require(mkdir(current, 0o700) == 0 || errno == EEXIST)
        }
    }

    private func write(_ contents: String, to path: String) throws {
        let file = try #require(fopen(path, "w"))
        defer { fclose(file) }
        try #require(fputs(contents, file) >= 0)
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private func removeRecursively(_ path: String) {
        var processID: pid_t = 0
        var arguments = [strdup("rm"), strdup("-rf"), strdup(path), nil]
        defer {
            for case let argument? in arguments { free(argument) }
        }
        let result = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&processID, "/bin/rm", nil, nil, $0.baseAddress, environ)
        }
        if result == 0 { waitpid(processID, nil, 0) }
    }
}
