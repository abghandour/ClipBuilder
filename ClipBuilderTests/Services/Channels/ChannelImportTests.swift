import Foundation
import Testing
@testable import Clip_Builder

/// The beta's take-over of the stable app's files in the shared data folder.
@Suite(.serialized)
struct ChannelImportTests {
    private func seedStableLibrary(_ profile: String, videos: Int = 1) throws -> URL {
        let url = SettingsStore.databaseURL(profileName: profile, channel: .stable)
        let database = try Database(path: url)
        let raw = try SQLiteConnection(path: url.path)
        for index in 0..<videos {
            try raw.execute("INSERT INTO videos (hash, filename, path, duration, width, height) VALUES (?, ?, ?, 10, 1920, 1080)",
                            [.text("hash\(index)"), .text("v\(index).mp4"), .text("/tmp/v\(index).mp4")])
        }
        _ = database
        return url
    }

    @Test func firstLaunchImportsSettingsEveryLibraryAndDefaults() throws {
        let scope = try DataFolderOverride()
        let data = scope.directory.url.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"{"footage":{}}"#.utf8).write(to: SettingsStore.settingsURL(channel: .stable))
        try seedStableLibrary("Peace", videos: 2)
        try seedStableLibrary("Second")
        #expect(ChannelImport.isFirstLaunch(channel: .beta))
        #expect(!ChannelImport.isFirstLaunch(channel: .stable))

        let source = try #require(UserDefaults(suiteName: "ChannelImportTests.source"))
        let target = try #require(UserDefaults(suiteName: "ChannelImportTests.target"))
        defer {
            source.removePersistentDomain(forName: "ChannelImportTests.source")
            target.removePersistentDomain(forName: "ChannelImportTests.target")
        }
        source.setPersistentDomain(["window.frame": "1,2,3,4", "kept": true,
                                    "settings.selectedTab": "team"], forName: AppChannel.stableBundleID)
        target.set("ai", forKey: "settings.selectedTab")

        let report = ChannelImport.importEverything(profiles: ["Peace", "Second", "Missing"],
                                                    defaults: target, stableDefaults: source)
        #expect(report.settingsImported)
        #expect(report.librariesImported == ["Peace", "Second"])
        #expect(report.defaultsImported == 2)
        #expect(report.failures.isEmpty)
        #expect(!ChannelImport.isFirstLaunch(channel: .beta))
        #expect(target.string(forKey: "window.frame") == "1,2,3,4")
        #expect(target.string(forKey: "settings.selectedTab") == "ai", "a value this app set already stays")

        let beta = SettingsStore.databaseURL(profileName: "Peace", channel: .beta)
        let copy = try SQLiteConnection(path: beta.path)
        #expect(try copy.query("SELECT COUNT(*) AS n FROM videos").first?["n"]?.intValue == 2)
        #expect(ChannelImport.stamp(of: beta) == Database.schemaVersion)
        #expect(!FileManager.default.fileExists(atPath: SettingsStore.databaseURL(profileName: "Missing", channel: .beta).path))

        // A second run changes nothing: the beta owns its copies now.
        let again = ChannelImport.importEverything(profiles: ["Peace", "Second"], defaults: target, stableDefaults: source)
        #expect(again.isEmpty)
        #expect(report.summary == "Imported settings, 2 libraries, window and screen preferences")
    }

    @Test func aProfileCreatedLaterImportsWhenFirstOpened() throws {
        _ = try DataFolderOverride()
        #expect(try !ChannelImport.importLibraryIfMissing(profileName: "Later"), "nothing to import yet")
        try seedStableLibrary("Later")
        #expect(try ChannelImport.importLibraryIfMissing(profileName: "Later"))
        #expect(try !ChannelImport.importLibraryIfMissing(profileName: "Later"), "imported once")
    }

    @Test func promotionWaitsForTheStableAppToReachTheBetaSchema() throws {
        _ = try DataFolderOverride()
        #expect(ChannelImport.promotionBlocker(profileName: "Peace") != nil, "no beta library")
        let stable = try seedStableLibrary("Peace")
        try ChannelImport.importLibraryIfMissing(profileName: "Peace")
        #expect(ChannelImport.promotionBlocker(profileName: "Peace") == nil)
        let raw = try SQLiteConnection(path: stable.path)
        try raw.execute("PRAGMA user_version = \(Database.schemaVersion - 1)")
        let blocker = try #require(ChannelImport.promotionBlocker(profileName: "Peace"))
        #expect(blocker.contains("Update Clip Builder"))
    }

    @Test func copyLibraryReplacesTheTargetAndItsSidecars() throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("a.db")
        let target = temp.url.appendingPathComponent("b.db")
        _ = try Database(path: source)
        try Data("stale".utf8).write(to: target)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: target.path + "-wal"))
        try ChannelImport.copyLibrary(from: source, to: target)
        #expect(ChannelImport.stamp(of: target) == Database.schemaVersion)
        #expect(!FileManager.default.fileExists(atPath: target.path + "-wal"))
    }
}
