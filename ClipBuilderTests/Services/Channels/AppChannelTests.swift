import Foundation
import Testing
@testable import Clip_Builder

struct AppChannelTests {
    @Test func plistValueSelectsTheChannelAndAMissingKeyIsStable() {
        #expect(AppChannel(plistValue: nil) == .stable)
        #expect(AppChannel(plistValue: "stable") == .stable)
        #expect(AppChannel(plistValue: "beta") == .beta)
        #expect(AppChannel(plistValue: "Beta") == .beta)
        #expect(AppChannel(plistValue: "nightly") == .stable)
    }

    @Test func namesFilesAndBundleIDsPerChannel() {
        #expect(AppChannel.stable.displayName == "Clip Builder")
        #expect(AppChannel.beta.displayName == "Clip Builder Beta")
        #expect(AppChannel.beta.bundleID == "com.mokotti-solutions.clipbuilder.beta")
        #expect(AppChannel.stable.settingsFileName == "app_settings.json")
        #expect(AppChannel.beta.settingsFileName == "app_settings.beta.json")
        #expect(AppChannel.stable.libraryFileName(profile: "Peace") == "Peace.db")
        #expect(AppChannel.beta.libraryFileName(profile: "Peace") == "Peace.beta.db")
        #expect(AppChannel.beta.pkgName(version: "1.151") == "ClipBuilder-Beta-1.151.pkg")
    }

    @Test func eachChannelTakesOnlyItsOwnInstaller() {
        #expect(AppChannel.stable.isPkgAsset("ClipBuilder-1.151.pkg"))
        #expect(!AppChannel.stable.isPkgAsset("ClipBuilder-Beta-1.151.pkg"))
        #expect(AppChannel.beta.isPkgAsset("ClipBuilder-Beta-1.151.pkg"))
        #expect(!AppChannel.beta.isPkgAsset("ClipBuilder-1.151.pkg"))
        #expect(!AppChannel.stable.isPkgAsset("ClipBuilder-1.151.dmg"))
    }

    @Test func settingsAndLibrariesSitBesideEachOther() throws {
        let scope = try DataFolderOverride()
        let data = scope.directory.url.appendingPathComponent("data")
        #expect(SettingsStore.settingsURL(channel: .stable).path == data.appendingPathComponent("app_settings.json").path)
        #expect(SettingsStore.settingsURL(channel: .beta).path == data.appendingPathComponent("app_settings.beta.json").path)
        #expect(SettingsStore.databaseURL(profileName: "Peace Grappler", channel: .stable).lastPathComponent == "Peace Grappler.db")
        #expect(SettingsStore.databaseURL(profileName: "Peace Grappler", channel: .beta).lastPathComponent == "Peace Grappler.beta.db")
        #expect(SettingsStore.databaseURL(profileName: "Peace Grappler", channel: .beta).deletingLastPathComponent().path
                == data.appendingPathComponent("profiles_db").path)
    }
}
