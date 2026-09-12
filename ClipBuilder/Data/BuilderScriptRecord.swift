import Foundation

nonisolated struct BuilderScriptRecord: Identifiable, Sendable, Equatable {
    enum Origin: String, Sendable { case human, ai, app }
    let id: UUID
    let name: String
    let description: String
    let source: String
    let paramsJSON: String
    let requiresJSON: String
    let mode: String
    let origin: Origin
    let createdAt: String
    let updatedAt: String
    let lastRunAt: String?
    let lastRunStatus: String?
}

nonisolated enum BuilderScriptPersistence {
    static let schema = """
        CREATE TABLE IF NOT EXISTS builder_scripts (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL CHECK(length(trim(name)) > 0),
            description TEXT NOT NULL, source TEXT NOT NULL,
            params_json TEXT NOT NULL, requires_json TEXT NOT NULL,
            mode TEXT NOT NULL CHECK(mode IN ('edit','find')),
            origin TEXT NOT NULL CHECK(origin IN ('human','ai','app')),
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            last_run_at TEXT,
            last_run_status TEXT CHECK(last_run_status IS NULL OR last_run_status IN
                ('completed','applied','failed','discarded','reverted'))
        );
        CREATE INDEX IF NOT EXISTS idx_builder_scripts_updated ON builder_scripts(updated_at DESC,id);
        """

    static func read(_ row: SQLRow) throws -> BuilderScriptRecord {
        func text(_ key: String) throws -> String {
            guard let value = row[key]?.stringValue else { throw ScriptError.invalid("Missing script field: " + key) }
            return value
        }
        guard let id = UUID(uuidString: try text("id")),
              let origin = BuilderScriptRecord.Origin(rawValue: try text("origin")) else {
            throw ScriptError.invalid("Invalid stored script identity.")
        }
        return try .init(id: id, name: text("name"), description: text("description"), source: text("source"),
            paramsJSON: text("params_json"), requiresJSON: text("requires_json"), mode: text("mode"), origin: origin,
            createdAt: text("created_at"), updatedAt: text("updated_at"),
            lastRunAt: row["last_run_at"]?.stringValue, lastRunStatus: row["last_run_status"]?.stringValue)
    }
}
