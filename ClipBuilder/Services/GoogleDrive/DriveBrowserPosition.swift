import Foundation

/// Where the Drive browser was last left for a profile: the location menu,
/// the shared drive, and the folder trail. Restored when the browser opens
/// again, falling back to the location's root when the folder is gone.
nonisolated struct DriveBrowserPosition: Codable, Equatable, Sendable {
    var location: String
    var driveID: String?
    var breadcrumbs: [DriveFile]

    static func key(profile: String) -> String { "googleDrive.lastPosition.\(profile)" }

    static func load(profile: String, defaults: UserDefaults = .standard) -> DriveBrowserPosition? {
        guard let data = defaults.data(forKey: key(profile: profile)),
              let position = try? JSONDecoder().decode(DriveBrowserPosition.self, from: data) else { return nil }
        return position
    }

    func save(profile: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(profile: profile))
    }

    /// A trail of folders from the location's root; "Shared drives" starts at
    /// the drive itself, so an empty trail there is not worth restoring.
    var isWorthRestoring: Bool { !breadcrumbs.isEmpty || location != "My Drive" && location != "Shared drives" }
}
