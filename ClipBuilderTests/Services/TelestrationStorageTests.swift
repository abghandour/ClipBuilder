import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration storage")
struct TelestrationStorageTests {
    @Test("Insert, update, batch read, delete and video cascade preserve source ownership")
    func roundTripAndDeletion() async throws {
        let temp = try await TempDatabase()
        let first = try await temp.seedVideo(), second = try await temp.seedVideo()
        var record = try await temp.database.saveTelestration(.init(videoID: first, drawing: .init(time: 4)))
        let other = try await temp.database.saveTelestration(.init(videoID: second, drawing: .init(time: 2)))
        #expect(record.id > 0 && record.updatedAt > 0)
        #expect(try await temp.database.fetchTelestrations(videoID: first) == [record])
        let id = record.id
        record.drawing.time = 7
        record.drawing.stay = 8
        record = try await temp.database.saveTelestration(record)
        #expect(record.id == id)
        let earlier = try await temp.database.saveTelestration(.init(videoID: first, drawing: .init(time: 1)))
        let rows = try await temp.database.fetchTelestrations(videoIDs: [first, second, first])
        #expect(rows[first] == [earlier, record] && rows[second] == [other])
        #expect(try await temp.database.fetchTelestrations(videoIDs: []).isEmpty)
        let raw = try SQLiteConnection(path: temp.path.path)
        #expect(try raw.query("SELECT at_time FROM telestrations WHERE id = ?", [.integer(id)]).first?["at_time"]?.doubleValue == 7)
        try await temp.database.deleteTelestration(id: earlier.id)
        #expect(try await temp.database.fetchTelestrations(videoID: first) == [record])
        try await temp.database.deleteVideos([first])
        #expect(try await temp.database.fetchTelestrations(videoID: first).isEmpty)
        #expect(try await temp.database.fetchTelestrations(videoID: second) == [other])
    }

    @Test("Unreadable JSON is skipped without losing valid rows")
    func unreadableRow() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let saved = try await temp.database.saveTelestration(.init(videoID: videoID, drawing: .init(time: 3)))
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("INSERT INTO telestrations(video_id, at_time, drawing_json, updated_at) VALUES (?, 1, 'broken JSON', 0)", [.integer(videoID)])
        #expect(try await temp.database.fetchTelestrations(videoID: videoID) == [saved])
        #expect(try await temp.database.fetchTelestrations(videoIDs: [videoID])[videoID] == [saved])
    }

    @Test("The table is created when an existing current-version library is opened")
    func existingLibrary() async throws {
        let temp = try await TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("DROP TABLE telestrations")
        let path = temp.path
        let reopened = try await Task.detached { try Database(path: path) }.value
        #expect(try await reopened.fetchTelestrations(videoIDs: [1]).isEmpty)
    }

    @Test("Plan reads key drawings by scene video path and retain them across trims")
    func sourcePathLookup() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let record = try await temp.database.saveTelestration(.init(videoID: videoID, drawing: .init(time: 4)))
        let scene = try #require(try await temp.database.fetchScenes(videoID: videoID).first)
        for bounds in [0.0...8.0, 3.0...6.0, 6.0...8.0] {
            let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: bounds.lowerBound, end: bounds.upperBound)])
            let byPath = try await WizardStrikePauses.drawings(plan: plan, sceneMap: [scene.id: scene], database: temp.database)
            #expect(byPath[scene.videoPath] == [record.drawing])
            let timing = WizardStrikePauses.timing(for: plan.clips[0], contacts: [], seconds: nil,
                drawings: byPath[scene.videoPath] ?? [])
            #expect(timing.pauses.count == (bounds.contains(4) ? 1 : 0))
        }
    }
}
