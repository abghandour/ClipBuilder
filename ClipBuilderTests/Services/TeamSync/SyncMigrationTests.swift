import Foundation
import Testing
@testable import Clip_Builder

struct SyncMigrationTests {
    @Test("Version 23 gains stable unique UUIDs and existing lesson queries keep working")
    func version23() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ClipBuilderSyncMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v23.db")
        let raw = try SQLiteConnection(path: path.path)
        // A real pre-sync lesson schema, not a v24 DB with a lowered stamp.
        try raw.executeScript("""
            CREATE TABLE wizard_lessons (
                id INTEGER PRIMARY KEY, text TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                evidence TEXT NOT NULL DEFAULT '', provider TEXT, model TEXT, learned_id TEXT,
                created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now'))
            );
            INSERT INTO wizard_lessons(id, text, pinned, learned_id) VALUES (7, 'First', 1, 'first'), (42, 'Second', 0, 'second');
            PRAGMA user_version = 23;
            """)
        let migrated = try Database(path: path)
        let rows = try raw.query("SELECT id, sync_id FROM wizard_lessons ORDER BY id")
        let ids = rows.compactMap { $0["sync_id"]?.stringValue }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == 24)
        #expect(try await migrated.fetchLessons().map(\.id) == [7, 42])
        #expect(try await migrated.syncPendingCount() == 0)
        #expect(throws: SQLiteError.self) {
            try raw.execute("INSERT INTO wizard_lessons(text, sync_id) VALUES ('Duplicate', ?)", [.text(ids[0])])
        }
        let newID = try await migrated.addLesson(text: "New", pinned: false, evidence: "Unchanged write API")
        let newSyncID = try #require(try raw.query("SELECT sync_id FROM wizard_lessons WHERE id = ?", [.integer(newID)]).first?["sync_id"]?.stringValue)
        #expect(UUID(uuidString: newSyncID) != nil)
        try await migrated.updateLesson(id: newID, text: "Updated", pinned: true)
        try await migrated.deleteLesson(id: 42)
        let ops = try raw.query("SELECT op FROM sync_outbox WHERE sync_id = ? ORDER BY sequence", [.text(newSyncID)])
        #expect(ops.first?["op"]?.stringValue == "upsert")
        #expect(ops.last?["op"]?.stringValue == "upsert")
        #expect(try raw.query("SELECT op FROM sync_outbox WHERE sync_id = ?", [.text(ids[1])]).first?["op"]?.stringValue == "delete")
        let reopened = try Database(path: path)
        #expect(try await reopened.fetchLessons().map(\.text) == ["First", "Updated"])
        #expect(try raw.query("SELECT sync_id FROM wizard_lessons WHERE id = 7").first?["sync_id"]?.stringValue == ids[0])
        #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
    }
}
