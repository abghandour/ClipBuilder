import Foundation

extension Database {
    nonisolated static func migrateBrandSync(_ db: SQLiteConnection, tables: [SyncTable] = SyncTable.all) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS profile_documents (document_json TEXT NOT NULL, sync_id TEXT)")
        if try !db.columnNames(of: "library_asset_metadata").contains("asset_id") {
            try db.execute("ALTER TABLE library_asset_metadata ADD COLUMN asset_id TEXT")
        }
        try db.execute("CREATE TABLE IF NOT EXISTS sync_bootstrap (id INTEGER PRIMARY KEY CHECK (id = 1), complete INTEGER NOT NULL DEFAULT 0)")
        try db.executeScript("""
            CREATE TABLE IF NOT EXISTS sync_join_boundary (
                id INTEGER PRIMARY KEY CHECK (id = 1), sequence INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_profile_adoption (
                id INTEGER PRIMARY KEY CHECK (id = 1), baseline_json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sync_pending_parents (
                "table" TEXT NOT NULL, sync_id TEXT NOT NULL, wire_json TEXT NOT NULL,
                server_wins_through INTEGER, PRIMARY KEY ("table", sync_id)
            );
            """)
        // An existing v25 binding must also reconcile server data before pushing.
        if try db.query("SELECT 1 FROM sync_bootstrap").isEmpty {
            try db.execute("DELETE FROM sync_cursors")
            try db.execute("INSERT INTO sync_bootstrap(id) VALUES (1)")
        }
        try db.execute("DELETE FROM sync_outbox WHERE NOT EXISTS (SELECT 1 FROM sync_binding)")
        for table in tables {
            let name = table.name
            let portableNew = name == "reel_traits" ? " AND NEW.video_kind IN ('instagram', 'imported', 'external')" : ""
            let portableOld = name == "reel_traits" ? " AND OLD.video_kind IN ('instagram', 'imported', 'external')" : ""
            if try !db.columnNames(of: name).contains("sync_id") {
                try db.execute("ALTER TABLE \(name) ADD COLUMN sync_id TEXT")
            }
            try db.execute("""
                UPDATE \(name) SET sync_id = lower(hex(randomblob(4))) || '-' ||
                    lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
                    substr('89ab', abs(random() % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                    lower(hex(randomblob(6))) WHERE sync_id IS NULL
                """)
            // Only a change to a column that travels queues the row. A write
            // that leaves them as they were (a rescan touching a local path,
            // a save that stores the same value again) would otherwise push
            // this Mac's whole copy over whatever a teammate changed since.
            // A trigger naming a column the table lacks fails every update,
            // so a table still missing one (a later migration adds it) keeps
            // the unguarded trigger until the next migration runs this again.
            // This runs only when the schema version changes: a change here
            // needs a version bump to reach existing libraries (52 did it).
            let present = try db.columnNames(of: name)
            let changed = table.columns.allSatisfy(present.contains)
                ? " AND (" + table.columns.map { "OLD.\"\($0)\" IS NOT NEW.\"\($0)\"" }.joined(separator: " OR ") + ")" : ""
            let runIdentity = name == "analysis_runs" ? "UPDATE analysis_runs SET run_key = lower(hex(randomblob(16))) WHERE rowid = NEW.rowid AND run_key IS NULL;" : ""
            try db.executeScript("""
                CREATE UNIQUE INDEX IF NOT EXISTS \(name)_sync_id ON \(name)(sync_id);
                DROP TRIGGER IF EXISTS \(name)_sync_identity;
                DROP TRIGGER IF EXISTS \(name)_sync_insert;
                DROP TRIGGER IF EXISTS \(name)_sync_update;
                DROP TRIGGER IF EXISTS \(name)_sync_delete;
                CREATE TRIGGER \(name)_sync_identity BEFORE UPDATE OF sync_id ON \(name)
                WHEN OLD.sync_id IS NOT NULL AND NEW.sync_id IS NOT OLD.sync_id
                    AND (SELECT suspended FROM sync_control WHERE id = 1) = 0
                BEGIN SELECT RAISE(ABORT, 'sync_id is immutable'); END;
                CREATE TRIGGER \(name)_sync_insert AFTER INSERT ON \(name)
                BEGIN
                    \(runIdentity)
                    UPDATE \(name) SET sync_id = lower(hex(randomblob(4))) || '-' ||
                        lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
                        substr('89ab', abs(random() % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                        lower(hex(randomblob(6))) WHERE rowid = NEW.rowid AND sync_id IS NULL;
                    INSERT INTO sync_outbox("table", sync_id, op)
                        SELECT '\(name)', sync_id, 'upsert' FROM \(name) WHERE rowid = NEW.rowid
                        AND (SELECT suspended FROM sync_control WHERE id = 1) = 0
                        AND EXISTS (SELECT 1 FROM sync_binding)\(portableNew);
                END;
                CREATE TRIGGER \(name)_sync_update AFTER UPDATE ON \(name)
                WHEN OLD.sync_id IS NOT NULL AND (SELECT suspended FROM sync_control WHERE id = 1) = 0
                    AND EXISTS (SELECT 1 FROM sync_binding)\(portableNew)\(changed)
                BEGIN
                    DELETE FROM sync_outbox WHERE "table" = '\(name)' AND sync_id = NEW.sync_id;
                    INSERT INTO sync_outbox("table", sync_id, op) VALUES ('\(name)', NEW.sync_id, 'upsert');
                END;
                CREATE TRIGGER \(name)_sync_delete AFTER DELETE ON \(name)
                WHEN (SELECT suspended FROM sync_control WHERE id = 1) = 0
                    AND EXISTS (SELECT 1 FROM sync_binding)\(portableOld)
                BEGIN
                    DELETE FROM sync_outbox WHERE "table" = '\(name)' AND sync_id = OLD.sync_id;
                    INSERT INTO sync_outbox("table", sync_id, op) VALUES ('\(name)', OLD.sync_id, 'delete');
                END;
                """)
        }
        try db.execute("DELETE FROM sync_outbox WHERE sequence NOT IN (SELECT MAX(sequence) FROM sync_outbox GROUP BY \"table\", sync_id)")
    }

    func initialSyncPending() throws -> Bool {
        try connection.query("SELECT complete FROM sync_bootstrap WHERE id = 1").first?["complete"]?.intValue != 1
    }

    func completeInitialSync() throws {
        // A downloaded document is not committed until the store has adopted
        // and saved it. Engine-only users without a profile can finish here.
        guard try connection.query("SELECT 1 FROM sync_profile_adoption").isEmpty else { return }
        try connection.execute("UPDATE sync_bootstrap SET complete = 1 WHERE id = 1")
    }

    func initialSyncBoundary() throws -> Int64 {
        // Capture once, not once per retry: edits during a stopped join survive.
        try backfillLessonIdentities()
        try connection.execute("""
            INSERT OR IGNORE INTO sync_join_boundary(id, sequence)
            SELECT 1, COALESCE(MAX(sequence), 0) FROM sync_outbox
            """)
        return try connection.query("SELECT sequence FROM sync_join_boundary WHERE id = 1").first?["sequence"]?.intValue ?? 0
    }

    /// Used by resource replacement on its worker, after writing detached JSON.
    nonisolated static func detachSync(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA busy_timeout=5000")
        try db.transaction {
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.stringValue })
            guard tables.contains("sync_binding") else { return }
            let wasAttached = try !db.query("SELECT 1 FROM sync_binding").isEmpty
            try db.execute("DELETE FROM sync_binding")
            for name in ["sync_outbox", "sync_cursors", "sync_wire_rows", "sync_join_boundary",
                         "sync_profile_adoption", "sync_pending_parents", "profile_documents"] where tables.contains(name) {
                try db.execute("DELETE FROM \(name)")
            }
            if tables.contains("sync_bootstrap") { try db.execute("UPDATE sync_bootstrap SET complete = 0 WHERE id = 1") }
            if wasAttached {
                // Identities belong to the old team. A later attachment seeds
                // fresh IDs and canonicalizes natural keys for the new scope.
                try db.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
                for table in SyncTable.all where tables.contains(table.name) {
                    try db.execute("""
                        UPDATE \(table.name) SET sync_id = lower(hex(randomblob(4))) || '-' ||
                            lower(hex(randomblob(2))) || '-4' || substr(lower(hex(randomblob(2))), 2) || '-' ||
                            substr('89ab', abs(random() % 4) + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                            lower(hex(randomblob(6)))
                        """)
                }
                try db.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            }
        }
    }

    func syncScope() throws -> SyncScope? {
        guard let row = try connection.query("SELECT * FROM sync_binding WHERE id = 1").first,
              let team = row["team_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let profile = row["profile_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
        return SyncScope(teamID: team, profileID: profile)
    }

    func bindSync(to scope: SyncScope) async throws {
        try connection.transaction {
            if let existing = try syncScope() {
                guard existing == scope else { throw SyncError.scopeMismatch }
                return
            }
            try backfillLessonIdentities()
            try connection.execute("INSERT INTO sync_binding VALUES (1, ?, ?)",
                                   [.text(scope.teamID.uuidString), .text(scope.profileID.uuidString)])
            for table in SyncTable.all {
                try connection.execute("INSERT OR IGNORE INTO sync_seed_progress(\"table\", after_rowid) VALUES (?, 0)", [.text(table.name)])
            }
        }
        try await seedSyncRows()
        _ = try initialSyncBoundary()
    }

    /// Run by the app after a cycle, so files downloaded through Drive since
    /// the previous pull acquire their shared descriptions without re-analysis.
    @discardableResult
    func resolveSyncAssets() throws -> Bool {
        var resolved = false
        var pathsByKind: [String: [String: String]] = [:]
        let pending = try connection.query("SELECT asset_id, kind FROM library_asset_metadata WHERE path LIKE 'team-asset:%'")
        for row in pending {
            guard let id = row["asset_id"]?.stringValue, let kind = row["kind"]?.stringValue,
                  let assetKind = AssetKind(rawValue: kind) else { continue }
            if pathsByKind[kind] == nil {
                pathsByKind[kind] = Dictionary(AssetStore.allFiles(of: assetKind).map {
                    (TeamSyncAsset.identity(path: $0.url.path, kind: kind), $0.url.path)
                }, uniquingKeysWith: { first, _ in first })
            }
            guard let path = pathsByKind[kind]?[id] else { continue }
            resolved = true
            try connection.transaction {
                try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
                try connection.execute("UPDATE library_asset_metadata SET path = ? WHERE asset_id = ? AND path LIKE 'team-asset:%'",
                                       [.text(path), .text(id)])
                try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            }
        }
        return resolved
    }

    func syncRowCounts() throws -> [String: Int] {
        try Dictionary(uniqueKeysWithValues: SyncTable.all.map { table in
            (table.name, Int(try connection.query("SELECT COUNT(*) AS n FROM \(table.name)\(syncFilter(table))").first?["n"]?.intValue ?? 0))
        })
    }

    /// Phase 2/3 derived scene/generated caches have local identities; only the
    /// Instagram/external brand reference traits are portable in Phase 1.
    private func syncFilter(_ table: SyncTable) -> String {
        table.name == "reel_traits" ? " WHERE video_kind IN ('instagram', 'imported', 'external')" : ""
    }

    /// Only queued legacy/random identities need work. Stable v5 IDs and all
    /// pulled IDs (including authoritative older random IDs) are left alone.
    /// Dependency order makes offline natural keys deterministic across Macs.
    func canonicalizeSyncIdentities(scope: SyncScope, tables: [SyncTable] = SyncTable.all) async throws {
        // Children push Home's sync_id as their project_id, so Home must carry
        // the shared identity before any of them leaves this Mac.
        if tables.contains(where: { $0.name == "projects" || $0.references.values.contains("projects") }) {
            try connection.transaction {
                try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
                try canonicalizeHomeIdentity(scope: scope)
                try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            }
        }
        for table in tables where !table.naturalKey.isEmpty {
            var after: Int64 = 0
            while true {
                try Task.checkCancellation()
                let rows = try connection.query("""
                    SELECT rowid AS local_rowid, * FROM \(table.name)
                    WHERE rowid > ? AND substr(sync_id, 15, 1) != '5'
                        AND sync_id IN (SELECT sync_id FROM sync_outbox WHERE "table" = ?)
                        AND sync_id NOT IN (SELECT sync_id FROM sync_wire_rows WHERE "table" = ?)
                    ORDER BY rowid LIMIT 500
                    """, [.integer(after), .text(table.name), .text(table.name)])
                guard !rows.isEmpty else { break }
                try connection.transaction {
                    try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
                    for var row in rows {
                        try Task.checkCancellation()
                        try connection.execute("SAVEPOINT sync_identity_row")
                        do {
                            if table.name == "library_asset_metadata", row["asset_id"]?.stringValue == nil {
                                let asset = TeamSyncAsset.identity(path: row["path"]?.stringValue ?? "", kind: row["kind"]?.stringValue ?? "")
                                row["asset_id"] = .text(asset)
                                try connection.execute("UPDATE library_asset_metadata SET asset_id = ? WHERE rowid = ?",
                                                       [.text(asset), row["local_rowid"] ?? .null])
                            }
                            try canonicalizeSyncIdentity(of: row, table: table, scope: scope)
                            try connection.execute("RELEASE sync_identity_row")
                        } catch {
                            try connection.execute("ROLLBACK TO sync_identity_row")
                            try connection.execute("RELEASE sync_identity_row")
                            if error is CancellationError { throw error }
                            NSLog("Team Sync: skipping identity in %@: %@", table.name, error.localizedDescription)
                        }
                    }
                    try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
                }
                after = rows.last?["local_rowid"]?.intValue ?? after
                // Release the database actor between bounded transactions. Stop
                // resumes using the already persisted canonical identities.
                await Task.yield()
            }
        }
    }

    /// Caller holds a transaction with sync_control suspended.
    private func canonicalizeSyncIdentity(of row: SQLRow, table: SyncTable, scope: SyncScope) throws {
        // Home has its own shared identity (canonicalizeHomeIdentity).
        let isHome = table.name == "projects" && row["is_home"]?.intValue == 1
        guard !isHome, isPortableSyncRow(row, table: table), let portable = try portableSyncRow(row, table: table),
              let old = row["sync_id"]?.stringValue else { return }
        var key = table.naturalKey.map { column -> String in
            let value = portable[column]?.stringValue ?? "<null>"
            return column == "username" ? value.lowercased() : value
        }
        // These keys have no local UNIQUE constraint. Preserve
        // each row, including two equal-time events/segments.
        if table.preservesDuplicateKeys { key.append(old) }
        let canonical = SyncMapping.stableID([scope.teamID.uuidString, scope.profileID.uuidString, table.name] + key)
        if old != canonical { try rekeySyncRow(table: table, old: old, new: canonical) }
    }

    /// Deletes voice profiles so the team follows. A voice learned since the
    /// last push still carries a random identity; it takes the shared one for
    /// its (person, video) first, or the deletion would name a row no teammate
    /// has and a copy they learned themselves would come back. Caller holds a
    /// transaction.
    func deleteVoiceProfiles(where predicate: String, _ values: [SQLValue]) throws {
        if let scope = try syncScope() {
            /// Rows of `name` matching `filter` that still wait for a shared identity.
            func unsettled(_ name: String, _ filter: String) throws -> [SQLRow] {
                try connection.query("""
                    SELECT * FROM \(name) WHERE (\(filter)) AND substr(sync_id, 15, 1) != '5'
                        AND sync_id IN (SELECT sync_id FROM sync_outbox WHERE "table" = '\(name)')
                        AND sync_id NOT IN (SELECT sync_id FROM sync_wire_rows WHERE "table" = '\(name)')
                    """, values)
            }
            if try !unsettled("voice_profiles", predicate).isEmpty {
                try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
                // The voice's identity is built on its video's, so a video that
                // has not been pushed either takes its shared identity first.
                let videos = try SyncTable.named("videos"), voices = try SyncTable.named("voice_profiles")
                /// As in canonicalizeSyncIdentities: a row that cannot take
                /// its shared identity is skipped, never a reason to fail
                /// the caller's delete, merge or speaker map.
                func settle(_ row: SQLRow, _ table: SyncTable) throws {
                    try connection.execute("SAVEPOINT voice_identity_row")
                    do {
                        try canonicalizeSyncIdentity(of: row, table: table, scope: scope)
                        try connection.execute("RELEASE voice_identity_row")
                    } catch {
                        try connection.execute("ROLLBACK TO voice_identity_row")
                        try connection.execute("RELEASE voice_identity_row")
                        if error is CancellationError { throw error }
                        NSLog("Team Sync: skipping identity in %@: %@", table.name, error.localizedDescription)
                    }
                }
                for row in try unsettled("videos", "id IN (SELECT video_id FROM voice_profiles WHERE \(predicate))") {
                    try settle(row, videos)
                }
                for row in try unsettled("voice_profiles", predicate) { try settle(row, voices) }
                try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            }
        }
        try connection.execute("DELETE FROM voice_profiles WHERE \(predicate)", values)
    }

    /// Home is one shared project per profile: every Mac's Home carries the
    /// same deterministic sync_id regardless of its name or created_at, so a
    /// pulled Home merges into the local one and children pushed under Home on
    /// one Mac resolve to Home on another.
    nonisolated static func homeSyncID(scope: SyncScope) -> String {
        SyncMapping.stableID([scope.teamID.uuidString, scope.profileID.uuidString, "projects", "home"])
    }

    /// Caller holds a transaction with sync_control suspended.
    private func canonicalizeHomeIdentity(scope: SyncScope, queue: Bool = true) throws {
        let canonical = Self.homeSyncID(scope: scope)
        guard let old = try connection.query("SELECT sync_id FROM projects WHERE is_home = 1 ORDER BY id LIMIT 1").first?["sync_id"]?.stringValue,
              old != canonical,
              try connection.query("SELECT 1 FROM projects WHERE sync_id = ?", [.text(canonical)]).isEmpty else { return }
        try rekeySyncRow(table: try SyncTable.named("projects"), old: old, new: canonical)
        // A Home seeded or pushed under its old identity must go out again
        // under the shared one.
        if queue, try !connection.query("SELECT 1 FROM sync_binding").isEmpty,
           try connection.query("SELECT 1 FROM sync_outbox WHERE \"table\" = 'projects' AND sync_id = ?", [.text(canonical)]).isEmpty {
            try connection.execute("INSERT INTO sync_outbox(\"table\", sync_id, op) VALUES ('projects', ?, 'upsert')", [.text(canonical)])
        }
    }

    private func rekeySyncRow(table: SyncTable, old: String, new: String) throws {
        if table.name == "text_overlay_presets",
           try !connection.query("SELECT 1 FROM text_overlay_presets WHERE sync_id = ?", [.text(new)]).isEmpty {
            // Identical name/design presets can predate sync; nothing references
            // their integer IDs. Keep the existing copy and its local thumbnail.
            try connection.execute("DELETE FROM text_overlay_presets WHERE sync_id = ?", [.text(old)])
        } else {
            try connection.execute("UPDATE \(table.name) SET sync_id = ? WHERE sync_id = ?", [.text(new), .text(old)])
        }
        try connection.execute("UPDATE sync_outbox SET sync_id = ? WHERE \"table\" = ? AND sync_id = ?",
                               [.text(new), .text(table.name), .text(old)])
    }

    private func references(for table: SyncTable, row: SQLRow) -> [String: String] {
        var refs = table.references
        if table.name == "reel_traits" {
            switch row["video_kind"]?.stringValue {
            case "instagram": refs["video_id"] = "ig_media"
            case "imported": refs["video_id"] = "ig_report_media"
            default: break
            }
        }
        return refs
    }

    private func isPortableSyncRow(_ row: SQLRow, table: SyncTable) -> Bool {
        table.name != "reel_traits" || ["instagram", "imported", "external"].contains(row["video_kind"]?.stringValue ?? "")
    }

    private func portableSyncRow(_ row: SQLRow, table: SyncTable) throws -> SQLRow? {
        var row = row
        for (column, target) in references(for: table, row: row) {
            if row[column] == nil || row[column]?.stringValue == nil { continue }
            guard let value = row[column]?.intValue,
                  let id = try connection.query("SELECT sync_id FROM \(target) WHERE id = ?", [.integer(value)]).first?["sync_id"]?.stringValue else {
                if table.name == "reel_traits" || table.name == "taste_studies" { return nil }
                throw SyncError.invalidRow("\(table.name).\(column) reference")
            }
            row[column] = .text(id)
        }
        if table.name == "fight_picks" {
            // Local fight_events ids mean nothing on another Mac; send sync_ids.
            let ids = (row["event_ids"]?.stringValue).flatMap { try? JSONDecoder().decode([Int64].self, from: Data($0.utf8)) } ?? []
            let syncIDs = try ids.compactMap { id in
                try connection.query("SELECT sync_id FROM fight_events WHERE id = ?", [.integer(id)]).first?["sync_id"]?.stringValue
            }
            row["event_ids"] = .text(String(decoding: try JSONEncoder().encode(syncIDs), as: UTF8.self))
        }
        if table.name == "reel_outcomes", let json = row["outcome_json"]?.stringValue {
            var object = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(json.utf8))
            object["accountID"] = nil
            object["videoID"] = nil
            row["outcome_json"] = .text(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
        }
        return row
    }

    func pendingSyncChanges(scope: SyncScope, limit: Int, table: SyncTable = .lessons) async throws -> [SyncPendingChange] {
        guard try syncScope() == scope else { throw SyncError.scopeMismatch }
        try await canonicalizeSyncIdentities(scope: scope, tables: [table])
        return try connection.transaction {
            // Reads and edits lazily fill original-text lesson identities. Do
            // that before capturing sequences so an edit during a POST cannot
            // requeue unrelated in-flight lessons just by reading them.
            if table == .lessons { try backfillLessonIdentities() }
            // Filter before LIMIT: a batch of skipped caches must not hide valid
            // changes behind it. Soft references have no SQLite cascade.
            if table.name == "reel_traits" {
                try connection.execute("""
                    DELETE FROM sync_outbox WHERE "table" = 'reel_traits' AND EXISTS (
                        SELECT 1 FROM reel_traits WHERE reel_traits.sync_id = sync_outbox.sync_id AND (
                            video_kind NOT IN ('instagram', 'imported', 'external')
                            OR (video_kind = 'instagram' AND NOT EXISTS (SELECT 1 FROM ig_media WHERE id = reel_traits.video_id))
                            OR (video_kind = 'imported' AND NOT EXISTS (SELECT 1 FROM ig_report_media WHERE id = reel_traits.video_id))
                        )
                    )
                    """)
            } else if table.name == "taste_studies" {
                try connection.execute("""
                    DELETE FROM sync_outbox WHERE "table" = 'taste_studies' AND EXISTS (
                        SELECT 1 FROM taste_studies WHERE taste_studies.sync_id = sync_outbox.sync_id
                            AND NOT EXISTS (SELECT 1 FROM ig_media WHERE id = taste_studies.media_id)
                    )
                    """)
            }
            var changes: [SyncPendingChange] = []
            var scannedThrough: Int64 = 0
            while changes.isEmpty {
                let entries = try connection.query("""
                    SELECT sync_id, MAX(sequence) AS sequence FROM sync_outbox
                    WHERE "table" = ? GROUP BY sync_id HAVING MAX(sequence) > ? ORDER BY sequence LIMIT ?
                    """, [.text(table.name), .integer(scannedThrough), .integer(Int64(max(1, limit)))])
                if entries.isEmpty { break }
                scannedThrough = entries.last?["sequence"]?.intValue ?? scannedThrough
                changes = try entries.compactMap { entry in
                    do {
                    guard let id = entry["sync_id"]?.stringValue, let sequence = entry["sequence"]?.intValue else { throw SyncError.invalidRow("outbox") }
                    let local = try connection.query("SELECT * FROM \(table.name) WHERE sync_id = ?", [.text(id)]).first
                    let portable: SQLRow?
                    if let local {
                        guard isPortableSyncRow(local, table: table),
                              let row = try portableSyncRow(local, table: table) else {
                            try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND sequence <= ?",
                                                   [.text(table.name), .text(id), .integer(sequence)])
                            return nil
                        }
                        portable = row
                    } else { portable = nil }
                    let cached = try connection.query("SELECT wire_json FROM sync_wire_rows WHERE \"table\" = ? AND sync_id = ?",
                                                      [.text(table.name), .text(id)]).first?["wire_json"]?.stringValue
                    let preserved = try cached.map { try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data($0.utf8)) } ?? [:]
                    if table.name == "reel_traits", local == nil,
                       !["instagram", "imported", "external"].contains(preserved["video_kind"]?.string ?? "") {
                        // Old clients may have queued a local-only delete. Only send
                        // trait tombstones whose previously shared kind is known.
                        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND sequence <= ?",
                                               [.text(table.name), .text(id), .integer(sequence)])
                        return nil
                    }
                    return SyncPendingChange(table: table, sequence: sequence, syncID: id,
                        wire: try SyncMapping.wire(local: portable, syncID: id,
                                                   scope: scope, preserved: preserved, table: table))
                    } catch {
                        if error is CancellationError { throw error }
                        NSLog("Team Sync: skipping queued row in %@: %@", table.name, error.localizedDescription)
                        return nil
                    }
                }
            }
            return changes
        }
    }

    func acknowledgeSyncChanges(_ changes: [SyncPendingChange]) throws {
        try connection.transaction {
            for change in changes { try acknowledgeSyncChange(change) }
        }
    }

    func acknowledgeSyncChange(_ change: SyncPendingChange) throws {
        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND sequence <= ?",
                               [.text(change.table.name), .text(change.syncID), .integer(change.sequence)])
        // The server now holds what was sent: that is the copy a later merge
        // measures this Mac's changes against. Left at the copy from before,
        // an edit made after this upload that returns a column to its old
        // value would look like no change and lose to the upload's own echo.
        guard Self.mergedOnPull.contains(change.table.name), !SyncMapping.isDeleted(change.wire) else { return }
        var seen = change.wire
        if let cached = try connection.query("SELECT wire_json FROM sync_wire_rows WHERE \"table\" = ? AND sync_id = ?",
                                             [.text(change.table.name), .text(change.syncID)]).first?["wire_json"]?.stringValue,
           let known = try? JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(cached.utf8)), !SyncMapping.isDeleted(known) {
            seen = known
            for column in change.table.columns { if let value = change.wire[column] { seen[column] = value } }
        }
        let json = String(decoding: try JSONEncoder().encode(seen), as: UTF8.self)
        try connection.execute("""
            INSERT INTO sync_wire_rows("table", sync_id, wire_json) VALUES (?, ?, ?)
            ON CONFLICT("table", sync_id) DO UPDATE SET wire_json = excluded.wire_json
            """, [.text(change.table.name), .text(change.syncID), .text(json)])
    }

    func syncCursor(table: SyncTable = .lessons) throws -> SyncCursor? {
        guard let row = try connection.query("SELECT * FROM sync_cursors WHERE \"table\" = ?", [.text(table.name)]).first,
              let timestamp = row["server_updated_at"]?.stringValue, let id = row["sync_id"]?.stringValue else { return nil }
        return SyncCursor(timestamp: timestamp, syncID: id)
    }

    func syncPendingCount() throws -> Int {
        Int(try connection.query("SELECT COUNT(*) AS n FROM (SELECT 1 FROM sync_outbox GROUP BY \"table\", sync_id)").first?["n"]?.intValue ?? 0)
    }

    @discardableResult
    func applySyncRows(_ rows: [SyncMapping.WireRow], scope: SyncScope, table: SyncTable = .lessons,
                       serverWinsThrough: Int64? = nil, advanceCursor: Bool = true) throws -> Bool {
        guard !rows.isEmpty else { return false }
        guard try syncScope() == scope else { throw SyncError.scopeMismatch }
        var dubFilesToRemove: [String] = []
        let changed = try connection.transaction {
            var changed = false
            var fightVideos = Set<Int64>()
            /// Waits for a parent row that has not arrived; retrySyncParents applies it later.
            func parkForParent(_ wire: SyncMapping.WireRow, id: String) throws {
                let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
                try connection.execute("""
                    INSERT INTO sync_pending_parents("table", sync_id, wire_json, server_wins_through)
                    VALUES (?, ?, ?, ?) ON CONFLICT("table", sync_id) DO UPDATE SET
                    wire_json = excluded.wire_json, server_wins_through = excluded.server_wins_through
                    """, [.text(table.name), .text(id), .text(json), serverWinsThrough.map(SQLValue.integer) ?? .null])
            }
            try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
            rowLoop: for wire in rows {
                let id = try SyncMapping.identity(wire, scope: scope)
                if table.name == "profile_documents", id != scope.profileID.uuidString.lowercased() {
                    throw SyncError.invalidRow("profile identity")
                }
                var local = SyncMapping.isDeleted(wire) ? [:] : try SyncMapping.local(wire: wire, localID: nil, scope: scope, table: table)
                if table.name == "reel_traits" {
                    // A nonportable remote upsert or tombstone must never touch a
                    // local generated/scene cache, even if its UUID collides.
                    if !SyncMapping.isDeleted(wire), !isPortableSyncRow(local, table: table) { continue }
                    if let existing = try connection.query("SELECT * FROM reel_traits WHERE sync_id = ?", [.text(id)]).first,
                       !isPortableSyncRow(existing, table: table) { continue }
                }
                let pulledHome = table.name == "projects" && !SyncMapping.isDeleted(wire) && local["is_home"]?.intValue == 1
                if pulledHome {
                    // Every Mac's Home shares homeSyncID; the local Home adopts it
                    // and this row updates it. A Home without that identity is
                    // never inserted as a second (deletable) project.
                    guard id == Self.homeSyncID(scope: scope) else {
                        NSLog("Team Sync: ignoring a Home project without the shared identity")
                        continue
                    }
                    try canonicalizeHomeIdentity(scope: scope, queue: false)
                }
                if !SyncMapping.isDeleted(wire) {
                    for (column, target) in references(for: table, row: local) {
                        if local[column]?.stringValue == nil { continue }
                        guard let ref = local[column]?.stringValue,
                              let value = try connection.query("SELECT id FROM \(target) WHERE sync_id = ?", [.text(ref)]).first?["id"] else {
                            if !table.references.isEmpty || table.name == "reel_traits" {
                                try parkForParent(wire, id: id)
                                continue rowLoop
                            }
                            throw SyncError.invalidRow("\(table.name).\(column) missing parent")
                        }
                        local[column] = (column == "video_id" && ["reel_traits", "reel_outcomes"].contains(table.name)) ? .text(value.stringValue ?? "") : value
                    }
                    if table.name == "fight_picks" {
                        // event_ids carries fight_events sync_ids. Translate only when
                        // every event has arrived; otherwise wait like an FK parent.
                        let refs = (local["event_ids"]?.stringValue).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                        var localIDs: [Int64] = []
                        for ref in refs {
                            guard let value = try connection.query("SELECT id FROM fight_events WHERE sync_id = ?", [.text(ref)]).first?["id"]?.intValue else {
                                try parkForParent(wire, id: id)
                                continue rowLoop
                            }
                            localIDs.append(value)
                        }
                        local["event_ids"] = .text(String(decoding: try JSONEncoder().encode(localIDs), as: UTF8.self))
                    }
                    if !table.naturalKey.isEmpty && !table.preservesDuplicateKeys && !pulledHome {
                        // An ordinary project never takes over Home's identity.
                        let homeGuard = table.name == "projects" ? " AND is_home = 0" : ""
                        let predicate = table.naturalKey.map { "\"\($0)\" IS ?" }.joined(separator: " AND ") + homeGuard
                        if let old = try connection.query("SELECT sync_id FROM \(table.name) WHERE \(predicate)",
                                                           table.naturalKey.map { local[$0] ?? .null }).first?["sync_id"]?.stringValue, old != id {
                            // Two local rows can share a natural key (NULL run_id scenes
                            // before schema 45). When one already carries this identity
                            // the upsert below lands on it; re-keying the other would
                            // collide and abort the whole pull.
                            if try connection.query("SELECT 1 FROM \(table.name) WHERE sync_id = ?", [.text(id)]).isEmpty {
                                try rekeySyncRow(table: table, old: old, new: id)
                            } else if table.name == "voice_profiles" {
                                // (person_key, video_id) is the primary key here, so the
                                // upsert below would move this identity onto a key another
                                // row holds and abort the whole pull. No client renames a
                                // voice in place (moveVoiceProfiles), so this should not
                                // arrive; if it does, keep both local rows as they are.
                                NSLog("Team Sync: ignoring a voice profile renamed onto %@", old)
                                continue rowLoop
                            } else {
                                NSLog("Team Sync: %@ already holds %@; leaving %@ as a local duplicate", table.name, id, old)
                            }
                        }
                    }
                }
                // What the server held when this Mac last saw the row.
                let base = try connection.query("SELECT wire_json FROM sync_wire_rows WHERE \"table\" = ? AND sync_id = ?",
                                                [.text(table.name), .text(id)]).first?["wire_json"]?.stringValue
                let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
                try connection.execute("""
                    INSERT INTO sync_wire_rows("table", sync_id, wire_json) VALUES (?, ?, ?)
                    ON CONFLICT("table", sync_id) DO UPDATE SET wire_json = excluded.wire_json
                    """, [.text(table.name), .text(id), .text(json)])
                try connection.execute("DELETE FROM sync_pending_parents WHERE \"table\" = ? AND sync_id = ?",
                                       [.text(table.name), .text(id)])
                if let serverWinsThrough {
                    // The initial shared copy wins both UUID and natural-key matches.
                    if table.name == "profile_documents" {
                        // The profile seed is created after binding. Its edits
                        // are replayed field by field during adoption, unlike
                        // ordinary rows whose newer outbox entry must survive.
                        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ?",
                                               [.text(table.name), .text(id)])
                    } else {
                        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? AND sequence <= ?",
                                               [.text(table.name), .text(id), .integer(serverWinsThrough)])
                    }
                }
                if try !connection.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? AND sync_id = ? LIMIT 1",
                                         [.text(table.name), .text(id)]).isEmpty {
                    // A change to this row is still waiting to be pushed.
                    if SyncMapping.isDeleted(wire), base != nil {
                        // A teammate deleted a row both Macs knew. The delete
                        // wins: pushing the waiting edit would bring the row
                        // back for everyone.
                        try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ?",
                                               [.text(table.name), .text(id)])
                    } else if !SyncMapping.isDeleted(wire),
                              let mine = try locallyChangedColumns(table: table, id: id, base: base, scope: scope),
                              let current = try connection.query("SELECT * FROM \(table.name) WHERE sync_id = ?", [.text(id)]).first {
                        // Field by field: what this Mac changed since it last
                        // saw the row stays and is pushed; every other column
                        // takes the teammate's value.
                        for column in mine { local[column] = current[column] ?? .null }
                        if mine.isEmpty {
                            try connection.execute("DELETE FROM sync_outbox WHERE \"table\" = ? AND sync_id = ?",
                                                   [.text(table.name), .text(id)])
                        }
                    } else {
                        continue
                    }
                }
                if table.name == "fight_events" {
                    let previous = try connection.query("SELECT * FROM fight_events WHERE sync_id = ?", [.text(id)]).first
                    let eventChanged = SyncMapping.isDeleted(wire) ? previous != nil :
                        previous == nil || table.columns.contains {
                            previous?[$0]?.stringValue != local[$0]?.stringValue
                        }
                    if eventChanged {
                        if let videoID = previous?["video_id"]?.intValue { fightVideos.insert(videoID) }
                        if let videoID = local["video_id"]?.intValue { fightVideos.insert(videoID) }
                    }
                }
                if SyncMapping.isDeleted(wire) {
                    // A teammate deleting their copy of this Mac's Home must not
                    // delete Home (and, by cascade, its local timelines) here.
                    if table.name == "projects",
                       try connection.query("SELECT is_home FROM projects WHERE sync_id = ?", [.text(id)]).first?["is_home"]?.intValue == 1 {
                        continue
                    }
                    if try !connection.query("SELECT 1 FROM \(table.name) WHERE sync_id = ?", [.text(id)]).isEmpty { changed = true }
                    if table.name == "dub_takes", let file = try connection.query(
                        "SELECT audio_file FROM dub_takes WHERE sync_id = ?", [.text(id)]).first?["audio_file"]?.stringValue {
                        dubFilesToRemove.append(file)
                    } else if table.name == "videos", let videoID = try connection.query(
                        "SELECT id FROM videos WHERE sync_id = ?", [.text(id)]).first?["id"]?.intValue {
                        dubFilesToRemove += try dubTakeAudioFiles(videoIDs: [videoID])
                    }
                    try connection.execute("DELETE FROM \(table.name) WHERE sync_id = ?", [.text(id)])
                } else {
                    let existing = try connection.query("SELECT * FROM \(table.name) WHERE sync_id = ?", [.text(id)]).first
                    if table.name == "dub_takes" {
                        guard let file = local["audio_file"]?.stringValue, !file.isEmpty,
                              file == URL(fileURLWithPath: file).lastPathComponent else {
                            throw SyncError.invalidRow("dub take audio_file")
                        }
                        // A content-key row can be edited in place. Its old bytes
                        // must not be mistaken for the teammate's new wording.
                        if let existing, ["text", "audio_file", "alignment_json", "drive_file_id"].contains(where: {
                            existing[$0]?.stringValue != local[$0]?.stringValue
                        }), let oldFile = existing["audio_file"]?.stringValue {
                            dubFilesToRemove.append(oldFile)
                        }
                    }
                    if table.name == "analysis_runs", existing == nil, let video = local["video_id"]?.intValue,
                       try connection.query("SELECT 1 FROM analysis_runs WHERE video_id = ? LIMIT 1", [.integer(video)]).isEmpty {
                        try connection.execute("INSERT OR IGNORE INTO sync_run_defaults(video_id) VALUES (?)", [.integer(video)])
                    }
                    if table.name == "videos", let driveID = existing?["drive_file_id"]?.stringValue, !driveID.isEmpty {
                        local["drive_file_id"] = .text(driveID)
                        local["drive_link"] = existing?["drive_link"] ?? .null
                    }
                    if table.name == "profile_documents" { try beginSyncProfileAdoption(fallback: "{}") }
                    for column in table.columns where column.hasSuffix("_json") {
                        if let text = local[column]?.stringValue,
                           let remote = try? JSONDecoder().decode(SyncJSON.self, from: Data(text.utf8)) {
                            let previous = existing?[column]?.stringValue.flatMap { try? JSONDecoder().decode(SyncJSON.self, from: Data($0.utf8)) }
                            let merged = SyncMapping.applyingPortableJSON(remote, to: previous)
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = .sortedKeys
                            local[column] = .text(String(decoding: try encoder.encode(merged), as: UTF8.self))
                        }
                    }
                    var columns = table.columns
                    if table.name == "projects" {
                        // is_home is per Mac and a pull never changes it; Home rows
                        // share homeSyncID, so a pulled Home lands on the local Home.
                        if let existing {
                            local["is_home"] = existing["is_home"] ?? .integer(0)
                        } else if local["is_home"]?.intValue == 1,
                                  try !connection.query("SELECT 1 FROM projects WHERE is_home = 1").isEmpty {
                            // Unreachable unless the local Home could not adopt the
                            // shared identity; never add a second Home or a copy of it.
                            NSLog("Team Sync: local Home could not adopt the shared identity")
                            continue
                        }
                        // profile_name is local-only and NOT NULL. INSERT ... ON CONFLICT
                        // checks NOT NULL before the conflict, so every upsert carries
                        // it: the row's own value, else this profile's projects' name.
                        let profile = try existing?["profile_name"]?.stringValue
                            ?? connection.query("SELECT profile_name FROM projects ORDER BY is_home DESC, id LIMIT 1").first?["profile_name"]?.stringValue
                            ?? path.deletingPathExtension().lastPathComponent
                        local["profile_name"] = .text(profile)
                        columns.append("profile_name")
                        if local["archived"]?.intValue == nil { local["archived"] = .integer(0) }
                    }
                    if table.name == "library_asset_metadata" {
                        // Metadata can arrive before Drive brings the file. Keep an
                        // opaque placeholder until a matching local asset is indexed.
                        local["path"] = .text("team-asset:\(local["asset_id"]?.stringValue ?? id)")
                        if try connection.query("SELECT 1 FROM library_asset_metadata WHERE sync_id = ?", [.text(id)]).isEmpty { columns.append("path") }
                    }
                    if table.name == "reel_outcomes", let json = local["outcome_json"]?.stringValue {
                        var object = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(json.utf8))
                        object["accountID"] = .number(Decimal(local["account_id"]?.intValue ?? 0))
                        object["videoID"] = .string(local["video_id"]?.stringValue ?? "")
                        local["outcome_json"] = .text(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
                    }
                    if existing == nil || columns.contains(where: { column in
                        let old = existing?[column]?.stringValue, new = local[column]?.stringValue
                        if column.hasSuffix("_json"), let old, let new,
                           let lhs = try? JSONDecoder().decode(SyncJSON.self, from: Data(old.utf8)),
                           let rhs = try? JSONDecoder().decode(SyncJSON.self, from: Data(new.utf8)) {
                            return lhs != rhs
                        }
                        if table.reals.contains(column), let lhs = existing?[column]?.doubleValue,
                           let rhs = local[column]?.doubleValue {
                            return abs(lhs - rhs) > max(1, abs(lhs), abs(rhs)) * 1e-12
                        }
                        return old != new
                    }) {
                        changed = true
                    }
                    let quoted = columns.map { "\"\($0)\"" }
                    try connection.execute("""
                        INSERT INTO \(table.name)(sync_id, \(quoted.joined(separator: ", ")))
                        VALUES (?, \(columns.map { _ in "?" }.joined(separator: ", ")))
                        ON CONFLICT(sync_id) DO UPDATE SET \(quoted.map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
                        """, [.text(id)] + columns.map { local[$0] ?? .null })
                }
            }
            for videoID in fightVideos {
                let generation = try advanceFightEventGeneration(videoID: videoID)
                try connection.execute("UPDATE fight_events SET generation = ? WHERE video_id = ?",
                                       [.integer(generation), .integer(videoID)])
                let version = try connection.query("SELECT MIN(COALESCE(scoring_version, 1)) AS v FROM fight_events WHERE video_id = ?",
                                                   [.integer(videoID)]).first?["v"]?.intValue ?? 1
                let pass = try startAnalysisPass(videoID: videoID, pass: .fightScore, version: Int(version))
                try finishAnalysisPass(pass, status: .completed, note: "Synced event snapshot")
            }
            if advanceCursor {
                let cursor = try SyncMapping.cursor(rows[rows.count - 1], scope: scope)
                try connection.execute("""
                    INSERT INTO sync_cursors("table", server_updated_at, sync_id) VALUES (?, ?, ?)
                    ON CONFLICT("table") DO UPDATE SET server_updated_at = excluded.server_updated_at, sync_id = excluded.sync_id
                    """, [.text(table.name), .text(cursor.timestamp), .text(cursor.syncID)])
            }
            try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            return changed
        }
        try deleteDubTakeAudioFiles(dubFilesToRemove)
        return changed
    }

    /// Rows of these tables are edited a field at a time on several Macs
    /// (a trim here, the transcript in use there), so a pull merges into a
    /// row that has a change waiting instead of skipping it.
    private nonisolated static let mergedOnPull: Set<String> = ["videos", "scenes", "transcript_picks", "fight_picks"]

    /// The synced columns of a local row that differ from `base`, the
    /// server's copy as this Mac last saw it: the ones changed here since.
    /// Nil when the row cannot be merged (another table, no such copy, no
    /// local row), which leaves the waiting change to win as a whole.
    private func locallyChangedColumns(table: SyncTable, id: String, base: String?, scope: SyncScope) throws -> [String]? {
        guard Self.mergedOnPull.contains(table.name), let base,
              let seen = try? JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(base.utf8)),
              !SyncMapping.isDeleted(seen),
              let row = try connection.query("SELECT * FROM \(table.name) WHERE sync_id = ?", [.text(id)]).first,
              let portable = (try? portableSyncRow(row, table: table)) ?? nil,
              let mine = try? SyncMapping.wire(local: portable, syncID: id, scope: scope, table: table) else { return nil }
        var changed = Set(table.columns.filter {
            !SyncMapping.sameWireValue(mine[$0] ?? .null, seen[$0] ?? .null, json: $0.hasSuffix("_json"))
        })
        // A range is one value: this Mac's start with a teammate's end can
        // be a range that ends before it starts.
        for pair in Self.mergedTogether where !changed.isDisjoint(with: pair) {
            changed.formUnion(pair.filter(table.columns.contains))
        }
        return table.columns.filter(changed.contains)
    }

    /// Columns that only mean something together.
    private nonisolated static let mergedTogether: [Set<String>] = [["start_time", "end_time"], ["edit_start", "edit_end"]]

    /// Whether changes to this table wait to be pushed.
    func syncPending(table: SyncTable) throws -> Bool {
        try !connection.query("SELECT 1 FROM sync_outbox WHERE \"table\" = ? LIMIT 1", [.text(table.name)]).isEmpty
    }

    func retrySyncParents(scope: SyncScope, table: SyncTable) throws -> Bool {
        var changed = false
        for row in try connection.query("SELECT * FROM sync_pending_parents WHERE \"table\" = ?", [.text(table.name)]) {
            try Task.checkCancellation()
            guard let json = row["wire_json"]?.stringValue else { continue }
            let wire = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(json.utf8))
            if try applySyncRows([wire], scope: scope, table: table,
                                 serverWinsThrough: row["server_wins_through"]?.intValue, advanceCursor: false) {
                changed = true
            }
        }
        return changed
    }
}
