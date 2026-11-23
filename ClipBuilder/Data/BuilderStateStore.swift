import Foundation

/// Persists the in-progress builder timeline per profile — the native
/// equivalent of the web app's localStorage builder state. One JSON file per
/// profile under the data folder (kept out of the shared SQLite schema).
nonisolated enum BuilderStateStore {
    /// A Builder UI preference, per profile; never part of a timeline or export.
    static func liveDubEnabled(profileName: String) -> Bool {
        UserDefaults.standard.object(forKey: "builder.liveDub.\(ProfileStore.sanitize(profileName))") as? Bool ?? true
    }

    static func setLiveDubEnabled(_ enabled: Bool, profileName: String) {
        UserDefaults.standard.set(enabled, forKey: "builder.liveDub.\(ProfileStore.sanitize(profileName))")
    }

    static var directory: URL {
        SettingsStore.dataDirectory.appendingPathComponent("builder_state", isDirectory: true)
    }

    static func url(profileName: String) -> URL {
        directory.appendingPathComponent(ProfileStore.sanitize(profileName) + ".json")
    }

    static func load(profileName: String) -> TimelineDocument? {
        guard let data = try? Data(contentsOf: url(profileName: profileName)) else { return nil }
        return try? JSONDecoder().decode(TimelineDocument.self, from: data)
    }

    static func save(_ document: TimelineDocument, profileName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url(profileName: profileName), options: .atomic)
    }

    static func clear(profileName: String) {
        try? FileManager.default.removeItem(at: url(profileName: profileName))
    }
}
