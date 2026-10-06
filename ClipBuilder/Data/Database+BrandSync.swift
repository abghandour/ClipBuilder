import Foundation

extension Database {
    nonisolated static func migrateBrandSync(_ db: SQLiteConnection) throws {
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
        for table in SyncTable.all {
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
                    AND EXISTS (SELECT 1 FROM sync_binding)\(portableNew)
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

    func bindSync(to scope: SyncScope) throws {
        try connection.transaction {
            if let existing = try syncScope() {
                guard existing == scope else { throw SyncError.scopeMismatch }
                return
            }
            try backfillLessonIdentities()
            try connection.execute("INSERT INTO sync_binding VALUES (1, ?, ?)",
                                   [.text(scope.teamID.uuidString), .text(scope.profileID.uuidString)])
            for table in SyncTable.all {
                let portable = table.name == "reel_traits" ? " AND video_kind IN ('instagram', 'imported', 'external')" : ""
                // Seed in local row order; a covering sync_id index otherwise
                // queues pre-existing rows in random UUID order.
                try connection.execute("""
                    INSERT INTO sync_outbox("table", sync_id, op)
                    SELECT ?, sync_id, 'upsert' FROM \(table.name)
                    WHERE NOT EXISTS (SELECT 1 FROM sync_outbox WHERE "table" = ? AND sync_id = \(table.name).sync_id)\(portable)
                    ORDER BY \(table.name).rowid
                    """, [.text(table.name), .text(table.name)])
            }
            _ = try initialSyncBoundary()
        }
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
    func canonicalizeSyncIdentities(scope: SyncScope, tables: [SyncTable] = SyncTable.all) throws {
        try connection.transaction {
            try connection.execute("UPDATE sync_control SET suspended = 1 WHERE id = 1")
            for table in tables where !table.naturalKey.isEmpty {
                try Task.checkCancellation()
                for var row in try connection.query("""
                    SELECT rowid AS local_rowid, * FROM \(table.name)
                    WHERE substr(sync_id, 15, 1) != '5'
                        AND sync_id IN (SELECT sync_id FROM sync_outbox WHERE "table" = ?)
                        AND sync_id NOT IN (SELECT sync_id FROM sync_wire_rows WHERE "table" = ?)
                    """, [.text(table.name), .text(table.name)]) {
                    try Task.checkCancellation()
                    if table.name == "library_asset_metadata", row["asset_id"]?.stringValue == nil {
                        let asset = TeamSyncAsset.identity(path: row["path"]?.stringValue ?? "", kind: row["kind"]?.stringValue ?? "")
                        row["asset_id"] = .text(asset)
                        try connection.execute("UPDATE library_asset_metadata SET asset_id = ? WHERE rowid = ?",
                                               [.text(asset), row["local_rowid"] ?? .null])
                    }
                    guard isPortableSyncRow(row, table: table),
                          let portable = try portableSyncRow(row, table: table) else { continue }
                    let key = table.naturalKey.map { column -> String in
                        let value = portable[column]?.stringValue ?? "<null>"
                        return column == "username" ? value.lowercased() : value
                    }
                    let canonical = SyncMapping.stableID([scope.teamID.uuidString, scope.profileID.uuidString, table.name] + key)
                    guard let old = row["sync_id"]?.stringValue, old != canonical else { continue }
                    try rekeySyncRow(table: table, old: old, new: canonical)
                }
            }
            try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
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
            guard let value = row[column]?.intValue,
                  let id = try connection.query("SELECT sync_id FROM \(target) WHERE id = ?", [.integer(value)]).first?["sync_id"]?.stringValue else {
                if table.name == "reel_traits" || table.name == "taste_studies" { return nil }
                throw SyncError.invalidRow("\(table.name).\(column) reference")
            }
            row[column] = .text(id)
        }
        if table.name == "reel_outcomes", let json = row["outcome_json"]?.stringValue {
            var object = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(json.utf8))
            object["accountID"] = nil
            object["videoID"] = nil
            row["outcome_json"] = .text(String(decoding: try JSONEncoder().encode(object), as: UTF8.self))
        }
        return row
    }

    func pendingSyncChanges(scope: SyncScope, limit: Int, table: SyncTable = .lessons) throws -> [SyncPendingChange] {
        guard try syncScope() == scope else { throw SyncError.scopeMismatch }
        try canonicalizeSyncIdentities(scope: scope, tables: [table])
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
            while changes.isEmpty {
                let entries = try connection.query("""
                    SELECT sync_id, MAX(sequence) AS sequence FROM sync_outbox
                    WHERE "table" = ? GROUP BY sync_id ORDER BY sequence LIMIT ?
                    """, [.text(table.name), .integer(Int64(max(1, limit)))])
                if entries.isEmpty { break }
                changes = try entries.compactMap { entry in
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
        return try connection.transaction {
            var changed = false
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
                if !SyncMapping.isDeleted(wire) {
                    for (column, target) in references(for: table, row: local) {
                        guard let ref = local[column]?.stringValue,
                              let value = try connection.query("SELECT id FROM \(target) WHERE sync_id = ?", [.text(ref)]).first?["id"] else {
                            if table.name == "reel_traits" || table.name == "taste_studies" {
                                let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
                                try connection.execute("""
                                    INSERT INTO sync_pending_parents("table", sync_id, wire_json, server_wins_through)
                                    VALUES (?, ?, ?, ?) ON CONFLICT("table", sync_id) DO UPDATE SET
                                    wire_json = excluded.wire_json, server_wins_through = excluded.server_wins_through
                                    """, [.text(table.name), .text(id), .text(json), serverWinsThrough.map(SQLValue.integer) ?? .null])
                                continue rowLoop
                            }
                            throw SyncError.invalidRow("\(table.name).\(column) missing parent")
                        }
                        local[column] = (column == "video_id") ? .text(value.stringValue ?? "") : value
                    }
                    if !table.naturalKey.isEmpty {
                        let predicate = table.naturalKey.map { "\"\($0)\" IS ?" }.joined(separator: " AND ")
                        if let old = try connection.query("SELECT sync_id FROM \(table.name) WHERE \(predicate)",
                                                           table.naturalKey.map { local[$0] ?? .null }).first?["sync_id"]?.stringValue, old != id {
                            try rekeySyncRow(table: table, old: old, new: id)
                        }
                    }
                }
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
                                         [.text(table.name), .text(id)]).isEmpty { continue }
                if SyncMapping.isDeleted(wire) {
                    if try !connection.query("SELECT 1 FROM \(table.name) WHERE sync_id = ?", [.text(id)]).isEmpty { changed = true }
                    try connection.execute("DELETE FROM \(table.name) WHERE sync_id = ?", [.text(id)])
                } else {
                    let existing = try connection.query("SELECT * FROM \(table.name) WHERE sync_id = ?", [.text(id)]).first
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
            if advanceCursor {
                let cursor = try SyncMapping.cursor(rows[rows.count - 1], scope: scope)
                try connection.execute("""
                    INSERT INTO sync_cursors("table", server_updated_at, sync_id) VALUES (?, ?, ?)
                    ON CONFLICT("table") DO UPDATE SET server_updated_at = excluded.server_updated_at, sync_id = excluded.sync_id
                    """, [.text(table.name), .text(cursor.timestamp), .text(cursor.syncID)])
            }
            #if DEBUG
            guard try connection.query("PRAGMA foreign_key_check").isEmpty else { throw SyncError.invalidRow("foreign keys") }
            #endif
            try connection.execute("UPDATE sync_control SET suspended = 0 WHERE id = 1")
            return changed
        }
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
