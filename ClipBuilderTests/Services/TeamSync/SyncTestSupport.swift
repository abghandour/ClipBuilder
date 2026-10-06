import Foundation
@testable import Clip_Builder

/// Two independent profile folders, never the user's Documents tree.
nonisolated final class SyncTestFolder: Sendable {
    let url: URL
    let database: Database

    init() throws {
        url = URL(fileURLWithPath: "/private/tmp/ClipBuilderSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        database = try Database(path: url.appendingPathComponent("profile.db"))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A PostgREST-shaped server double. Exercises the real client's HTTP requests,
/// JSON, scoping, upsert and keyset filters; it is not an alternate sync engine.
actor StubSyncServer {
    var rows: [String: SyncMapping.WireRow] = [:]
    var version = 2
    var offline = false
    var clock = 0
    var requests: [URLRequest] = []
    var afterPush: (@Sendable () async throws -> Void)?
    var beforePull: (@Sendable () async throws -> Void)?
    var beforePullTable = "wizard_lessons"

    func setVersion(_ value: Int) { version = value }
    func setOffline(_ value: Bool) { offline = value }
    func onNextPush(_ body: @escaping @Sendable () async throws -> Void) { afterPush = body }
    func onNextPull(table: String = "wizard_lessons", _ body: @escaping @Sendable () async throws -> Void) {
        beforePullTable = table
        beforePull = body
    }
    func allRows(table: String = "wizard_lessons") -> [SyncMapping.WireRow] { rows.filter { $0.key.hasPrefix(table + ":") }.map(\.value) }
    func capturedRequests() -> [URLRequest] { requests }

    func seed(_ row: SyncMapping.WireRow, table: String = "wizard_lessons") throws {
        var row = row
        clock += 1
        row["server_updated_at"] = .string(String(format: "2026-10-06T00:00:00.%06d+00:00", clock))
        row["updated_by"] = .string("00000000-0000-0000-0000-000000000001")
        if SyncMapping.isDeleted(row) { row["deleted_at"] = row["server_updated_at"] }
        guard let id = row["sync_id"]?.string else { throw SyncError.invalidRow("stub id") }
        rows[table + ":" + id] = row
    }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if url.path.hasSuffix("/otp") { return (Data("{}".utf8), response) }
        if url.path.hasSuffix("/verify") || url.path.hasSuffix("/token") {
            return (Data(#"{"access_token":"test-session","refresh_token":"test-refresh","expires_in":3600}"#.utf8), response)
        }
        if url.path.hasSuffix("/schema_version") {
            return (try JSONEncoder().encode([["version": version]]), response)
        }
        let table = url.lastPathComponent
        guard SyncTable.all.contains(where: { $0.name == table }) else { throw SyncError.invalidRow("stub route") }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        if request.httpMethod == "POST" {
            guard query["on_conflict"] == "sync_id",
                  request.value(forHTTPHeaderField: "Prefer")?.contains("resolution=merge-duplicates") == true else {
                throw SyncError.invalidRow("upsert request")
            }
            let batch = try JSONDecoder().decode([SyncMapping.WireRow].self, from: request.httpBody!)
            guard let first = batch.first, batch.allSatisfy({ Set($0.keys) == Set(first.keys) }) else {
                throw SyncError.invalidRow("batch keys")
            }
            for row in batch { try seed(row, table: table) }
            let callback = table == "wizard_lessons" ? afterPush : nil
            if table == "wizard_lessons" { afterPush = nil }
            try await callback?()
            return (Data(), response)
        }
        let callback = table == beforePullTable ? beforePull : nil
        if table == beforePullTable { beforePull = nil }
        try await callback?()
        guard query["order"] == "server_updated_at.asc,sync_id.asc" else {
            throw SyncError.invalidRow("pull order")
        }
        var result = allRows(table: table).filter {
            "eq.\($0["team_id"]?.string ?? "")" == query["team_id"] &&
            "eq.\($0["profile_id"]?.string ?? "")" == query["profile_id"]
        }.sorted {
            let left = ($0["server_updated_at"]!.string!, $0["sync_id"]!.string!)
            let right = ($1["server_updated_at"]!.string!, $1["sync_id"]!.string!)
            return left < right
        }
        if let filter = query["or"] {
            let timestamp = String(filter.components(separatedBy: "server_updated_at.gt.")[1].split(separator: ",")[0])
            let id = String(filter.components(separatedBy: "sync_id.gt.")[1].prefix(36))
            result = result.filter { ($0["server_updated_at"]!.string!, $0["sync_id"]!.string!) > (timestamp, id) }
        }
        result = Array(result.prefix(Int(query["limit"] ?? "200") ?? 200))
        return (try JSONEncoder().encode(result), response)
    }

    nonisolated func client() -> SupabaseClient {
        SupabaseClient(baseURL: URL(string: "https://sync.invalid")!, apiKey: "test-anon", accessToken: "test-user") {
            try await self.handle($0)
        }
    }
}

/// Fixtures exercise the actual local schemas, including composite primary keys,
/// non-integer IDs, REAL values, and embedded local IDs in outcome JSON.
nonisolated enum BrandSyncFixtures {
    static func seed(_ db: SQLiteConnection, includeDocument: Bool = true) throws {
        for table in SyncTable.all {
            if table.name == "profile_documents" && !includeDocument { continue }
            let info = try db.query("PRAGMA table_info(\(table.name))")
            var columns = table.columns.filter { column in info.contains { $0["name"]?.stringValue == column } }
            var values: SQLRow = [:]
            for column in columns {
                if table.references[column] != nil { values[column] = .integer(1) }
                else if table.integers.contains(column) { values[column] = .integer(1) }
                else if table.reals.contains(column) { values[column] = .real(1.25) }
                else { values[column] = .text(column.hasSuffix("_json") ? "{}" : "sample-\(column)") }
            }
            if table.name == "library_asset_metadata" {
                columns.append("path")
                values["path"] = .text("/private/tmp/team-sync-asset.png")
                values["kind"] = .text("images")
                values["asset_id"] = .text("fixture-asset")
            }
            if table.name == "ig_accounts" { values["username"] = .text("brand"); values["kind"] = .text("own") }
            if table.name == "reel_traits" { values["video_kind"] = .text("imported"); values["video_id"] = .text("1") }
            if table.name == "reel_outcomes" {
                values["video_id"] = .text("1")
                values["outcome_json"] = .text(#"{"accountID":1,"videoID":"1","raw":{"views":300}}"#)
            }
            let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute("INSERT INTO \(table.name)(\(quoted)) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))", columns.map { values[$0] ?? .null })
        }
    }
}
