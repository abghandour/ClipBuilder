import Foundation
import Testing
@testable import Clip_Builder

struct SyncVoiceProfileTests {
    private static let table = "voice_profiles"

    /// Two Macs holding the same file under different local ids, both bound.
    private func pair() async throws -> (first: TempDatabase, second: TempDatabase, a: Int64, b: Int64, scope: SyncScope) {
        let first = try await TempDatabase(), second = try await TempDatabase()
        let a = try await first.seedVideo()
        _ = try await second.seedVideo()
        let b = try await second.seedVideo()
        try SQLiteConnection(path: first.path.path).execute("UPDATE videos SET hash = 'shared-video' WHERE id = ?", [.integer(a)])
        try SQLiteConnection(path: second.path.path).execute("UPDATE videos SET hash = 'shared-video' WHERE id = ?", [.integer(b)])
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        return (first, second, a, b, scope)
    }

    private func profile(_ key: String, video: Int64, vector: [Double], windows: Int = 12) -> VoiceProfile {
        VoiceProfile(personKey: key, videoID: video, vector: vector, windows: windows, correctionWindows: 2)
    }

    /// Sends everything the first Mac has queued for the table to the second.
    @discardableResult
    private func deliver(from: TempDatabase, to: TempDatabase, scope: SyncScope) async throws -> [SyncPendingChange] {
        let table = try SyncTable.named(Self.table)
        let changes = try await from.database.pendingSyncChanges(scope: scope, limit: 50, table: table)
        try await from.database.acknowledgeSyncChanges(changes)
        _ = try await to.database.applySyncRows(changes.map(\.wire), scope: scope, table: table, advanceCursor: false)
        return changes
    }

    @Test func projectionMatchesTheLocalTable() async throws {
        let temp = try await TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        let table = try SyncTable.named(Self.table)
        #expect(SyncTable.footage.contains { $0.name == Self.table })
        #expect(table.references == ["video_id": "videos"])
        #expect(table.naturalKey == ["person_key", "video_id"])
        #expect(table.integers == ["video_id", "windows", "correction_windows"])
        #expect(try raw.columnNames(of: Self.table).isSuperset(of: Set(table.columns + ["sync_id"])))
        // A profile must arrive after the video it belongs to.
        let names = SyncTable.all.map(\.name)
        #expect(try #require(names.firstIndex(of: "videos")) < #require(names.firstIndex(of: Self.table)))
    }

    @Test func aTeammateRemembersTheVoiceAndFollowsReplacementAndRemoval() async throws {
        let (first, second, a, b, scope) = try await pair()
        let vector = (0..<192).map { Double($0) / 191 - 0.123456789012345 }
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil,
            profiles: [profile("host", video: a, vector: vector), profile("guest", video: a, vector: [0, 1])])
        let sent = try await deliver(from: first, to: second, scope: scope)
        #expect(sent.count == 2)
        let arrived = try await second.database.fetchVoiceProfiles()
        let host = try #require(arrived.first { $0.personKey == "host" })
        #expect(host.videoID == b && host.windows == 12 && host.correctionWindows == 2)
        #expect(host.vector.count == vector.count)
        #expect(zip(host.vector, vector).allSatisfy { abs($0 - $1) < 1e-12 })
        // A pulled profile is never echoed back.
        #expect(try await second.database.pendingSyncChanges(scope: scope, limit: 50, table: SyncTable.named(Self.table)).isEmpty)

        // A re-map keeps the host's row identity and retires the guest's.
        let hostID = try #require(sent.first { $0.wire["person_key"]?.string == "host" }?.syncID)
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil,
            profiles: [profile("host", video: a, vector: [1, 0], windows: 30)])
        let second_ = try await deliver(from: first, to: second, scope: scope)
        #expect(second_.count == 2)
        #expect(second_.first { !SyncMapping.isDeleted($0.wire) }?.syncID == hostID)
        let after = try await second.database.fetchVoiceProfiles()
        #expect(after.map(\.personKey) == ["host"])
        #expect(after.first?.vector == [1, 0] && after.first?.windows == 30)

        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [])
        let removal = try await deliver(from: first, to: second, scope: scope)
        #expect(removal.count == 1 && SyncMapping.isDeleted(removal[0].wire))
        #expect(try await second.database.fetchVoiceProfiles().isEmpty)
    }

    @Test func bothMacsLearningTheSameVoiceShareOneRow() async throws {
        let (first, second, a, b, scope) = try await pair()
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [profile("host", video: a, vector: [1, 0])])
        try await second.database.replaceVoiceProfiles(videoID: b, transcriptionKey: nil, profiles: [profile("host", video: b, vector: [0, 1])])
        let table = try SyncTable.named(Self.table)
        let fromFirst = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        _ = try await second.database.applySyncRows(fromFirst.map(\.wire), scope: scope, table: table, advanceCursor: false)
        // The second Mac's unsent edit survives, now under the shared identity.
        let pending = try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        #expect(pending.map(\.syncID) == fromFirst.map(\.syncID))
        let rows = try await second.database.fetchVoiceProfiles()
        #expect(rows.count == 1 && rows[0].vector == [0, 1])
    }

    @Test func aTeammatesReassignmentConvergesWithAVoiceLearnedElsewhere() async throws {
        let (first, second, a, b, scope) = try await pair()
        let table = try SyncTable.named(Self.table)
        let source = try await first.database.createPerson(name: "Source Person")
        let target = try await first.database.createPerson(name: "Target Person")
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil,
            profiles: [profile(source.key, video: a, vector: [1, 0])])
        try await deliver(from: first, to: second, scope: scope)
        // The second Mac independently learns the target's voice in this video.
        let rawA = try SQLiteConnection(path: first.path.path), rawB = try SQLiteConnection(path: second.path.path)
        try rawB.execute("INSERT INTO voice_profiles (person_key, video_id, vector_json, windows) VALUES (?, ?, '[0,1]', 5)",
                         [.text(target.key), .integer(b)])
        // The first Mac, which has no target voice, hands the source's voice over.
        try await first.database.reassignPerson(videoID: a, from: source, to: target)
        let fromFirst = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        let fromSecond = try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        #expect(fromFirst.count == 2 && fromFirst.filter { SyncMapping.isDeleted($0.wire) }.count == 1)
        #expect(fromSecond.count == 1)
        // Both Macs name the target's voice in this video with one identity.
        #expect(fromFirst.first { !SyncMapping.isDeleted($0.wire) }?.syncID == fromSecond.first?.syncID)
        // The first Mac pushes first. The second pulls that with its own voice
        // still unsent, which therefore survives and is the last write.
        try await first.database.acknowledgeSyncChanges(fromFirst)
        _ = try await second.database.applySyncRows(fromFirst.map(\.wire), scope: scope, table: table, advanceCursor: false)
        try await second.database.acknowledgeSyncChanges(fromSecond)
        _ = try await first.database.applySyncRows(fromSecond.map(\.wire), scope: scope, table: table, advanceCursor: false)
        let rowsA = try rawA.query("SELECT person_key, sync_id, vector_json FROM voice_profiles WHERE video_id = ?", [.integer(a)])
        let rowsB = try rawB.query("SELECT person_key, sync_id, vector_json FROM voice_profiles WHERE video_id = ?", [.integer(b)])
        #expect(rowsA.count == 1 && rowsB.count == 1)
        #expect(rowsA.first?["person_key"]?.stringValue == target.key && rowsB.first?["person_key"]?.stringValue == target.key)
        #expect(rowsA.first?["sync_id"]?.stringValue == rowsB.first?["sync_id"]?.stringValue)
        #expect(rowsA.first?["vector_json"]?.stringValue == "[0,1]" && rowsB.first?["vector_json"]?.stringValue == "[0,1]")
        #expect(try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table).isEmpty)
        #expect(try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table).isEmpty)
    }

    @Test("A row renamed in place onto a held key is ignored, also during the join pass", arguments: [false, true])
    func aRenamedIdentityNeverAbortsThePull(joining: Bool) async throws {
        let (first, second, a, b, scope) = try await pair()
        let table = try SyncTable.named(Self.table)
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [profile("source", video: a, vector: [1, 0])])
        try await second.database.replaceVoiceProfiles(videoID: b, transcriptionKey: nil,
            profiles: [profile("source", video: b, vector: [1, 0]), profile("target", video: b, vector: [0, 1])])
        var wire = try #require(try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table).first).wire
        wire["person_key"] = .string("target")
        // The second Mac's rows take their shared identities, as before any push.
        #expect(try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table).count == 2)
        let rawB = try SQLiteConnection(path: second.path.path)
        if !joining { try rawB.execute("DELETE FROM sync_outbox") }
        let boundary = try rawB.query("SELECT COALESCE(MAX(sequence), 0) AS s FROM sync_outbox").first?["s"]?.intValue ?? 0
        _ = try await second.database.applySyncRows([wire], scope: scope, table: table,
                                                    serverWinsThrough: joining ? boundary : nil, advanceCursor: false)
        let rows = try await second.database.fetchVoiceProfiles()
        #expect(rows.map(\.personKey) == ["source", "target"])
        #expect(rows.map(\.vector) == [[1, 0], [0, 1]])
        #expect(try rawB.query("SELECT suspended FROM sync_control WHERE id = 1").first?["suspended"]?.intValue == 0)
    }

    @Test func aVoiceRemovedBeforeItsFirstPushRetiresTheTeammatesCopy() async throws {
        let (first, second, a, b, scope) = try await pair()
        let table = try SyncTable.named(Self.table)
        // Both Macs learn the host's voice; only the second has pushed it.
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [profile("host", video: a, vector: [1, 0])])
        try await second.database.replaceVoiceProfiles(videoID: b, transcriptionKey: nil, profiles: [profile("host", video: b, vector: [0, 1])])
        let shared = try #require(try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table).first)
        try await second.database.acknowledgeSyncChanges([shared])
        // The first Mac corrects the map before it ever syncs the voice.
        let rawA = try SQLiteConnection(path: first.path.path)
        #expect(try rawA.query("SELECT sync_id FROM voice_profiles").first?["sync_id"]?.stringValue != shared.syncID)
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [])
        let removal = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        #expect(removal.count == 1)
        #expect(removal.first?.syncID == shared.syncID)
        #expect(removal.first.map { SyncMapping.isDeleted($0.wire) } == true)
        _ = try await second.database.applySyncRows(removal.map(\.wire), scope: scope, table: table, advanceCursor: false)
        #expect(try await second.database.fetchVoiceProfiles().isEmpty)
    }

    @Test func aVoiceRemovedBeforeItsVideoWasEverPushedStillNamesTheSharedRow() async throws {
        // Unlike pair(), neither Mac's video has its shared identity yet.
        let first = try await TempDatabase(), second = try await TempDatabase()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        let a = try await first.seedVideo()
        _ = try await second.seedVideo()
        let b = try await second.seedVideo()
        try SQLiteConnection(path: first.path.path).execute("UPDATE videos SET hash = 'offline-video' WHERE id = ?", [.integer(a)])
        try SQLiteConnection(path: second.path.path).execute("UPDATE videos SET hash = 'offline-video' WHERE id = ?", [.integer(b)])
        let table = try SyncTable.named(Self.table)
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [profile("host", video: a, vector: [1, 0])])
        try await first.database.replaceVoiceProfiles(videoID: a, transcriptionKey: nil, profiles: [])
        try await second.database.replaceVoiceProfiles(videoID: b, transcriptionKey: nil, profiles: [profile("host", video: b, vector: [0, 1])])
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        let shared = try #require(try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table).first)
        let removal = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
        #expect(removal.count == 1)
        #expect(removal.first?.syncID == shared.syncID)
        #expect(removal.first.map { SyncMapping.isDeleted($0.wire) } == true)
    }

    @Test func version49SeedsProfilesOfAnAlreadyBoundProfile() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        try await temp.database.replaceVoiceProfiles(videoID: id, transcriptionKey: nil, profiles: [profile("host", video: id, vector: [1, 0])])
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        for suffix in ["identity", "insert", "update", "delete"] {
            try raw.execute("DROP TRIGGER voice_profiles_sync_\(suffix)")
        }
        try raw.execute("DROP INDEX voice_profiles_sync_id")
        try raw.execute("ALTER TABLE voice_profiles DROP COLUMN sync_id")
        try raw.execute("DELETE FROM sync_outbox WHERE \"table\" = 'voice_profiles'")
        // An unsent edit elsewhere must stay an ordinary local-wins edit.
        try raw.execute("INSERT INTO moments (video_id, at_time, note) VALUES (?, 1, 'Noted offline')", [.integer(id)])
        let unsent = try raw.query("SELECT COUNT(*) AS n FROM sync_outbox").first?["n"]?.intValue
        let bootstrap = try raw.query("SELECT complete FROM sync_bootstrap WHERE id = 1").first?["complete"]?.intValue
        let boundary = try raw.query("SELECT COUNT(*) AS n FROM sync_join_boundary").first?["n"]?.intValue
        try raw.execute("PRAGMA user_version = 49")
        let path = temp.path
        let upgraded = try await Task.detached { try Database(path: path) }.value
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        // The upgrade queues the profiles without reopening the join pass,
        // which would let the server win over unsent edits in every table.
        #expect(try raw.query("SELECT 1 FROM sync_seed_progress WHERE \"table\" = 'voice_profiles'").isEmpty)
        #expect(try raw.query("SELECT complete FROM sync_bootstrap WHERE id = 1").first?["complete"]?.intValue == bootstrap)
        #expect(try raw.query("SELECT COUNT(*) AS n FROM sync_join_boundary").first?["n"]?.intValue == boundary)
        #expect(try raw.query("SELECT COUNT(*) AS n FROM sync_outbox").first?["n"]?.intValue == (unsent ?? -1) + 1)
        try await upgraded.bindSync(to: scope)
        let changes = try await upgraded.pendingSyncChanges(scope: scope, limit: 10, table: SyncTable.named(Self.table))
        #expect(changes.count == 1)
        #expect(changes.first?.wire["person_key"]?.string == "host")
    }
}
