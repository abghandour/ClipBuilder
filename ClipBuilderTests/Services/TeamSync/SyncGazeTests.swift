import Foundation
import Testing
@testable import Clip_Builder

struct SyncGazeTests {
    @Test func spansAndNoneReceiptArriveWithoutALocalPass() async throws {
        let first = try await TempDatabase(), second = try await TempDatabase()
        let a = try await first.seedVideo()
        _ = try await second.seedVideo()
        let b = try await second.seedVideo()
        try SQLiteConnection(path: first.path.path).execute("UPDATE videos SET hash = 'gaze-video' WHERE id = ?", [.integer(a)])
        try SQLiteConnection(path: second.path.path).execute("UPDATE videos SET hash = 'gaze-video' WHERE id = ?", [.integer(b)])
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        let table = try SyncTable.named("gaze_spans")
        let span = GazeMeter.Span(start: 2, end: 4, kind: .down)
        try await first.database.replaceGazeSpans(videoID: a, tile: 1, personKey: "guest", spans: [span],
                                                 meterVersion: GazeMeter.meterVersion)
        var changes = try await first.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
        try await first.database.acknowledgeSyncChanges(changes)
        _ = try await second.database.applySyncRows(changes.map(\.wire), scope: scope, table: table, advanceCursor: false)
        let arrived = try await second.database.fetchGazeSpans(videoID: b)
        #expect(arrived.map(\.span) == [span])
        #expect(arrived.first?.tile == 1 && arrived.first?.personKey == "guest")
        #expect(try await second.database.gazeMeasured(videoID: b, meterVersion: GazeMeter.meterVersion))

        try await first.database.replaceGazeSpans(videoID: a, tile: 1, personKey: "guest", spans: [],
                                                 meterVersion: GazeMeter.meterVersion)
        changes = try await first.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
        try await first.database.acknowledgeSyncChanges(changes)
        _ = try await second.database.applySyncRows(changes.map(\.wire), scope: scope, table: table, advanceCursor: false)
        #expect(try await second.database.fetchGazeSpans(videoID: b).isEmpty)
        #expect(try await second.database.gazeMeasured(videoID: b, meterVersion: GazeMeter.meterVersion))
        #expect(try await second.database.fetchAnalysisPasses().filter { $0.pass == .gaze }.isEmpty)
        #expect(try await second.database.pendingSyncChanges(scope: scope, limit: 50, table: table).isEmpty)
    }
}
