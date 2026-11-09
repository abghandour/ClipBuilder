import Foundation
import Testing
@testable import Clip_Builder

struct SyncDubTakeTests {
    private func seed(_ temp: TempDatabase, videoID: Int64) async throws -> DubTake {
        let source = DubTakeSource(videoID: videoID, transcriptionKey: "shared-transcript", rowStart: 0,
            rowEnd: 4, language: "en", text: "Shared speech")
        let settings = ElevenLabsSettings()
        let key = DubTake.key(videoHash: "shared-video", source: source, voice: "elevenlabs:clone", settings: settings)
        let take = DubTake(id: key, source: source, speakerKey: "host", text: source.text, voice: "elevenlabs:clone",
            model: settings.model, settingsHash: DubTake.settingsHash(settings), audioFile: key + ".caf",
            alignment: nil, edited: true, driveFileID: "shared-caf")
        try await temp.database.upsertDubTake(take)
        let line = DubLine(clipUID: UUID(), speakerKey: "guest", voice: take.voice, text: take.text,
            sourceStart: 0, sourceEnd: 4, start: 0, duration: 4, takeSource: source,
            takeID: take.id, plannedText: take.text, plannedSpeaker: "host")
        try await temp.database.rememberDubReview([line])
        return take
    }

    @Test func projectionsFollowTranscriptsAndHaveValidColumnsAndReferences() async throws {
        let temp = try await TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        let names = SyncTable.all.map(\.name)
        let transcripts = try #require(names.firstIndex(of: "transcripts"))
        #expect(Array(names[(transcripts + 1)...(transcripts + 2)]) == ["dub_takes", "dub_speaker_overrides"])
        for name in ["dub_takes", "dub_speaker_overrides"] {
            let table = try SyncTable.named(name)
            #expect(table.references == ["video_id": "videos"])
            #expect(table.integers.contains("video_id"))
            #expect(table.reals == ["row_start", "row_end"])
            #expect(try raw.columnNames(of: name).isSuperset(of: Set(table.columns + ["sync_id"])))
        }
        #expect(try SyncTable.named("dub_takes").naturalKey == ["id"])
        #expect(try SyncTable.named("dub_speaker_overrides").naturalKey ==
            ["video_id", "transcription_key", "row_start", "row_end", "language"])
    }

    @Test func twoMacsConvergeAndVideoRemovalPropagatesTakeAndSpeakerTombstones() async throws {
        let first = try await TempDatabase(), second = try await TempDatabase()
        let a = try await first.seedVideo()
        _ = try await second.seedVideo()
        let b = try await second.seedVideo()
        let rawA = try SQLiteConnection(path: first.path.path), rawB = try SQLiteConnection(path: second.path.path)
        try rawA.execute("UPDATE videos SET hash = 'shared-video' WHERE id = ?", [.integer(a)])
        try rawB.execute("UPDATE videos SET hash = 'shared-video' WHERE id = ?", [.integer(b)])
        let takeA = try await seed(first, videoID: a), takeB = try await seed(second, videoID: b)
        #expect(a != b && takeA.id == takeB.id)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await first.database.bindSync(to: scope)
        try await second.database.bindSync(to: scope)
        try await first.database.canonicalizeSyncIdentities(scope: scope)
        try await second.database.canonicalizeSyncIdentities(scope: scope)
        let folder = await second.database.dubTakesDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent(takeB.audioFile)
        try Data("paid audio".utf8).write(to: audio)
        for name in ["dub_takes", "dub_speaker_overrides"] {
            let table = try SyncTable.named(name)
            let aa = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
            let bb = try await second.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
            let left = try #require(aa.first), right = try #require(bb.first)
            #expect(left.syncID == right.syncID)
            #expect(left.wire["video_id"] == right.wire["video_id"])
            if name == "dub_takes" {
                #expect(left.wire["id"]?.string == takeA.id)
                #expect(left.wire["drive_file_id"]?.string == "shared-caf")
            }
            try await first.database.acknowledgeSyncChanges(aa)
            try await second.database.acknowledgeSyncChanges(bb)
            _ = try await second.database.applySyncRows([left.wire], scope: scope, table: table, advanceCursor: false)
        }
        try await first.database.deleteVideos([a])
        for name in ["dub_takes", "dub_speaker_overrides"] {
            let table = try SyncTable.named(name)
            let changes = try await first.database.pendingSyncChanges(scope: scope, limit: 10, table: table)
            let deleted = try #require(changes.first)
            #expect(SyncMapping.isDeleted(deleted.wire))
            _ = try await second.database.applySyncRows([deleted.wire], scope: scope, table: table, advanceCursor: false)
        }
        #expect(try await second.database.fetchDubTakes(videoID: b).isEmpty)
        #expect(try await second.database.dubSpeakerOverride(takeB.source) == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func version48AddsDriveColumnAndSeedsExistingBoundTakes() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.seedVideo()
        _ = try await seed(temp, videoID: id)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let raw = try SQLiteConnection(path: temp.path.path)
        for table in ["dub_takes", "dub_speaker_overrides"] {
            for suffix in ["identity", "insert", "update", "delete"] {
                try raw.execute("DROP TRIGGER \(table)_sync_\(suffix)")
            }
            try raw.execute("DROP INDEX \(table)_sync_id")
            try raw.execute("ALTER TABLE \(table) DROP COLUMN sync_id")
            try raw.execute("DELETE FROM sync_outbox WHERE \"table\" = ?", [.text(table)])
            try raw.execute("DELETE FROM sync_seed_progress WHERE \"table\" = ?", [.text(table)])
        }
        try raw.execute("ALTER TABLE dub_takes DROP COLUMN drive_file_id")
        try raw.execute("PRAGMA user_version = 48")
        let path = temp.path
        let upgraded = try await Task.detached { try Database(path: path) }.value
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == 49)
        #expect(try raw.columnNames(of: "dub_takes").contains("drive_file_id"))
        #expect(try await upgraded.fetchDubTakes(videoID: id).count == 1)
        for name in ["dub_takes", "dub_speaker_overrides"] {
            #expect(try !raw.query("SELECT 1 FROM sync_seed_progress WHERE \"table\" = ?", [.text(name)]).isEmpty)
        }
        try await upgraded.bindSync(to: scope)
        for name in ["dub_takes", "dub_speaker_overrides"] {
            let changes = try await upgraded.pendingSyncChanges(scope: scope, limit: 10, table: SyncTable.named(name))
            #expect(changes.count == 1)
        }
    }
}
