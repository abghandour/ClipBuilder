import Foundation
import Testing

@testable import Clip_Builder

struct AssetSyncPlannerTests {
    @Test func unionAndConflicts() {
        let base = AssetSyncEntry(size: 3, modifiedDate: Date(timeIntervalSince1970: 100), md5: "aaa")
        var different = base
        different.md5 = "bbb"
        var newer = different
        newer.modifiedDate = Date(timeIntervalSince1970: 200)
        var noChecksum = different
        noChecksum.md5 = nil
        let cases: [(AssetSyncEntry?, AssetSyncEntry?, AssetSyncPlan.Operation)] = [
            (base, nil, .upload), (nil, base, .download), (base, base, .skip),
            (newer, base, .replaceInDrive), (base, newer, .replaceLocal), (base, different, .conflict),
            (base, noChecksum, .skip),
        ]
        for (a, b, expected) in cases {
            let local = a.map { ["music/a.mp3": $0] } ?? [:]
            let remote = b.map { ["music/a.mp3": $0] } ?? [:]
            let actions = AssetSyncPlanner.plan(local: local, remote: remote).actions
            #expect(actions.first(where: { $0.path == "music/a.mp3" })?.operation == expected)
        }
    }

    @Test func parentsBeforeChildrenAndStableOrder() {
        let entries: [String: AssetSyncEntry] = [
            "music": .init(isFolder: true), "music/Album": .init(isFolder: true),
            "music/Album/Disc": .init(isFolder: true), "music/Album/Disc/a.mp3": .init(),
        ]
        for localFirst in [true, false] {
            let actions = AssetSyncPlanner.plan(local: localFirst ? entries : [:], remote: localFirst ? [:] : entries)
                .actions
                .filter { $0.path.hasPrefix("music") }
            let folders = actions.filter { $0.operation == (localFirst ? .createDriveFolder : .createLocalFolder) }.map(
                \.path)
            #expect(folders == ["music", "music/Album", "music/Album/Disc"])
            #expect(actions.last?.path == "music/Album/Disc/a.mp3")
        }
        #expect(
            AssetSyncPlanner.plan(local: entries, remote: [:]).actions
                == AssetSyncPlanner.plan(local: Dictionary(uniqueKeysWithValues: entries.reversed()), remote: [:])
                .actions)
    }

    @Test func ignoredPathsAndFolderCollision() {
        var local: [String: AssetSyncEntry] = [:]
        for path in ["music/.secret.mp3", "music/.import-abc/a.mp3", "music/a.exe", "effects/previews/a.mp4"] {
            local[path] = .init()
        }
        #expect(AssetSyncPlanner.plan(local: local, remote: local).actions.allSatisfy { !$0.path.contains("/") })
        local = ["music/a.mp3": .init(isFolder: true), "music/a.mp3/child.mp3": .init()]
        let actions = AssetSyncPlanner.plan(local: local, remote: ["music/a.mp3": .init()]).actions
        #expect(actions.first(where: { $0.path == "music/a.mp3" })?.operation == .conflict)
        #expect(!actions.contains(where: { $0.path.hasSuffix("child.mp3") }))
    }
}
