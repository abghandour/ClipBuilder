import Foundation

nonisolated struct SyncPendingChange: Sendable {
    var table: SyncTable = .lessons
    let sequence: Int64
    let syncID: String
    let wire: SyncMapping.WireRow
}

extension Database {
    /// Separate from the legacy lazy migrations so the v24 backfill, triggers,
    /// and version stamp commit together. SQLite needs a unique index rather
    /// than ALTER TABLE ADD COLUMN ... UNIQUE.
    nonisolated static func migrateTeamSync(_ db: SQLiteConnection) throws {
        if try !db.columnNames(of: "wizard_lessons").contains("sync_id") {
            try db.execute("ALTER TABLE wizard_lessons ADD COLUMN sync_id TEXT")
        }
        try db.execute("""
            UPDATE wizard_lessons SET sync_id = lower(hex(randomblob(4))) || '-' ||
                lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
                substr('89ab', abs(random() % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                lower(hex(randomblob(6))) WHERE sync_id IS NULL
            """)
        try db.executeScript("""
            CREATE UNIQUE INDEX IF NOT EXISTS wizard_lessons_sync_id ON wizard_lessons(sync_id);
            CREATE TABLE IF NOT EXISTS sync_control (
                id INTEGER PRIMARY KEY CHECK (id = 1), suspended INTEGER NOT NULL DEFAULT 0
            );
            INSERT OR IGNORE INTO sync_control(id) VALUES (1);
            CREATE TABLE IF NOT EXISTS sync_outbox (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                "table" TEXT NOT NULL,
                sync_id TEXT NOT NULL,
                op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
                changed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS sync_outbox_identity ON sync_outbox("table", sync_id, sequence);
            CREATE TABLE IF NOT EXISTS sync_binding (
                id INTEGER PRIMARY KEY CHECK (id = 1), team_id TEXT NOT NULL, profile_id TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_cursors (
                "table" TEXT PRIMARY KEY, server_updated_at TEXT NOT NULL, sync_id TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_wire_rows (
                "table" TEXT NOT NULL, sync_id TEXT NOT NULL, wire_json TEXT NOT NULL,
                PRIMARY KEY ("table", sync_id)
            );
            CREATE TRIGGER IF NOT EXISTS wizard_lessons_sync_identity
            BEFORE UPDATE OF sync_id ON wizard_lessons
            WHEN OLD.sync_id IS NOT NULL AND NEW.sync_id IS NOT OLD.sync_id
            BEGIN SELECT RAISE(ABORT, 'sync_id is immutable'); END;
            CREATE TRIGGER IF NOT EXISTS wizard_lessons_sync_insert AFTER INSERT ON wizard_lessons
            BEGIN
                UPDATE wizard_lessons SET sync_id = lower(hex(randomblob(4))) || '-' ||
                    lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
                    substr('89ab', abs(random() % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                    lower(hex(randomblob(6))) WHERE id = NEW.id AND sync_id IS NULL;
                INSERT INTO sync_outbox("table", sync_id, op)
                    SELECT 'wizard_lessons', sync_id, 'upsert' FROM wizard_lessons
                    WHERE id = NEW.id AND (SELECT suspended FROM sync_control WHERE id = 1) = 0;
            END;
            CREATE TRIGGER IF NOT EXISTS wizard_lessons_sync_update AFTER UPDATE ON wizard_lessons
            WHEN OLD.sync_id IS NOT NULL AND (SELECT suspended FROM sync_control WHERE id = 1) = 0
            BEGIN
                INSERT INTO sync_outbox("table", sync_id, op) VALUES ('wizard_lessons', NEW.sync_id, 'upsert');
            END;
            CREATE TRIGGER IF NOT EXISTS wizard_lessons_sync_delete AFTER DELETE ON wizard_lessons
            WHEN (SELECT suspended FROM sync_control WHERE id = 1) = 0
            BEGIN
                INSERT INTO sync_outbox("table", sync_id, op) VALUES ('wizard_lessons', OLD.sync_id, 'delete');
            END;
            """)
    }

    /// Called explicitly by an engine only after its schema gate passes. No
    /// engine is constructed by the app in Phase 0. Bind once to prevent sending
    /// a profile's pending changes or cursor to another team accidentally.
}
