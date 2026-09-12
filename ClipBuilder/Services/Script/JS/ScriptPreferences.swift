import Foundation

/// Small profile-scoped cache. The current header/capture remains authoritative.
@MainActor
struct ScriptPreferences {
    private let defaults: UserDefaults

    nonisolated init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func examplesInstalled(profile: String) -> Bool {
        defaults.bool(forKey: key(profile) + ".examplesInstalled")
    }

    func markExamplesInstalled(profile: String) {
        defaults.set(true, forKey: key(profile) + ".examplesInstalled")
    }

    func parameters(id: UUID, profile: String) -> Data? {
        let data = (defaults.dictionary(forKey: key(profile) + ".params") ?? [:])[id.uuidString] as? Data
        guard let data, data.count <= 64 * 1024 else { return nil }
        return data
    }

    func saveParameters(_ data: Data, id: UUID, profile: String) throws {
        guard data.count <= 64 * 1024,
              case .object = try ScriptStrictJSON.decode(data) else {
            throw ScriptError.invalid("Expected script parameter JSON of at most 64 KiB.")
        }
        var values = defaults.dictionary(forKey: key(profile) + ".params") ?? [:]
        values[id.uuidString] = data
        defaults.set(values, forKey: key(profile) + ".params")
    }

    func removeParameters(id: UUID, profile: String) {
        var values = defaults.dictionary(forKey: key(profile) + ".params") ?? [:]
        values.removeValue(forKey: id.uuidString)
        defaults.set(values, forKey: key(profile) + ".params")
    }

    private func key(_ profile: String) -> String {
        "builder.scripts." + Data(profile.utf8).base64EncodedString()
    }
}
