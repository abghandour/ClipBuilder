import Foundation

/// Which of the two apps this is. Both are built from the same tree; the
/// build configuration sets `ClipBuilderChannel` in Info.plist. Nothing in
/// the app branches on the channel except its name, its marks, the files it
/// owns in the shared data folder, and the releases its updater takes
/// (docs/Stable-Beta-Channels-Plan.md).
nonisolated enum AppChannel: String, Sendable, CaseIterable {
    case stable
    case beta

    static let plistKey = "ClipBuilderChannel"
    static let stableBundleID = "com.mokotti-solutions.clipbuilder"

    /// The running app's channel; a build without the key is stable.
    static let current = AppChannel(plistValue: Bundle.main.object(forInfoDictionaryKey: plistKey) as? String)

    init(plistValue: String?) {
        self = plistValue.flatMap { AppChannel(rawValue: $0.lowercased()) } ?? .stable
    }

    var displayName: String {
        switch self {
        case .stable: "Clip Builder"
        case .beta: "Clip Builder Beta"
        }
    }

    var bundleID: String {
        switch self {
        case .stable: Self.stableBundleID
        case .beta: Self.stableBundleID + ".beta"
        }
    }

    /// `app_settings.json` or `app_settings.beta.json`, beside each other.
    var settingsFileName: String {
        switch self {
        case .stable: "app_settings.json"
        case .beta: "app_settings.beta.json"
        }
    }

    /// `<profile>.db` or `<profile>.beta.db` under `profiles_db`.
    func libraryFileName(profile: String) -> String {
        switch self {
        case .stable: profile + ".db"
        case .beta: profile + ".beta.db"
        }
    }

    /// `ClipBuilder-<version>.pkg` or `ClipBuilder-Beta-<version>.pkg`.
    func pkgName(version: String) -> String {
        switch self {
        case .stable: "ClipBuilder-\(version).pkg"
        case .beta: "ClipBuilder-Beta-\(version).pkg"
        }
    }

    /// Whether a release asset is this channel's installer; each channel
    /// ignores the other's pkg on the same release.
    func isPkgAsset(_ name: String) -> Bool {
        guard name.hasSuffix(".pkg") else { return false }
        let beta = name.hasPrefix("ClipBuilder-Beta-")
        switch self {
        case .stable: return name.hasPrefix("ClipBuilder-") && !beta
        case .beta: return beta
        }
    }

    /// The beta takes every release as it appears; stable only releases the
    /// developer has blessed (GitHub's `latest`, which skips prereleases).
    var takesPrereleases: Bool { self == .beta }

    var other: AppChannel { self == .stable ? .beta : .stable }
}
