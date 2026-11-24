import Foundation
import Testing
@testable import Clip_Builder

struct DatabaseGazeTests {
    @Test func roundTripAndReplaceOnlyTheRequestedTile() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        let other = try await temp.seedVideo()
        let spans: [GazeMeter.Span] = [.init(start: 1, end: 2, kind: .down), .init(start: 4, end: 5, kind: .aside)]
        try await temp.database.replaceGazeSpans(videoID: video, tile: 0, personKey: "person", spans: spans, meterVersion: 1)
        try await temp.database.replaceGazeSpans(videoID: video, tile: 1, personKey: nil, spans: [spans[0]], meterVersion: 1)
        try await temp.database.replaceGazeSpans(videoID: other, tile: 0, personKey: nil, spans: spans, meterVersion: 1)
        let rows = try await temp.database.fetchGazeSpans(videoID: video)
        #expect(rows.map(\.tile) == [0, 0, 1])
        #expect(rows.filter { $0.tile == 0 }.map(\.span) == spans)
        #expect(rows[0].personKey == "person")
        #expect(rows.allSatisfy { $0.videoID == video && $0.meterVersion == 1 })
        let replacement = GazeMeter.Span(start: 8, end: 9, kind: .turned)
        try await temp.database.replaceGazeSpans(videoID: video, tile: 0, personKey: "new", spans: [replacement], meterVersion: 2)
        let after = try await temp.database.fetchGazeSpans(videoID: video)
        #expect(after.count == 2)
        #expect(after[0].span == replacement && after[0].personKey == "new" && after[0].meterVersion == 2)
        #expect(after[1].span == spans[0])
        #expect(try await temp.database.fetchGazeSpans(videoID: other).map(\.span) == spans)
    }

    @Test func noneMarkerIsAMeasurementWithoutALocalPass() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        #expect(try await !temp.database.gazeMeasured(videoID: video, meterVersion: 1))
        try await temp.database.replaceGazeSpans(videoID: video, tile: 2, personKey: "speaker", spans: [], meterVersion: 1)
        #expect(try await temp.database.fetchGazeSpans(videoID: video).isEmpty)
        #expect(try await temp.database.gazeMeasured(videoID: video, meterVersion: 1))
        #expect(try await !temp.database.gazeMeasured(videoID: video, meterVersion: 2))
        #expect(try await temp.database.fetchAnalysisPasses().filter { $0.pass == .gaze }.isEmpty)
        let raw = try SQLiteConnection(path: temp.path.path)
        let row = try #require(raw.query("SELECT * FROM gaze_spans").first)
        #expect(row["kind"]?.stringValue == "none")
        #expect(row["start_time"]?.doubleValue == 0 && row["end_time"]?.doubleValue == 0)
        #expect(row["tile"]?.intValue == 2 && row["person_key"]?.stringValue == "speaker")
        try await temp.database.replaceGazeSpans(videoID: video, tile: 2, personKey: nil,
                                                spans: [.init(start: 2, end: 3, kind: .down)], meterVersion: 2)
        #expect(try await !temp.database.gazeMeasured(videoID: video, meterVersion: 1))
        #expect(try await temp.database.gazeMeasured(videoID: video, meterVersion: 2))
        try await temp.database.replaceGazeSpans(videoID: video, tile: 2, personKey: nil, spans: [], meterVersion: 2)
        #expect(try raw.query("SELECT * FROM gaze_spans").count == 1)
    }

    @Test func completeRecordingReplacesOldTilesAndFinishesPass() async throws {
        let temp = try await TempDatabase()
        let video = try await temp.seedVideo()
        try await temp.database.replaceGazeSpans(videoID: video, tile: 7, personKey: nil, spans: [], meterVersion: 0)
        let pass = try await temp.database.startAnalysisPass(videoID: video, pass: .gaze, version: 1)
        try await temp.database.finishGazeMeasurement(pass, tiles: [
            .init(tile: 0, personKey: "one", spans: []),
            .init(tile: 1, personKey: "two", spans: [.init(start: 1, end: 2, kind: .aside)])
        ])
        #expect(try await !temp.database.gazeMeasured(videoID: video, meterVersion: 0))
        #expect(try await temp.database.gazeMeasured(videoID: video, meterVersion: GazeMeter.meterVersion))
        #expect(try await temp.database.fetchAnalysisPasses().last?.status == .completed)
        let raw = try SQLiteConnection(path: temp.path.path)
        #expect(try raw.query("SELECT tile FROM gaze_spans ORDER BY tile").compactMap { $0["tile"]?.intValue } == [0, 1])
    }

    @Test func syncColumnsAndUpgradeFromPreviousSchema() async throws {
        let temp = try await TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        let table = try SyncTable.named("gaze_spans")
        #expect(try raw.columnNames(of: table.name) == Set(table.columns + ["id", "sync_id"]))
        #expect(table.naturalKey == ["video_id", "tile", "start_time", "kind"])
        #expect(table.references == ["video_id": "videos"])
        #expect(!SyncTable.all.contains { $0.name == "analysis_passes" })
        try raw.execute("DROP TABLE gaze_spans")
        try raw.execute("PRAGMA user_version = 52")
        let path = temp.path
        let upgraded = try await Task.detached { try Database(path: path) }.value
        #expect(try await !upgraded.gazeMeasured(videoID: 1, meterVersion: 1))
        #expect(try raw.columnNames(of: table.name) == Set(table.columns + ["id", "sync_id"]))
        #expect(try raw.query("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'gaze_spans_sync_%'").count == 4)
        #expect(try raw.query("PRAGMA user_version").first?.values.first?.intValue == Database.schemaVersion)
    }
}
