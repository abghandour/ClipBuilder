import Foundation
import Testing
@testable import Clip_Builder

struct SyncMigrationTests {
    @Test("Binding seeds lessons in local order regardless of UUIDs or identity backfill", arguments: [false, true])
    func bindingQueueOrder(hasLearnedIDs: Bool) async throws {
        let folder = try SyncTestFolder()
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        // Reverse UUID order makes a covering-index scan deterministically
        // disagree with insertion order, even when identities are prefilled.
        for index in 1...5 {
            try raw.execute("""
                INSERT INTO wizard_lessons(text, learned_id, sync_id) VALUES (?, ?, ?)
                """, [.text("Lesson \(index)"), hasLearnedIDs ? .text("learned-\(index)") : .null,
                      .text("00000000-0000-4000-8000-00000000000\(6 - index)")])
        }
        try await folder.database.bindSync(to: scope)
        let queued = try raw.query("""
            SELECT l.text, o.sequence FROM sync_outbox o
            JOIN wizard_lessons l ON l.sync_id = o.sync_id
            WHERE o."table" = 'wizard_lessons' ORDER BY o.sequence
            """)
        let expected = (1...5).map { "Lesson \($0)" }
        #expect(queued.compactMap { $0["text"]?.stringValue } == expected)
        let pending = try await folder.database.pendingSyncChanges(scope: scope, limit: 5)
        #expect(pending.compactMap { $0.wire["text"]?.string } == expected)
        #expect(pending.map(\.sequence) == queued.compactMap { $0["sequence"]?.intValue })
    }

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
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        #expect(try await migrated.fetchLessons().map(\.id) == [7, 42])
        #expect(try await migrated.syncPendingCount() == 0)
        #expect(throws: SQLiteError.self) {
            try raw.execute("INSERT INTO wizard_lessons(text, sync_id) VALUES ('Duplicate', ?)", [.text(ids[0])])
        }
        try await migrated.bindSync(to: SyncScope(teamID: UUID(), profileID: UUID()))
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

extension SyncMigrationTests {
    @Test("Real v24 schema gains every Phase 1 identity and transactional insert/update/delete triggers")
    func version24() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ClipBuilderV25-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v24.db")
        let raw = try SQLiteConnection(path: path.path)
        try raw.executeScript(Database.schema)
        try Database.migrate(raw)
        try Database.migrateTeamSync(raw)
        try BrandSyncFixtures.seed(raw, includeDocument: false)
        try raw.execute("DELETE FROM sync_outbox")
        try raw.execute("PRAGMA user_version = 24")
        let migrated = try Database(path: path)
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        #expect(try await migrated.syncPendingCount() == 0)
        try await migrated.bindSync(to: SyncScope(teamID: UUID(), profileID: UUID()))
        for table in SyncTable.all {
            #expect(try raw.columnNames(of: table.name).contains("sync_id"))
            for row in try raw.query("SELECT sync_id FROM \(table.name)") {
                #expect(row["sync_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
            }
            let triggers = try raw.query("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [.text(table.name)])
            #expect(triggers.count == 4)
            if table.name != "profile_documents" {
                try raw.execute("UPDATE \(table.name) SET \"\(table.columns[0])\" = \"\(table.columns[0])\"")
                #expect(try !raw.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? AND op = 'upsert'", [.text(table.name)]).isEmpty)
            }
        }
        for table in SyncTable.all.reversed() where table.name != "profile_documents" {
            let ids = try raw.query("SELECT sync_id FROM \(table.name)")
            try raw.execute("DELETE FROM \(table.name)")
            for row in ids {
                #expect(try !raw.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND op = 'delete'",
                                      [.text(table.name), row["sync_id"] ?? .null]).isEmpty)
            }
        }
        try raw.execute("DELETE FROM sync_outbox")
        try BrandSyncFixtures.seed(raw)
        for table in SyncTable.all {
            let rows = try raw.query("SELECT sync_id FROM \(table.name)")
            #expect(rows.count == 1)
            #expect(rows.first?["sync_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
            #expect(try !raw.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? AND op = 'upsert'", [.text(table.name)]).isEmpty)
        }
        #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
    }
}

extension SyncMigrationTests {
    @Test("Unattached profiles never queue; binding seeds once and acknowledgements prune bounded changes")
    func outboxRequiresBinding() async throws {
        let folder = try SyncTestFolder()
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        try BrandSyncFixtures.seed(raw)
        for table in SyncTable.all {
            try raw.execute("UPDATE \(table.name) SET \"\(table.columns[0])\" = \"\(table.columns[0])\"")
        }
        #expect(try raw.query("SELECT * FROM sync_outbox").isEmpty)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await folder.database.bindSync(to: scope)
        try await folder.database.bindSync(to: scope)
        #expect(try await folder.database.syncPendingCount() == SyncTable.all.count)
        let old = try await folder.database.pendingSyncChanges(scope: scope, limit: 10)
        for _ in 0..<100 { try raw.execute("UPDATE wizard_lessons SET text = 'Changed'") }
        #expect(try raw.query("SELECT * FROM sync_outbox WHERE \"table\" = 'wizard_lessons'").count == 1)
        try await folder.database.acknowledgeSyncChanges(old)
        #expect(try raw.query("SELECT * FROM sync_outbox WHERE \"table\" = 'wizard_lessons'").count == 1)
        let current = try await folder.database.pendingSyncChanges(scope: scope, limit: 10)
        try await folder.database.acknowledgeSyncChanges(current)
        #expect(try raw.query("SELECT * FROM sync_outbox WHERE \"table\" = 'wizard_lessons'").isEmpty)
        try raw.execute("DELETE FROM sync_binding")
        try raw.execute("DELETE FROM sync_outbox")
        for table in SyncTable.all.reversed() { try raw.execute("DELETE FROM \(table.name)") }
        #expect(try raw.query("SELECT * FROM sync_outbox").isEmpty)
    }
}

extension SyncMigrationTests {
    @Test("Version 25 upgrade removes unattached backlog without changing local identities")
    func version25OutboxRepair() async throws {
        let folder = try SyncTestFolder()
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        let id = try await folder.database.addLesson(text: "Keep me", pinned: true, evidence: "")
        let identity = try #require(try raw.query("SELECT sync_id FROM wizard_lessons WHERE id = ?", [.integer(id)]).first?["sync_id"]?.stringValue)
        try raw.execute("INSERT INTO sync_outbox(\"table\", sync_id, op) VALUES ('wizard_lessons', ?, 'upsert')", [.text(identity)])
        try raw.execute("DROP TABLE sync_bootstrap")
        try raw.execute("PRAGMA user_version = 25")
        let reopened = try Database(path: folder.url.appendingPathComponent("profile.db"))
        #expect(try await reopened.syncPendingCount() == 0)
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        #expect(try raw.query("SELECT sync_id FROM wizard_lessons WHERE id = ?", [.integer(id)]).first?["sync_id"]?.stringValue == identity)
        try await reopened.updateLesson(id: id, text: "Still local", pinned: false)
        #expect(try await reopened.syncPendingCount() == 0)
        try await reopened.bindSync(to: SyncScope(teamID: UUID(), profileID: UUID()))
        #expect(try await reopened.syncPendingCount() == 1)
    }
}

extension SyncMigrationTests {
    @Test("Version 26 upgrade preserves attached cursors and pending edits")
    func version26RecoveryStorage() async throws {
        let folder = try SyncTestFolder()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await folder.database.bindSync(to: scope)
        _ = try await folder.database.addLesson(text: "Pending", pinned: true, evidence: "")
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        try raw.executeScript("""
            UPDATE sync_bootstrap SET complete = 1;
            INSERT INTO sync_cursors VALUES ('wizard_lessons', '2026-10-06T00:00:00Z', '00000000-0000-0000-0000-000000000001');
            DROP TABLE sync_profile_adoption;
            DROP TABLE sync_join_boundary;
            DROP TABLE sync_pending_parents;
            PRAGMA user_version = 26;
            """)
        let cursor = try await folder.database.syncCursor()
        let reopened = try Database(path: folder.url.appendingPathComponent("profile.db"))
        #expect(try await reopened.syncScope() == scope)
        #expect(try await reopened.syncCursor() == cursor)
        #expect(try await reopened.syncPendingCount() == 1)
        // Phase 2 reopens reconciliation for its newly shared tables.
        #expect(try await reopened.initialSyncPending())
        #expect(try raw.query("SELECT * FROM sync_profile_adoption").isEmpty)
        #expect(try raw.query("SELECT * FROM sync_pending_parents").isEmpty)
    }

    @Test("Replacing a profile detaches its database and permits a different team binding")
    func detachForReplacement() async throws {
        let folder = try SyncTestFolder()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await folder.database.bindSync(to: scope)
        _ = try await folder.database.addLesson(text: "Keep local knowledge", pinned: false, evidence: "")
        var profile = BrandProfile(name: "Local")
        profile.teamID = scope.teamID
        profile.profileID = scope.profileID
        try await folder.database.saveSyncProfile(profile)
        try await folder.database.beginSyncProfileAdoption()
        _ = try await folder.database.initialSyncBoundary()
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        try Database.detachSync(raw)
        #expect(try raw.query("PRAGMA busy_timeout").first?["timeout"]?.intValue == 5000)
        #expect(try await folder.database.syncScope() == nil)
        #expect(try await folder.database.syncPendingCount() == 0)
        #expect(try await folder.database.syncedProfileDocument() == nil)
        #expect(try await folder.database.syncProfileAdoption() == nil)
        #expect(try await folder.database.initialSyncPending())
        _ = try await folder.database.addLesson(text: "Detached edit", pinned: false, evidence: "")
        #expect(try await folder.database.syncPendingCount() == 0)
        await #expect(throws: SyncError.scopeMismatch) { try await folder.database.saveSyncProfile(profile) }
        let other = SyncScope(teamID: UUID(), profileID: UUID())
        try await folder.database.bindSync(to: other)
        #expect(try await folder.database.syncScope() == other)
        #expect(try await folder.database.syncPendingCount() == 2)
    }
}

extension SyncMigrationTests {
    @Test("Version 27 preserves local footage and children, permits NULL paths, and seeds attached profiles", arguments: [false, true])
    func version27Footage(attached: Bool) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ClipBuilderV28-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v27.db")
        let raw = try SQLiteConnection(path: path.path)
        // Construct the actual v27 schema: NOT NULL path, no footage sync IDs.
        try raw.executeScript(Database.schema)
        try Database.migrate(raw)
        try Database.migrateTeamSync(raw)
        try Database.migrateBrandSync(raw, tables: SyncTable.all.filter { !SyncTable.footage.contains($0) })
        try raw.executeScript("""
            INSERT INTO videos(id, hash, filename, path, duration, drive_file_id)
                VALUES (42, 'existing-hash', 'Existing.mov', '/private/tmp/existing.mov', 12, 'drive-id');
            INSERT INTO analysis_runs(id, video_id, name) VALUES (17, 42, 'Existing run');
            INSERT INTO scenes(id, video_id, run_id, start_time, end_time) VALUES (9, 42, 17, 0, 12);
            INSERT INTO scene_tags(scene_id, tag) VALUES (9, 'fight');
            INSERT INTO transcripts(video_id, start_time, end_time, text) VALUES (42, 0, 12, 'Keep transcript');
            UPDATE sync_bootstrap SET complete = 1;
            PRAGMA user_version = 27;
            """)
        if attached {
            try raw.execute("INSERT INTO sync_binding VALUES (1, ?, ?)", [.text(UUID().uuidString), .text(UUID().uuidString)])
            try raw.execute("INSERT INTO sync_cursors VALUES ('wizard_lessons', '2026-10-06T00:00:00Z', ?)", [.text(UUID().uuidString)])
        }
        let migrated = try Database(path: path)
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
        #expect(try await migrated.video(id: 42)?.path == "/private/tmp/existing.mov")
        #expect(try await migrated.video(id: 42)?.driveFileID == "drive-id")
        #expect(try await migrated.fetchScenes(videoID: 42).first?.tags == ["fight"])
        #expect(try await migrated.fetchTranscripts(videoID: 42).first?.text == "Keep transcript")
        #expect(try await migrated.fetchAnalysisRuns().first?.id == 17)
        for table in SyncTable.footage {
            #expect(try raw.columnNames(of: table.name).contains("sync_id"))
            for row in try raw.query("SELECT sync_id FROM \(table.name)") {
                #expect(row["sync_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
            }
        }
        #expect(try await migrated.syncPendingCount() == 0)
        if attached {
            #expect(try !raw.query("SELECT 1 FROM sync_seed_progress").isEmpty)
            try await migrated.seedSyncRows()
            #expect(try await migrated.syncPendingCount() == 5)
        }
        #expect(try await migrated.initialSyncPending() == attached)
        if attached { #expect(try await migrated.syncCursor() != nil) }
        try raw.execute("INSERT INTO videos(hash, filename, path) VALUES ('remote-hash', 'Remote.mov', NULL)")
        #expect(try raw.query("SELECT path FROM videos WHERE hash = 'remote-hash'").first?["path"]?.stringValue == nil)
        #expect(throws: SQLiteError.self) {
            try raw.execute("INSERT INTO videos(hash, filename, path) VALUES ('existing-hash', 'Duplicate.mov', NULL)")
        }
        let identities = try raw.query("SELECT sync_id FROM videos ORDER BY id").compactMap { $0["sync_id"]?.stringValue }
        _ = try Database(path: path)
        #expect(try raw.query("SELECT sync_id FROM videos ORDER BY id").compactMap { $0["sync_id"]?.stringValue } == identities)
    }
}
