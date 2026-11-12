import Foundation
import Testing
@testable import Clip_Builder

/// A Mac with a change waiting must not push its whole older copy of a row
/// over what a teammate changed since (the lost transcript picks and
/// transcript pins of November 12, 2026).
@Suite(.timeLimit(.minutes(2)))
struct SyncMergeTests {
    private func engine(_ folder: SyncTestFolder, _ server: StubSyncServer, _ scope: SyncScope) -> SyncEngine {
        SyncEngine(database: folder.database, client: server.client(), scope: scope, batchSize: 50)
    }

    private func raw(_ folder: SyncTestFolder) throws -> SQLiteConnection {
        try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
    }

    /// The same footage on both Macs, under different local ids and paths.
    private func seedVideo(_ a: SQLiteConnection, _ b: SQLiteConnection) throws {
        try a.execute("INSERT INTO videos(id, hash, filename, path) VALUES (10, 'same-footage', 'Talk.mov', '/private/tmp/mac-a.mov')")
        try b.execute("INSERT INTO videos(id, hash, filename, path) VALUES (90, 'same-footage', 'Talk.mov', '/private/tmp/mac-b.mov')")
    }

    private func pending(_ db: SQLiteConnection, _ table: String) throws -> Int {
        try db.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ?", [.text(table)]).count
    }

    private func value(_ db: SQLiteConnection, _ column: String) throws -> String? {
        try db.query("SELECT \(column) AS v FROM videos").first?["v"]?.stringValue
    }

    @Test("An update that changes no synced column queues nothing; a real change does")
    func unchangedUpdateIsNotQueued() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try raw(a), rawB = try raw(b)
        try seedVideo(rawA, rawB)
        try await engine(a, server, scope).sync()
        #expect(try pending(rawA, "videos") == 0)
        // A local-only column, and a synced column written with the value it has.
        try rawA.execute("UPDATE videos SET path = '/private/tmp/moved.mov'")
        try rawA.execute("UPDATE videos SET filename = filename, active_transcription_key = active_transcription_key")
        #expect(try pending(rawA, "videos") == 0)
        try rawA.execute("UPDATE videos SET video_type = 'podcast'")
        #expect(try pending(rawA, "videos") == 1)
    }

    @Test("A waiting change keeps its own columns and takes the teammate's for the rest")
    func waitingChangeMergesByColumn() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try raw(a), rawB = try raw(b)
        try seedVideo(rawA, rawB)
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        // A pins a transcript; B, not having seen that, changes another column.
        try rawA.execute("UPDATE videos SET active_transcription_key = 'set-a'")
        try await ea.sync()
        try rawB.execute("UPDATE videos SET video_type = 'podcast'")
        try await eb.sync()
        #expect(try value(rawB, "active_transcription_key") == "set-a")
        #expect(try value(rawB, "video_type") == "podcast")
        #expect(try value(rawB, "path") == "/private/tmp/mac-b.mov")
        let row = try #require(await server.allRows(table: "videos").first)
        #expect(row["active_transcription_key"] == .string("set-a"))
        #expect(row["video_type"] == .string("podcast"))
        try await ea.sync()
        #expect(try value(rawA, "active_transcription_key") == "set-a")
        #expect(try value(rawA, "video_type") == "podcast")
        #expect(try pending(rawA, "videos") == 0)
        #expect(try pending(rawB, "videos") == 0)
    }

    @Test("Both Macs changing the same column: the one syncing later keeps its value")
    func sameColumnLastSyncWins() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try raw(a), rawB = try raw(b)
        try seedVideo(rawA, rawB)
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        try rawA.execute("UPDATE videos SET active_transcription_key = 'set-a'")
        try rawB.execute("UPDATE videos SET active_transcription_key = 'set-b'")
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        #expect(try value(rawA, "active_transcription_key") == "set-b")
        #expect(try value(rawB, "active_transcription_key") == "set-b")
    }

    @Test("A teammate's delete beats an edit of the same pick that was still waiting")
    func deleteBeatsWaitingEdit() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try raw(a), rawB = try raw(b)
        try seedVideo(rawA, rawB)
        try rawA.execute("""
            INSERT INTO transcript_picks(video_id, project_id, position, start_time, end_time, original_start, original_end, kept)
            VALUES (10, NULL, 0, 1, 2, 1, 2, 1)
            """)
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        #expect(try rawB.query("SELECT 1 FROM transcript_picks").count == 1)
        try rawA.execute("DELETE FROM transcript_picks")
        try await ea.sync()
        try rawB.execute("UPDATE transcript_picks SET kept = 0")
        #expect(try pending(rawB, "transcript_picks") == 1)
        try await eb.sync()
        #expect(try rawB.query("SELECT 1 FROM transcript_picks").isEmpty)
        #expect(try pending(rawB, "transcript_picks") == 0)
        let picks = await server.allRows(table: "transcript_picks")
        #expect(picks.count == 1)
        #expect(picks.allSatisfy { SyncMapping.isDeleted($0) })
        try await ea.sync()
        #expect(try rawA.query("SELECT 1 FROM transcript_picks").isEmpty)
    }

    @Test("Wire values compare by meaning: reals within rounding, JSON by content")
    func wireValueComparison() {
        #expect(SyncMapping.sameWireValue(.number(Decimal(string: "2374.9")!), .number(Decimal(2374.9)), json: false))
        #expect(!SyncMapping.sameWireValue(.number(1), .number(2), json: false))
        #expect(SyncMapping.sameWireValue(.string(#"{"a":1,"b":2}"#), .string(#"{"b":2,"a":1}"#), json: true))
        #expect(!SyncMapping.sameWireValue(.string(#"{"a":1}"#), .string(#"{"a":2}"#), json: true))
        #expect(!SyncMapping.sameWireValue(.string("a"), .null, json: false))
    }
}
