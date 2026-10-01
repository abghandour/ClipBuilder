import Foundation
import Testing
@testable import Clip_Builder

struct CriticBriefKeyTests {
    @Test func stabilityAndInvalidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("reel")
        try Data([1]).write(to: file)
        var row = CriticExemplars.Candidate(id: "generated:1", path: file.path, date: "", duration: 20, percentile: 90)
        var profile = Fixtures.brand()
        let key = try CriticBriefStore.key(pool: [row], profile: profile)
        #expect(try key == CriticBriefStore.key(pool: [row], profile: profile))
        // Non-evidence row metadata is deliberately absent from the key.
        row.date = "2026-09-29"
        #expect(try key == CriticBriefStore.key(pool: [row], profile: profile))
        row.favorite = true
        #expect(try key != CriticBriefStore.key(pool: [row], profile: profile))
        row.favorite = false
        profile.tasteRubric += " changed"
        #expect(try key != CriticBriefStore.key(pool: [row], profile: profile))
        profile = Fixtures.brand()
        profile.houseStyle += " changed"
        #expect(try key != CriticBriefStore.key(pool: [row], profile: profile))
        profile = Fixtures.brand()
        try Data([1, 2]).write(to: file)
        let rewritten = try CriticBriefStore.key(pool: [row], profile: profile)
        #expect(key != rewritten)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        #expect(try rewritten != CriticBriefStore.key(pool: [row], profile: profile))
    }

    @Test func orderingAndCacheRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("reel")
        try Data([1]).write(to: file)
        let a = CriticExemplars.Candidate(id: "a", path: file.path, date: "", duration: 20)
        var b = a; b.id = "b"
        let profile = Fixtures.brand()
        #expect(try CriticBriefStore.key(pool: [a, b], profile: profile) == CriticBriefStore.key(pool: [b, a], profile: profile))
        let store = CriticBriefStore(profile: profile, root: folder)
        let brief = CriticBriefFixtures.brief()
        try store.save(brief)
        #expect(store.load() == brief)
    }
}

extension CriticBriefKeyTests {
    @Test @MainActor func unrelatedDatabaseWritesDoNotInvalidateTheBrief() async throws {
        let temp = try TempDatabase()
        let profile = Fixtures.brand()
        for index in 1...2 {
            let url = temp.directory.url.appendingPathComponent("reel-\(index).mp4")
            try Data([UInt8(index)]).write(to: url)
            let id = try await temp.database.insertGeneratedVideo(path: url.path, duration: 20,
                timelineJSON: "{}", wizardProvider: nil, wizardModel: nil)
            try await temp.database.setGeneratedVideoFavorite(id, favorite: true)
        }
        let before = try await CriticExemplars.select(database: temp.database, profile: profile)
        #expect(before.exemplars.count == 2)
        let key = try CriticBriefStore.key(pool: before.exemplars, profile: profile)
        try await temp.database.setDriveSetting("critic-test-unrelated", value: "changed")
        let after = try await CriticExemplars.select(database: temp.database, profile: profile)
        #expect(try key == CriticBriefStore.key(pool: after.exemplars, profile: profile))
    }
}
