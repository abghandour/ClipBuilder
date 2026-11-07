import AppKit
import Foundation

// MARK: - Stable and beta channels (docs/Stable-Beta-Channels-Plan.md)

extension AppStore {
    /// The beta's first launch: take over settings, every profile's library
    /// and the stable app's user defaults, before the store reads any of
    /// them. Returns the report for the one-time notice, nil otherwise.
    nonisolated static func importFromStableIfFirstLaunch() -> ChannelImport.Report? {
        guard ChannelImport.isFirstLaunch(), !BugReporting.isTestHost else { return nil }
        let profiles = ProfileStore.listProfiles().map(\.profileName)
        let report = ChannelImport.importEverything(profiles: profiles)
        NSLog("Channel import on first launch: %@ (%@)", report.summary, report.failures.joined(separator: "; "))
        return report
    }

    /// The one-time banner after the first-launch import.
    func presentChannelImport(_ report: ChannelImport.Report) {
        let source = Self.stableAppVersion.map { "Clip Builder \($0)" } ?? "Clip Builder"
        var message = report.isEmpty ? "Nothing to import from \(source)." : "\(report.summary) from \(source)."
        if !report.failures.isEmpty {
            message += "\n\nNot imported: " + report.failures.joined(separator: "; ")
        }
        presentNotice("Welcome to Clip Builder Beta", message)
    }

    /// A profile the stable app created after the first launch has no beta
    /// library yet: import it before opening.
    func importLibraryBeforeOpening(profileName: String) {
        guard AppChannel.current == .beta else { return }
        do {
            if try ChannelImport.importLibraryIfMissing(profileName: profileName) {
                recordUnifiedLog(channel: "app", text: "Imported the \(profileName) library from Clip Builder")
            }
        } catch {
            presentError("Could not import the \(profileName) library from Clip Builder", error)
        }
    }

    /// Settings › General › Channel: start this profile over from the stable
    /// app's library. The beta's own file is replaced; nothing in the stable
    /// app changes.
    func replaceLibraryWithStable() {
        let name = activeProfile.profileName
        let source = SettingsStore.databaseURL(profileName: name, channel: .stable)
        guard FileManager.default.fileExists(atPath: source.path) else {
            presentError("Clip Builder has no library for \(name).")
            return
        }
        flushPendingProfileSave()
        builder.flushPendingAutosave()
        database = nil
        do {
            try ChannelImport.copyLibrary(from: source, to: SettingsStore.databaseURL(profileName: name, channel: .beta))
            presentNotice("Library replaced", "\(name) now matches the Clip Builder library.")
        } catch {
            presentError("Could not copy the \(name) library from Clip Builder", error)
        }
        openActiveProfile()
    }

    /// Settings › General › Channel: make the stable app use this profile's
    /// beta library. Refused while the stable app runs (SQLite files must
    /// not change under an open connection) or until the stable app can
    /// read the beta file's schema; the stable file is backed up first.
    func promoteLibraryToStable() {
        let name = activeProfile.profileName
        if let blocker = ChannelImport.promotionBlocker(profileName: name) {
            presentError(blocker)
            return
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: AppChannel.stableBundleID).isEmpty {
            presentError("Quit Clip Builder first, then copy the library.")
            return
        }
        flushPendingProfileSave()
        builder.flushPendingAutosave()
        let stable = SettingsStore.databaseURL(profileName: name, channel: .stable)
        let beta = SettingsStore.databaseURL(profileName: name, channel: .beta)
        do {
            if FileManager.default.fileExists(atPath: stable.path),
               let folder = Database.defaultBackupFolder(for: stable) {
                let backup = folder.appendingPathComponent(Database.backupName(for: stable, reason: "before-promotion"))
                try ChannelImport.copyLibrary(from: stable, to: backup)
            }
            try ChannelImport.copyLibrary(from: beta, to: stable)
            presentNotice("Library copied", "Clip Builder will open \(name) with this library. "
                          + "The previous one is in data/db-backups.")
        } catch {
            presentError("Could not copy the \(name) library to Clip Builder", error)
        }
    }

    /// The installed stable app's version, for the import notice.
    nonisolated static var stableAppVersion: String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppChannel.stableBundleID),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    nonisolated static var versionAndBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
