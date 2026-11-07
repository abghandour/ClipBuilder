import Foundation

/// What the beta takes over from the stable app so nothing has to be set up
/// twice. The first launch imports everything; a profile the stable app
/// creates later is imported the first time the beta opens it; a library
/// can be re-imported or promoted from Settings. Libraries are copied with
/// SQLite's online backup (`VACUUM INTO`), which reads a consistent snapshot
/// with the WAL folded in even while the other app has the file open.
nonisolated enum ChannelImport {
    nonisolated struct Report: Equatable, Sendable {
        var settingsImported = false
        var librariesImported: [String] = []
        var defaultsImported = 0
        var failures: [String] = []

        var isEmpty: Bool { !settingsImported && librariesImported.isEmpty && defaultsImported == 0 }

        var summary: String {
            var parts: [String] = []
            if settingsImported { parts.append("settings") }
            if !librariesImported.isEmpty {
                parts.append(librariesImported.count == 1 ? "the \(librariesImported[0]) library"
                             : "\(librariesImported.count) libraries")
            }
            if defaultsImported > 0 { parts.append("window and screen preferences") }
            return parts.isEmpty ? "Nothing to import" : "Imported " + parts.joined(separator: ", ")
        }
    }

    nonisolated struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The beta's first launch: it has no settings file of its own yet.
    static func isFirstLaunch(channel: AppChannel = .current) -> Bool {
        channel == .beta && !FileManager.default.fileExists(atPath: SettingsStore.settingsURL(channel: .beta).path)
    }

    /// Settings, every profile's library and the stable app's user defaults.
    /// Never throws: each part that fails is named in the report and the
    /// app starts with what it got.
    static func importEverything(profiles: [String], defaults: UserDefaults = .standard,
                                 stableDefaults: UserDefaults? = UserDefaults(suiteName: AppChannel.stableBundleID))
        -> Report {
        var report = Report()
        let stableSettings = SettingsStore.settingsURL(channel: .stable)
        let betaSettings = SettingsStore.settingsURL(channel: .beta)
        if FileManager.default.fileExists(atPath: stableSettings.path),
           !FileManager.default.fileExists(atPath: betaSettings.path) {
            do {
                try FileManager.default.createDirectory(at: betaSettings.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: stableSettings, to: betaSettings)
                report.settingsImported = true
            } catch {
                report.failures.append("settings: \(error.localizedDescription)")
            }
        }
        for profile in profiles {
            do {
                if try importLibraryIfMissing(profileName: profile) { report.librariesImported.append(profile) }
            } catch {
                report.failures.append("\(profile) library: \(error.localizedDescription)")
            }
        }
        if let stableDefaults {
            report.defaultsImported = importDefaults(from: stableDefaults, into: defaults)
        }
        return report
    }

    /// Copies the stable library into the beta's file when the beta has none
    /// and the stable app has one. Returns whether a copy was made.
    @discardableResult
    static func importLibraryIfMissing(profileName: String) throws -> Bool {
        let source = SettingsStore.databaseURL(profileName: profileName, channel: .stable)
        let target = SettingsStore.databaseURL(profileName: profileName, channel: .beta)
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: target.path) else { return false }
        try copyLibrary(from: source, to: target)
        return true
    }

    /// Replaces `target` with a snapshot of `source`. The caller has closed
    /// its own connection to `target`; `source` may be open elsewhere.
    static func copyLibrary(from source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let stale = URL(fileURLWithPath: target.path + suffix)
            if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
        }
        let connection = try SQLiteConnection(path: source.path)
        let quoted = target.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute("VACUUM INTO '\(quoted)'")
    }

    /// `PRAGMA user_version` of a library file, nil when there is none.
    static func stamp(of library: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: library.path),
              let connection = try? SQLiteConnection(path: library.path) else { return nil }
        return try? connection.query("PRAGMA user_version").first?.values.first?.intValue
    }

    /// Whether the beta's library may replace the stable one: only once the
    /// stable app has opened a library at the beta file's schema or newer,
    /// which its own library's stamp shows. An older stable app would refuse
    /// the copy (`Database.NewerLibrary`) and the user would have nothing.
    static func promotionBlocker(profileName: String) -> String? {
        let beta = SettingsStore.databaseURL(profileName: profileName, channel: .beta)
        let stable = SettingsStore.databaseURL(profileName: profileName, channel: .stable)
        guard let betaStamp = stamp(of: beta) else { return "The beta has no library for this profile." }
        guard let stableStamp = stamp(of: stable) else { return nil }
        if stableStamp < betaStamp {
            return "Clip Builder has not opened this profile at library version \(betaStamp) yet "
                + "(its library is at \(stableStamp)). Update Clip Builder, open the profile in it once, "
                + "then copy."
        }
        return nil
    }

    /// Keys the stable app has set that this app has not: window frames,
    /// screen choices, dismissed banners. The data folder key is skipped
    /// when it names a folder that no longer passes validation.
    static func importDefaults(from source: UserDefaults, into target: UserDefaults) -> Int {
        guard let domain = source.persistentDomain(forName: AppChannel.stableBundleID) else { return 0 }
        var copied = 0
        for (key, value) in domain where target.object(forKey: key) == nil {
            if key == SettingsStore.dataFolderDefaultsKey, let path = value as? String,
               SettingsStore.dataFolderRejection(forPath: path) != nil { continue }
            target.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
