import Foundation
import Testing
@testable import Clip_Builder

/// The feed parsing behind the updater, over fixture JSON: no network.
struct UpdateServiceTests {
    private func release(_ version: String, prerelease: Bool, assets: [String], draft: Bool = false) -> String {
        let list = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"#
        }.joined(separator: ",")
        return #"{"tag_name":"v\#(version)","name":"Clip Builder \#(version)","body":"notes","draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(list)]}"#
    }

    @Test func stableTakesTheBlessedReleaseAndItsOwnPkg() throws {
        let data = Data(release("1.152", prerelease: false,
                                assets: ["ClipBuilder-Beta-1.152.pkg", "ClipBuilder-1.152.pkg"]).utf8)
        let update = try #require(try UpdateService.update(from: data, channel: .stable, currentVersion: "1.150"))
        #expect(update.version == "1.152")
        #expect(update.pkgName == "ClipBuilder-1.152.pkg")
        #expect(try UpdateService.update(from: data, channel: .stable, currentVersion: "1.152") == nil)
        #expect(try UpdateService.update(from: data, channel: .stable, currentVersion: "1.153") == nil)
    }

    @Test func stableRefusesAReleaseWithoutAStablePkg() throws {
        let data = Data(release("1.152", prerelease: false, assets: ["ClipBuilder-Beta-1.152.pkg"]).utf8)
        #expect(throws: UpdateError.self) {
            try UpdateService.update(from: data, channel: .stable, currentVersion: "1.150")
        }
    }

    @Test func betaTakesTheNewestNonDraftReleaseEvenAPrerelease() throws {
        let list = "[" + [
            release("1.154", prerelease: true, assets: ["ClipBuilder-Beta-1.154.pkg"], draft: true),
            release("1.153", prerelease: true, assets: ["ClipBuilder-Beta-1.153.pkg"]),
            release("1.152", prerelease: false, assets: ["ClipBuilder-Beta-1.152.pkg", "ClipBuilder-1.152.pkg"]),
        ].joined(separator: ",") + "]"
        let data = Data(list.utf8)
        let update = try #require(try UpdateService.update(from: data, channel: .beta, currentVersion: "1.152"))
        #expect(update.version == "1.153")
        #expect(update.pkgName == "ClipBuilder-Beta-1.153.pkg")
        #expect(try UpdateService.update(from: data, channel: .beta, currentVersion: "1.153") == nil)
    }

    @Test func betaIgnoresTheStablePkgOnABlessedRelease() throws {
        let data = Data(("[" + release("1.152", prerelease: false, assets: ["ClipBuilder-1.152.pkg"]) + "]").utf8)
        #expect(throws: UpdateError.self) {
            try UpdateService.update(from: data, channel: .beta, currentVersion: "1.150")
        }
    }

    @Test func versionsCompareNumerically() throws {
        let data = Data(release("1.200", prerelease: false, assets: ["ClipBuilder-1.200.pkg"]).utf8)
        #expect(try UpdateService.update(from: data, channel: .stable, currentVersion: "1.99")?.version == "1.200")
    }
}
