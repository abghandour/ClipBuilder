import Foundation
import Testing
@testable import Clip_Builder

struct SyncEngineTests {
    private func engine(_ folder: SyncTestFolder, _ server: StubSyncServer, _ scope: SyncScope) -> SyncEngine {
        SyncEngine(database: folder.database, client: server.client(), scope: scope, batchSize: 1)
    }

    @Test("Two data folders converge through REST, remap ids, page cursors and never echo pulls")
    func roundTrip() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder()
        let server = StubSyncServer(), scope = SyncScope(teamID: UUID(), profileID: UUID())
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        let originalID = try await a.database.addLesson(text: "Shared", pinned: true, evidence: "A")
        _ = try await b.database.addLesson(text: "Existing B", pinned: true, evidence: "B")
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        let fromA = try await a.database.fetchLessons(), fromB = try await b.database.fetchLessons()
        #expect(Set(fromA.map(\.text)) == Set(fromB.map(\.text)))
        #expect(fromB.first { $0.text == "Shared" }?.id != originalID)
        #expect(try await a.database.syncPendingCount() == 0)
        #expect(try await b.database.syncPendingCount() == 0)
        let cursor = try await b.database.syncCursor()
        #expect(cursor != nil)
        // A new engine uses the durable cursor; empty pulls leave it unchanged.
        try await engine(b, server, scope).sync()
        #expect(try await b.database.syncCursor() == cursor)
        let requests = await server.capturedRequests()
        #expect(requests.contains { $0.url!.absoluteString.contains("%2B") })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "apikey") == "test-anon" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-user" })
    }

    @Test("Offline edits on both Macs converge with the last server write winning")
    func offlineEdits() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder()
        let server = StubSyncServer(), scope = SyncScope(teamID: UUID(), profileID: UUID())
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        let id = try await a.database.addLesson(text: "Original", pinned: true, evidence: "")
        try await ea.sync()
        try await eb.sync()
        let bid = try #require(try await b.database.fetchLessons().first?.id)
        await server.setOffline(true)
        try await a.database.updateLesson(id: id, text: "A edit", pinned: true)
        try await b.database.updateLesson(id: bid, text: "B edit", pinned: true)
        _ = try await a.database.addLesson(text: "Only A", pinned: false, evidence: "")
        _ = try await b.database.addLesson(text: "Only B", pinned: false, evidence: "")
        await #expect(throws: URLError.self) { try await ea.sync() }
        #expect(await ea.status == .offline(pending: 2))
        await server.setOffline(false)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        let expected: Set<String> = ["B edit", "Only A", "Only B"]
        #expect(Set(try await a.database.fetchLessons().map(\.text)) == expected)
        #expect(Set(try await b.database.fetchLessons().map(\.text)) == expected)
        #expect(try await b.database.syncPendingCount() == 0)
    }

    @Test("Deletes become tombstones, remove the remote row, and are not echoed")
    func tombstone() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder()
        let server = StubSyncServer(), scope = SyncScope(teamID: UUID(), profileID: UUID())
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        let id = try await a.database.addLesson(text: "Delete me", pinned: true, evidence: "")
        try await ea.sync()
        try await eb.sync()
        try await a.database.deleteLesson(id: id)
        try await ea.sync()
        try await eb.sync()
        #expect(try await b.database.fetchLessons().isEmpty)
        #expect(try await b.database.syncPendingCount() == 0)
        #expect(await server.allRows().filter { SyncMapping.isDeleted($0) }.count == 1)
        // Deleting before the first push also creates a tombstone successfully.
        let unsent = try await a.database.addLesson(text: "Never sent", pinned: false, evidence: "")
        try await a.database.deleteLesson(id: unsent)
        try await ea.sync()
        #expect(await server.allRows().count == 2)
    }

    @Test("A newer server schema stops before any local rows, outbox, binding or cursor change")
    func schemaGate() async throws {
        let a = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        _ = try await a.database.addLesson(text: "Local", pinned: true, evidence: "")
        let raw = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let before = try raw.query("SELECT sequence FROM sync_outbox").compactMap { $0["sequence"]?.intValue }
        await server.setVersion(2)
        let sync = engine(a, server, scope)
        await #expect(throws: SyncError.needsUpdate(2)) { try await sync.sync() }
        #expect(await sync.status == .needsUpdate(serverVersion: 2))
        #expect(try raw.query("SELECT sequence FROM sync_outbox").compactMap { $0["sequence"]?.intValue } == before)
        #expect(try raw.query("SELECT * FROM sync_binding").isEmpty)
        #expect(try raw.query("SELECT * FROM sync_cursors").isEmpty)
        #expect(try raw.query("SELECT text FROM wizard_lessons").first?["text"]?.stringValue == "Local")
        #expect(await server.capturedRequests().count == 1)
    }

    @Test("Edits while a push is in flight survive its acknowledgement")
    func inFlightPush() async throws {
        let a = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let id = try await a.database.addLesson(text: "Before", pinned: true, evidence: "")
        await server.onNextPush {
            try await a.database.updateLesson(id: id, text: "During HTTP", pinned: true)
        }
        try await engine(a, server, scope).sync()
        #expect(await server.allRows().first?["text"]?.string == "During HTTP")
        #expect(try await a.database.fetchLessons().first?.text == "During HTTP")
        #expect(try await a.database.syncPendingCount() == 0)
    }

    @Test("Edits while a pull is in flight are kept and pushed next time")
    func inFlightPull() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let id = try await a.database.addLesson(text: "Before", pinned: true, evidence: "")
        let ea = engine(a, server, scope)
        try await ea.sync()
        let eb = engine(b, server, scope)
        try await eb.sync()
        let bid = try #require(try await b.database.fetchLessons().first?.id)
        try await b.database.updateLesson(id: bid, text: "Remote", pinned: true)
        try await eb.sync()
        await server.onNextPull {
            try await a.database.updateLesson(id: id, text: "During pull", pinned: true)
        }
        try await ea.sync()
        #expect(try await a.database.fetchLessons().first?.text == "During pull")
        #expect(try await a.database.syncPendingCount() == 1)
        #expect(await ea.status == .pending(changes: 1))
        try await ea.sync()
        try await eb.sync()
        #expect(try await b.database.fetchLessons().first?.text == "During pull")
    }

    @Test("Unknown nested wire fields survive storage, reopening and a local edit")
    func unknownFields() async throws {
        let a = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let future: SyncJSON = .object(["nested": .array([.number(3), .bool(false)])])
        var wire = try SyncMapping.wire(local: ["text": .text("Future"), "pinned": .integer(0), "evidence": .text("")],
                                       syncID: UUID().uuidString, scope: scope)
        wire["future_column"] = future
        try await server.seed(wire)
        try await engine(a, server, scope).sync()
        let reopened = try Database(path: a.url.appendingPathComponent("profile.db"))
        let id = try #require(try await reopened.fetchLessons().first?.id)
        try await reopened.updateLesson(id: id, text: "Edited", pinned: true)
        try await SyncEngine(database: reopened, client: server.client(), scope: scope).sync()
        #expect(await server.allRows().first?["future_column"] == future)
        #expect(await server.allRows().first?["text"]?.string == "Edited")
    }

    @Test("A malformed batch rolls back rows, cursor, unknown fields and suppression")
    func atomicApply() async throws {
        let a = try SyncTestFolder()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var good = try SyncMapping.wire(local: ["text": .text("Good"), "pinned": .integer(0), "evidence": .text("")],
                                       syncID: UUID().uuidString, scope: scope)
        good["server_updated_at"] = .string("2026-10-06T00:00:00.000001+00:00")
        var bad = good
        bad["sync_id"] = .string(UUID().uuidString.lowercased())
        bad["text"] = .array([])
        await #expect(throws: SyncError.self) { try await a.database.applySyncRows([good, bad], scope: scope) }
        #expect(try await a.database.fetchLessons().isEmpty)
        #expect(try await a.database.syncCursor() == nil)
        let raw = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        #expect(try raw.query("SELECT * FROM sync_wire_rows").isEmpty)
        _ = try await a.database.addLesson(text: "Captured", pinned: true, evidence: "")
        #expect(try await a.database.syncPendingCount() == 1)
    }

    @Test("Email OTP sends a code, verifies it and refreshes through auth endpoints")
    func emailCode() async throws {
        let server = StubSyncServer(), client = server.client()
        try await client.sendEmailCode(to: "member@example.com")
        let session = try await client.verifyEmailCode(email: "member@example.com", code: "123456")
        #expect(session.access_token == "test-session")
        _ = try await client.refreshSession(refreshToken: try #require(session.refresh_token))
        let requests = await server.capturedRequests()
        #expect(requests.map { $0.url!.path } == ["/auth/v1/otp", "/auth/v1/verify", "/auth/v1/token"])
        let verify = try JSONDecoder().decode(SyncMapping.WireRow.self, from: requests[1].httpBody!)
        #expect(verify == ["email": .string("member@example.com"), "token": .string("123456"), "type": .string("email")])
    }
}
