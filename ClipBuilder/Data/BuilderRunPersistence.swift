import Foundation

/// SQL shared by the actor and the coordinator's short, synchronous connection.
/// A connection is confined to its caller; no actor-owned handle crosses isolation.
nonisolated enum BuilderRunPersistence {
    static func record(_ run: BuilderRunRecord, on db: SQLiteConnection) throws {
        try db.execute("""
            INSERT INTO builder_runs (run_uuid, timeline_id, request, created_at, provider, model,
                duration_seconds, status, baseline_revision, applied_revision, summary,
                library_effects_json, events_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_uuid) DO UPDATE SET status = excluded.status, applied_revision = excluded.applied_revision,
                events_json = CASE WHEN excluded.provider = 'script' AND excluded.status = 'failed'
                    THEN excluded.events_json ELSE builder_runs.events_json END,
                summary = CASE WHEN excluded.provider = 'script' AND excluded.status = 'failed'
                    THEN excluded.summary ELSE builder_runs.summary END
            WHERE builder_runs.timeline_id = excluded.timeline_id AND builder_runs.status = 'completed'
                AND excluded.status IN ('applied', 'failed', 'discarded')
            """, [.text(run.runUUID), .integer(run.timelineID), .text(run.request), .text(run.createdAt),
                  .text(run.provider), run.model.map(SQLValue.text) ?? .null,
                  run.durationSeconds.map(SQLValue.real) ?? .null, .text(run.status.rawValue),
                  .integer(Int64(run.baselineRevision)), run.appliedRevision.map { .integer(Int64($0)) } ?? .null,
                  run.summary.map(SQLValue.text) ?? .null, .text(run.libraryEffectsJSON), .text(run.eventsJSON)])
        guard try db.query("SELECT changes() AS count").first?["count"]?.intValue == 1 else {
            throw ApplyFailure.notApplicable
        }
    }

    static func retainRuns(timelineID: Int64, on db: SQLiteConnection) throws {
        // Rank the protected row first, leaving 49 other slots when it exists.
        try db.execute("""
            DELETE FROM builder_runs WHERE timeline_id = ? AND run_uuid NOT IN (
                SELECT r.run_uuid FROM builder_runs r WHERE r.timeline_id = ?
                ORDER BY EXISTS(SELECT 1 FROM timeline_wizard_before b
                    WHERE b.timeline_id = r.timeline_id AND b.run_uuid = r.run_uuid) DESC,
                    r.created_at DESC, r.rowid DESC LIMIT 50)
            """, [.integer(timelineID), .integer(timelineID)])
    }

    static func saveBefore(_ before: WizardBeforeRecord, on db: SQLiteConnection) throws {
        try db.execute("""
            INSERT INTO timeline_wizard_before
                (timeline_id, run_uuid, request, created_at, document_json, applied_revision)
            VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(timeline_id) DO UPDATE SET
                run_uuid = excluded.run_uuid, request = excluded.request, created_at = excluded.created_at,
                document_json = excluded.document_json, applied_revision = excluded.applied_revision
            """, [.integer(before.timelineID), .text(before.runUUID), .text(before.request),
                  .text(before.createdAt), .text(before.documentJSON), .integer(Int64(before.appliedRevision))])
    }

    static func run(_ row: SQLRow) -> BuilderRunRecord {
        BuilderRunRecord(runUUID: row["run_uuid"]?.stringValue ?? "",
                         timelineID: row["timeline_id"]?.intValue ?? 0,
                         request: row["request"]?.stringValue ?? "", createdAt: row["created_at"]?.stringValue ?? "",
                         provider: row["provider"]?.stringValue ?? "local", model: row["model"]?.stringValue,
                         durationSeconds: row["duration_seconds"]?.doubleValue,
                         status: BuilderRunStatus(rawValue: row["status"]?.stringValue ?? "") ?? .failed,
                         baselineRevision: Int(row["baseline_revision"]?.intValue ?? 0),
                         appliedRevision: row["applied_revision"]?.intValue.map(Int.init),
                         summary: row["summary"]?.stringValue,
                         libraryEffectsJSON: row["library_effects_json"]?.stringValue ?? "[]",
                         eventsJSON: row["events_json"]?.stringValue ?? "[]")
    }

    static func before(_ row: SQLRow) -> WizardBeforeRecord {
        WizardBeforeRecord(timelineID: row["timeline_id"]?.intValue ?? 0,
                           runUUID: row["run_uuid"]?.stringValue ?? "", request: row["request"]?.stringValue ?? "",
                           createdAt: row["created_at"]?.stringValue ?? "",
                           documentJSON: row["document_json"]?.stringValue ?? "",
                           appliedRevision: Int(row["applied_revision"]?.intValue ?? 0))
    }
}
