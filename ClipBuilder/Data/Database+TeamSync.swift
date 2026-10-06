import Foundation

nonisolated struct SyncPendingChange: Sendable {
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
        for row in try db.query("SELECT id FROM wizard_lessons WHERE sync_id IS NULL") {
            try db.execute("UPDATE wizard_lessons SET sync_id = ? WHERE id = ?",
                           [.text(UUID().uuidString.lowercased()), row["id"] ?? .null])
        }
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
    func bindSync(to scope: SyncScope) throws {
        try connection.transaction {
            if let row = try connection.query("SELECT * FROM sync_binding WHERE id = 1").first {
                guard row["team_id"]?.stringValue == scope.teamID.uuidString,
                      row["profile_id"]?.stringValue == scope.profileID.uuidString else {
                    throw SyncError.scopeMismatch
                }
                return
            }
            try connection.execute("INSERT INTO sync_binding VALUES (1, ?, ?)",
                                   [.text(scope.teamID.uuidString), .text(scope.profileID.uuidString)])
            // First attach includes rows that predate the outbox migration.
            try connection.execute("""
                INSERT INTO sync_outbox("table", sync_id, op)
                SELECT 'wizard_lessons', sync_id, 'upsert' FROM wizard_lessons
                WHERE NOT EXISTS (SELECT 1 FROM sync_outbox
                    WHERE "table" = 'wizard_lessons' AND sync_id = wizard_lessons.sync_id)
                """)
        }
    }

    func pendingSyncChanges(scope: SyncScope, limit: Int) throws -> [SyncPendingChange] {
        try connection.transaction {
            try connection.query("""
                SELECT sync_id, MAX(sequence) AS sequence FROM sync_outbox
                WHERE "table" = 'wizard_lessons' GROUP BY sync_id ORDER BY sequence LIMIT ?
                """, [.integer(Int64(limit))]).map { entry in
                guard let id = entry["sync_id"]?.stringValue, let sequence = entry["sequence"]?.intValue else {
                    throw SyncError.invalidRow("outbox")
                }
                let local = try connection.query("SELECT * FROM wizard_lessons WHERE sync_id = ?", [.text(id)]).first
                let cached = try connection.query("SELECT wire_json FROM sync_wire_rows WHERE \"table\" = ? AND sync_id = ?",
                                                  [.text(SyncMapping.table), .text(id)]).first?["wire_json"]?.stringValue
                let preserved = try cached.map { try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data($0.utf8)) } ?? [:]
                return SyncPendingChange(sequence: sequence, syncID: id,
                    wire: try SyncMapping.wire(local: local, syncID: id, scope: scope, preserved: preserved))
            }
        }
    }

    func acknowledgeSyncChange(_ change: SyncPendingChange) throws {
        // An edit that happened while HTTP was in flight has a larger sequence.
        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND sequence <= ?",
                               [.text(SyncMapping.table), .text(change.syncID), .integer(change.sequence)])
    }

    func syncCursor() throws -> SyncCursor? {
        guard let row = try connection.query("SELECT * FROM sync_cursors WHERE \"table\" = ?", [.text(SyncMapping.table)]).first,
              let timestamp = row["server_updated_at"]?.stringValue, let id = row["sync_id"]?.stringValue else { return nil }
        return SyncCursor(timestamp: timestamp, syncID: id)
    }

    func syncPendingCount() throws -> Int {
        Int(try connection.query("SELECT COUNT(DISTINCT sync_id) AS count FROM sync_outbox WHERE \"table\" = ?",
                                 [.text(SyncMapping.table)]).first?["count"]?.intValue ?? 0)
    }

    /// There are no awaits inside the batch. The write lock also prevents other
    /// SQLite connections from writing while suppression is enabled. Rollback
    /// restores the switch, rows, preserved fields and cursor on any failure.
    func applySyncRows(_ rows: [SyncMapping.WireRow], scope: SyncScope) throws {
        guard !rows.isEmpty else { return }
        try connection.transaction {
            try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
            for wire in rows {
                let id = try SyncMapping.identity(wire, scope: scope)
                let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
                try connection.execute("""
                    INSERT INTO sync_wire_rows("table", sync_id, wire_json) VALUES (?, ?, ?)
                    ON CONFLICT("table", sync_id) DO UPDATE SET wire_json = excluded.wire_json
                    """, [.text(SyncMapping.table), .text(id), .text(json)])
                // A local edit made during a pull must survive until the next
                // push; that push gets a newer server stamp and will be pulled.
                if try !connection.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? LIMIT 1",
                                         [.text(SyncMapping.table), .text(id)]).isEmpty { continue }
                if SyncMapping.isDeleted(wire) {
                    try connection.execute("DELETE FROM wizard_lessons WHERE sync_id = ?", [.text(id)])
                } else {
                    let localID = try connection.query("SELECT id FROM wizard_lessons WHERE sync_id = ?", [.text(id)]).first?["id"]?.intValue
                    let local = try SyncMapping.local(wire: wire, localID: localID, scope: scope)
                    let columns = SyncMapping.columns
                    let assignments = columns.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
                    try connection.execute("""
                        INSERT INTO wizard_lessons(sync_id, \(columns.joined(separator: ", ")))
                        VALUES (?, \(columns.map { _ in "?" }.joined(separator: ", ")))
                        ON CONFLICT(sync_id) DO UPDATE SET \(assignments)
                        """, [.text(id)] + columns.map { local[$0] ?? .null })
                }
            }
            let cursor = try SyncMapping.cursor(rows[rows.count - 1], scope: scope)
            try connection.execute("""
                INSERT INTO sync_cursors("table", server_updated_at, sync_id) VALUES (?, ?, ?)
                ON CONFLICT("table") DO UPDATE SET server_updated_at = excluded.server_updated_at, sync_id = excluded.sync_id
                """, [.text(SyncMapping.table), .text(cursor.timestamp), .text(cursor.syncID)])
            #if DEBUG
            guard try connection.query("PRAGMA foreign_key_check").isEmpty else {
                throw SyncError.invalidRow("foreign keys")
            }
            #endif
            try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
        }
    }
}
