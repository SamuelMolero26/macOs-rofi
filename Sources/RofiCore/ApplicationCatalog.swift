import Foundation

/// One installed application as the Applications mode understands it.
///
/// The record normalizes identity and presentation once, so modes and native
/// catalog adapters do not need to repeat bundle fallback rules.
public struct ApplicationRecord: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let bundlePath: String

    /// Creates a normalized application record. A localized display name wins
    /// over the bundle name, then the bundle's filename supplies the fallback.
    /// Missing identifiers use the bundle path as a stable local identity.
    public init(identifier: String?, localizedDisplayName: String?, bundleName: String?, bundlePath: String) {
        self.identifier = nonEmptyApplicationValue(identifier) ?? bundlePath
        self.displayName =
            nonEmptyApplicationValue(localizedDisplayName) ?? nonEmptyApplicationValue(bundleName)
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        self.bundlePath = bundlePath
    }
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

private func nonEmptyApplicationValue(_ value: String?) -> String? {
    value?.isEmpty == false ? value : nil
}
