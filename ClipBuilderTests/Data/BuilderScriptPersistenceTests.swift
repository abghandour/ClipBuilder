import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder script persistence")
struct BuilderScriptPersistenceTests {
    private func source(_ name: String = "Saved") -> String {
        "/** clipbuilder-script\n{\"name\":\"\(name)\",\"description\":\"Fixture\",\"mode\":\"edit\",\"params\":[],\"requires\":[]}\n*/\nreturn;"
    }

    @Test func freshSaveAtomicMetadataAndReopen() async throws {
        let temp = try TempDatabase()
        let saved = try await temp.database.saveBuilderScript(source: source(), origin: .ai)
        #expect(saved.origin == .ai)
        #expect(saved.paramsJSON == "[]")
        #expect((try? Date(saved.createdAt, strategy: .iso8601)) != nil)
        do {
            _ = try await temp.database.saveBuilderScript(source: "/** clipbuilder-script {broken} */", id: saved.id)
            Issue.record("Malformed headers must not save")
        } catch {}
        let unchanged = try await temp.database.fetchBuilderScripts()
        #expect(unchanged == [saved])
        let renamed = source("Renamed").replacingOccurrences(of: "\"params\":[]", with: "\"params\":[{\"name\":\"n\",\"type\":\"number\",\"default\":2}]")
        let updated = try await temp.database.saveBuilderScript(source: renamed, id: saved.id)
        #expect(updated.name == "Renamed")
        #expect(updated.paramsJSON.contains("\"n\""))
        #expect(updated.source == renamed)
        #expect(updated.origin == .ai)
        #expect(updated.createdAt == saved.createdAt)
        // Reopen the same WAL database; never copy only the main file.
        let reopened = try Database(path: temp.path)
        let rows = try await reopened.fetchBuilderScripts()
        #expect(rows == [updated])
        let duplicate = try await reopened.duplicateBuilderScript(id: saved.id)
        #expect(duplicate.id != saved.id)
        #expect(duplicate.source == updated.source)
        let file = temp.directory.url.appendingPathComponent("script.js")
        try await reopened.exportBuilderScript(id: saved.id, to: file)
        let imported = try await reopened.importBuilderScript(from: file)
        #expect(imported.id != saved.id && imported.id != duplicate.id)
        #expect(imported.source == updated.source)
        try await reopened.deleteBuilderScript(id: duplicate.id)
        let remaining = try await reopened.fetchBuilderScripts()
        #expect(remaining.count == 2)
    }

    @Test(arguments: [14, 12, 0]) func upgrade(version: Int) async throws {
        let temp = try TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("DROP TABLE builder_scripts")
        try raw.execute("PRAGMA user_version = \(version)")
        let reopened = try Database(path: temp.path)
        let record = try await reopened.saveBuilderScript(source: source())
        let again = try Database(path: temp.path)
        let rows = try await again.fetchBuilderScripts()
        #expect(rows == [record])
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == 15)
        #expect(try raw.query("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_builder_scripts_updated'").count == 1)
    }

    @Test func constraintsAndHostValidation() async throws {
        let temp = try TempDatabase()
        let record = try await temp.database.saveBuilderScript(source: source())
        let raw = try SQLiteConnection(path: temp.path.path)
        for sql in ["name='  '", "mode='other'", "origin='other'", "last_run_status='other'",
                    "id=NULL", "name=NULL", "description=NULL", "source=NULL", "params_json=NULL",
                    "requires_json=NULL", "mode=NULL", "origin=NULL", "created_at=NULL", "updated_at=NULL"] {
            #expect(throws: (any Error).self) { try raw.execute("UPDATE builder_scripts SET " + sql) }
        }
        do {
            _ = try await temp.database.saveBuilderScript(source: source() + String(repeating: " ", count: 256 * 1024))
            Issue.record("Oversized source must fail")
        } catch {}
        try await temp.database.markBuilderScriptRun(id: record.id, status: .completed)
        let rows = try await temp.database.fetchBuilderScripts()
        #expect(rows.first?.lastRunStatus == "completed")
        let timestamp = try #require(rows.first?.lastRunAt)
        #expect((try? Date(timestamp, strategy: .iso8601)) != nil)
    }
}
