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
        await server.setVersion(4)
        let sync = engine(a, server, scope)
        await #expect(throws: SyncError.needsUpdate(4)) { try await sync.sync() }
        #expect(await sync.status == .needsUpdate(serverVersion: 4))
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
        try await a.database.bindSync(to: scope)
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

extension SyncEngineTests {
    @Test("Every brand table converges with remapped references, independent cursors and no pull echo")
    func brandTables() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        try BrandSyncFixtures.seed(rawA)
        try rawA.execute("UPDATE sync_control SET suspended = 1")
        try rawA.execute("UPDATE profile_documents SET sync_id = ?", [.text(scope.profileID.uuidString.lowercased())])
        try rawA.execute("DELETE FROM sync_outbox WHERE \"table\" = 'profile_documents'")
        try rawA.execute("UPDATE sync_control SET suspended = 0")
        // Reserve different integer sequences without creating pending rows.
        try rawB.executeScript("""
            UPDATE sync_control SET suspended = 1;
            INSERT INTO ig_accounts(id, username) VALUES (99, 'unrelated');
            INSERT INTO ig_media(id, account_id, media_id) VALUES (99, 99, 'other');
            INSERT INTO ig_report_media(id, account_id, shortcode) VALUES (99, 99, 'other');
            UPDATE sync_control SET suspended = 0;
            """)
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        for table in SyncTable.all {
            let remote = await server.allRows(table: table.name)
            #expect(!remote.isEmpty, "Missing \(table.name)")
            #expect(try await b.database.syncCursor(table: table) != nil)
            for row in remote where !SyncMapping.isDeleted(row) {
                let id = try #require(row["sync_id"]?.string)
                #expect(try !rawB.query("SELECT 1 FROM \(table.name) WHERE sync_id = ?", [.text(id)]).isEmpty)
            }
        }
        let account = try #require(try rawB.query("SELECT id FROM ig_accounts WHERE username = 'brand'").first?["id"]?.intValue)
        #expect(account != 1)
        #expect(try rawB.query("SELECT account_id FROM ig_media WHERE media_id = 'sample-media_id'").first?["account_id"]?.intValue == account)
        let outcome = try #require(try rawB.query("SELECT outcome_json FROM reel_outcomes").first?["outcome_json"]?.stringValue)
        let object = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(outcome.utf8))
        #expect(object["accountID"] == .number(Decimal(account)))
        #expect(try await b.database.syncPendingCount() == 0)
        #expect(try rawB.query("PRAGMA foreign_key_check").isEmpty)
    }

    @Test("Joining merges natural keys while preserving local integer IDs and media paths")
    func naturalKeyJoin() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        try rawA.executeScript("""
            INSERT INTO people(id, key, name) VALUES (1, 'person', 'A');
            INSERT INTO ig_accounts(id, username) VALUES (1, 'Brand');
            INSERT INTO ig_media(id, account_id, media_id, local_video_path) VALUES (1, 1, 'media', '/private/a.mov');
            """)
        try rawB.executeScript("""
            INSERT INTO people(id, key, name) VALUES (44, 'person', 'B');
            INSERT INTO ig_accounts(id, username) VALUES (55, 'brand');
            INSERT INTO ig_media(id, account_id, media_id, local_video_path) VALUES (66, 55, 'media', '/private/b.mov');
            """)
        try await engine(a, server, scope).sync()
        try await engine(b, server, scope).sync()
        try await engine(a, server, scope).sync()
        #expect(try rawB.query("SELECT id FROM people").first?["id"]?.intValue == 44)
        #expect(try rawB.query("SELECT id FROM ig_accounts").first?["id"]?.intValue == 55)
        #expect(try rawB.query("SELECT id FROM ig_media").first?["id"]?.intValue == 66)
        #expect(try rawB.query("SELECT local_video_path FROM ig_media").first?["local_video_path"]?.stringValue == "/private/b.mov")
        for name in ["people", "ig_accounts", "ig_media"] {
            #expect(await server.allRows(table: name).count == 1)
            #expect(try rawB.query("SELECT * FROM \(name)").count == 1)
        }
        #expect(try rawA.query("SELECT name FROM people").first?["name"]?.stringValue == "A")
        #expect(try rawB.query("SELECT name FROM people").first?["name"]?.stringValue == "A")
    }
}

extension SyncEngineTests {
    @Test("Joining keeps the shared profile and natural-key values, and uploads only unmatched local rows")
    func serverWinsInitialJoin() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var owner = BrandProfile(name: "Owner")
        owner.teamID = scope.teamID
        owner.profileID = scope.profileID
        owner.houseStyle = "Team style"
        var joiner = owner
        joiner.houseStyle = "Local style"
        joiner.sourceFolder = "/private/tmp/joiner-footage"
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        try rawA.execute("INSERT INTO people(key, name) VALUES ('match', 'Shared name')")
        try rawB.execute("INSERT INTO people(key, name) VALUES ('match', 'Local name'), ('unique', 'Only here')")
        try await a.database.bindSync(to: scope)
        try await a.database.saveSyncProfile(owner)
        try await engine(a, server, scope).sync()
        try await b.database.bindSync(to: scope)
        try await b.database.saveSyncProfile(joiner)
        // Fail after downloading the document. A fresh engine must resume the
        // server-first join without re-uploading the UI's stale local document.
        await server.onNextPull { throw URLError(.networkConnectionLost) }
        await #expect(throws: URLError.self) { try await self.engine(b, server, scope).sync() }
        #expect(try await b.database.initialSyncPending())
        let reopened = try Database(path: b.url.appendingPathComponent("profile.db"))
        try await reopened.saveSyncProfile(joiner)
        try await SyncEngine(database: reopened, client: server.client(), scope: scope).sync()
        let document = try #require(try await reopened.syncedProfileDocument())
        let applied = try TeamProfileDocument.applying(document, to: joiner)
        #expect(applied.houseStyle == "Team style")
        #expect(applied.sourceFolder == joiner.sourceFolder)
        #expect(try rawB.query("SELECT name FROM people WHERE key = 'match'").first?["name"]?.stringValue == "Shared name")
        let remotePeople = await server.allRows(table: "people")
        #expect(Set(remotePeople.compactMap { $0["name"]?.string }) == ["Shared name", "Only here"])
        let remoteProfile = try #require(await server.allRows(table: "profile_documents").first?["document_json"]?.string)
        #expect(try TeamProfileDocument.applying(remoteProfile, to: owner).houseStyle == "Team style")
        #expect(try await reopened.syncPendingCount() == 0)
        #expect(try await reopened.initialSyncPending())
        try JSONEncoder().encode(applied).write(to: b.url.appendingPathComponent("saved-profile.json"), options: .atomic)
        try await reopened.completeSyncProfileAdoption(applied)
        #expect(try await !reopened.initialSyncPending())
    }

    @Test("Pruned media and account cascades leave harmless soft-reference orphans")
    func orphanedBrandReferences() async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        try raw.execute("PRAGMA foreign_keys = ON")
        try raw.executeScript("""
            INSERT INTO ig_accounts(id, username) VALUES (1, 'brand');
            INSERT INTO ig_media(id, account_id, media_id) VALUES (1, 1, 'pruned');
            INSERT INTO ig_report_media(id, account_id, shortcode) VALUES (1, 1, 'cascade');
            INSERT INTO reel_traits(video_kind, video_id, version, traits_json, computed_at) VALUES
                ('instagram', '1', 1, '{}', '2026-10-06'), ('imported', '1', 1, '{}', '2026-10-06');
            INSERT INTO taste_studies(media_id, category_key, studied_at) VALUES (1, 'fight', '2026-10-06');
            DELETE FROM ig_media;
            DELETE FROM ig_accounts;
            """)
        // These were written before attachment and have random legacy IDs.
        let sync = engine(folder, server, scope)
        try await sync.sync()
        #expect(await sync.status == .synced)
        #expect(await server.allRows(table: "reel_traits").isEmpty)
        #expect(await server.allRows(table: "taste_studies").isEmpty)
        #expect(try await folder.database.syncPendingCount() == 0)
        // Repeated writes to the orphaned caches cannot poison later cycles.
        try raw.execute("UPDATE reel_traits SET version = 2")
        try raw.execute("UPDATE taste_studies SET category_key = 'new'")
        try await sync.sync()
        #expect(await sync.status == .synced)
        #expect(try await folder.database.syncPendingCount() == 0)
    }

    @Test("Local-only traits created during HTTP cannot upload or overwrite local caches on pull")
    func localOnlyTraitsDuringUpload() async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let sync = engine(folder, server, scope)
        try await sync.sync()
        _ = try await folder.database.addLesson(text: "Trigger upload", pinned: false, evidence: "")
        let dbPath = folder.url.appendingPathComponent("profile.db").path
        let localID = UUID().uuidString.lowercased()
        await server.onNextPush {
            let raw = try SQLiteConnection(path: dbPath)
            try raw.execute("INSERT INTO reel_traits(video_kind, video_id, version, traits_json, computed_at, sync_id) VALUES ('generated', '42', 1, '{}', '2026-10-06', ?)", [.text(localID)])
            // Simulate an old client's already-queued row as well as current triggers.
            try raw.execute("INSERT INTO sync_outbox(\"table\", sync_id, op) VALUES ('reel_traits', ?, 'upsert')", [.text(localID)])
            try raw.execute("INSERT INTO sync_outbox(\"table\", sync_id, op) VALUES ('reel_traits', ?, 'delete')", [.text(UUID().uuidString.lowercased())])
            try raw.execute("INSERT INTO reel_traits(video_kind, video_id, version, traits_json, computed_at) VALUES ('external', 'portable-reference', 1, '{}', '2026-10-06')")
        }
        try await sync.sync()
        let uploaded = await server.allRows(table: "reel_traits")
        #expect(uploaded.count == 1)
        #expect(uploaded.first?["video_kind"]?.string == "external")
        let table = try SyncTable.named("reel_traits")
        var invalid = try SyncMapping.wire(local: ["video_kind": .text("generated"), "video_id": .text("42"),
            "version": .integer(2), "traits_json": .text("{}"), "computed_at": .text("2026-10-06"), "reference": .integer(0)],
            syncID: localID, scope: scope, table: table)
        try await server.seed(invalid, table: table.name)
        try await sync.sync()
        let raw = try SQLiteConnection(path: dbPath)
        #expect(try raw.query("SELECT version FROM reel_traits WHERE sync_id = ?", [.text(localID)]).first?["version"]?.intValue == 1)
        // A malicious portable kind or a tombstone with the same ID also cannot touch it.
        invalid["video_kind"] = .string("external")
        try await server.seed(invalid, table: table.name)
        try await sync.sync()
        try await server.seed(SyncMapping.wire(local: nil, syncID: localID, scope: scope, table: table), table: table.name)
        try await sync.sync()
        #expect(try raw.query("SELECT video_kind FROM reel_traits WHERE sync_id = ?", [.text(localID)]).first?["video_kind"]?.stringValue == "generated")
        #expect(try await folder.database.syncPendingCount() == 0)
    }

    @Test("Uploads use table batches and acknowledgements preserve edits made during the POST")
    func batchedUploads() async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var ids: [Int64] = []
        for index in 0..<5 {
            ids.append(try await folder.database.addLesson(text: "Lesson \(index)", pinned: false, evidence: ""))
        }
        let editedID = ids[0]
        await server.onNextPush {
            try await folder.database.updateLesson(id: editedID, text: "During batch", pinned: true)
        }
        let sync = SyncEngine(database: folder.database, client: server.client(), scope: scope, batchSize: 3)
        try await sync.sync()
        let posts = await server.capturedRequests().filter { $0.httpMethod == "POST" }
        let sizes = try posts.map { try JSONDecoder().decode([SyncMapping.WireRow].self, from: $0.httpBody!).count }
        #expect(sizes == [3, 3])
        #expect(await server.allRows().contains { $0["text"]?.string == "During batch" })
        #expect(try await folder.database.syncPendingCount() == 0)
        // Pulling unchanged rows and server echoes causes no cache refresh.
        try await sync.sync()
        #expect(await sync.changedTables.isEmpty)
    }
}

extension SyncEngineTests {
    /// Exercise the same durable adoption boundary as TeamSyncState without
    /// starting AppStore's network monitors, user-data bootstrap or Keychain.
    private func adopt(_ current: BrandProfile, database: Database, folder: URL) async throws -> BrandProfile {
        let adoption = try #require(try await database.syncProfileAdoption())
        let merged = try TeamProfileDocument.merging(adoption.document, into: current, baseline: adoption.baseline)
        try JSONEncoder().encode(merged).write(to: folder.appendingPathComponent("saved-profile.json"), options: .atomic)
        try await database.completeSyncProfileAdoption(merged)
        return merged
    }

    @Test("Stop or quit around adoption never replaces the team's profile", arguments: [false, true])
    func interruptedProfileAdoption(adoptBeforeStop: Bool) async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var local = BrandProfile(name: "Joiner")
        local.teamID = scope.teamID
        local.profileID = scope.profileID
        local.houseStyle = "Local default"
        local.sourceFolder = "/private/tmp/local-footage"
        var shared = local
        shared.houseStyle = "Team style"
        let table = try SyncTable.named("profile_documents")
        try await server.seed(SyncMapping.wire(local: ["document_json": .text(TeamProfileDocument.encode(shared))],
            syncID: scope.profileID.uuidString.lowercased(), scope: scope, table: table), table: table.name)
        try await folder.database.bindSync(to: scope)
        try await folder.database.saveSyncProfile(local)
        try await engine(folder, server, scope).sync()
        #expect(try await folder.database.initialSyncPending())
        if adoptBeforeStop {
            local = try await adopt(local, database: folder.database, folder: folder.url)
            #expect(try await !folder.database.initialSyncPending())
        } else {
            // A failed disk save cannot acknowledge the adoption.
            let invalidFolder = folder.url.appendingPathComponent("missing-directory")
            await #expect(throws: (any Error).self) {
                _ = try await self.adopt(local, database: folder.database, folder: invalidFolder)
            }
            #expect(try await folder.database.initialSyncPending())
        }
        // The attach error handler's pause-save, followed by quit/relaunch.
        local.teamSyncPaused = true
        try await folder.database.saveSyncProfile(local)
        try JSONEncoder().encode(local).write(to: folder.url.appendingPathComponent("saved-profile.json"), options: .atomic)
        let reopened = try Database(path: folder.url.appendingPathComponent("profile.db"))
        let loaded = try JSONDecoder().decode(BrandProfile.self, from: Data(contentsOf: folder.url.appendingPathComponent("saved-profile.json")))
        try await reopened.saveSyncProfile(loaded)
        try await SyncEngine(database: reopened, client: server.client(), scope: scope).sync()
        let merged = try await adopt(loaded, database: reopened, folder: folder.url)
        #expect(merged.houseStyle == "Team style")
        #expect(merged.sourceFolder == local.sourceFolder)
        #expect(merged.teamSyncPaused == true)
        let remote = try #require(await server.allRows(table: table.name).first?["document_json"]?.string)
        #expect(try TeamProfileDocument.applying(remote, to: local).houseStyle == "Team style")
    }

    @Test("Edits during join and later pulls merge with the newer remote profile", arguments: [false, true])
    func concurrentProfileAdoption(alreadyJoined: Bool) async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var original = BrandProfile(name: "Joiner")
        original.teamID = scope.teamID
        original.profileID = scope.profileID
        original.houseStyle = "Old style"
        original.tagline = "Old tagline"
        try await folder.database.bindSync(to: scope)
        try await folder.database.saveSyncProfile(original)
        if alreadyJoined {
            try await engine(folder, server, scope).sync()
            _ = try await adopt(original, database: folder.database, folder: folder.url)
        }
        var shared = original
        shared.houseStyle = "New team style"
        let table = try SyncTable.named("profile_documents")
        try await server.seed(SyncMapping.wire(local: ["document_json": .text(TeamProfileDocument.encode(shared))],
            syncID: scope.profileID.uuidString.lowercased(), scope: scope, table: table), table: table.name)
        var edited = original
        edited.tagline = "Edited while pulling"
        edited.sourceFolder = "/private/tmp/new-local-folder"
        let current = edited
        await server.onNextPull {
            // This save used to replace the pulled document or cause the store
            // to skip adoption because its snapshot no longer matched.
            try await folder.database.saveSyncProfile(current)
        }
        try await engine(folder, server, scope).sync()
        let merged = try await adopt(edited, database: folder.database, folder: folder.url)
        #expect(merged.houseStyle == "New team style")
        #expect(merged.tagline == edited.tagline)
        #expect(merged.sourceFolder == edited.sourceFolder)
        try await engine(folder, server, scope).sync()
        let remote = try #require(await server.allRows(table: table.name).first?["document_json"]?.string)
        let uploaded = try TeamProfileDocument.applying(remote, to: original)
        #expect(uploaded.houseStyle == "New team style")
        #expect(uploaded.tagline == edited.tagline)
    }

    @Test("A tombstoned profile completes adoption and re-uploads the local profile", arguments: [false, true])
    func tombstonedProfileAdoption(alreadyJoined: Bool) async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        var local = BrandProfile(name: "Local")
        local.teamID = scope.teamID
        local.profileID = scope.profileID
        local.houseStyle = "Keep this style"
        local.sourceFolder = "/private/tmp/local-footage"
        try await folder.database.bindSync(to: scope)
        try await folder.database.saveSyncProfile(local)
        if alreadyJoined {
            try await engine(folder, server, scope).sync()
            _ = try await adopt(local, database: folder.database, folder: folder.url)
        }
        let table = try SyncTable.named("profile_documents")
        try await server.seed(SyncMapping.wire(local: nil, syncID: scope.profileID.uuidString.lowercased(),
            scope: scope, table: table), table: table.name)
        try await engine(folder, server, scope).sync()
        #expect(try await folder.database.syncedProfileDocument() == nil)
        let adoption = try #require(try await folder.database.syncProfileAdoption())
        #expect(adoption.document == nil)

        // Stop, a failed profile save, and relaunch must leave recovery possible.
        local.tagline = "Edited after the tombstone"
        try await folder.database.saveSyncProfile(local)
        await #expect(throws: (any Error).self) {
            _ = try await self.adopt(local, database: folder.database,
                                     folder: folder.url.appendingPathComponent("missing-directory"))
        }
        #expect(try await folder.database.syncProfileAdoption() != nil)
        let reopened = try Database(path: folder.url.appendingPathComponent("profile.db"))
        let recovered = try await adopt(local, database: reopened, folder: folder.url)
        #expect(recovered.houseStyle == local.houseStyle)
        #expect(recovered.tagline == local.tagline)
        #expect(recovered.sourceFolder == local.sourceFolder)
        #expect(try await reopened.syncProfileAdoption() == nil)
        #expect(try await !reopened.initialSyncPending())
        #expect(try await reopened.syncedProfileDocument() != nil)
        #expect(try await reopened.syncPendingCount() == 1)

        let sync = SyncEngine(database: reopened, client: server.client(), scope: scope)
        try await sync.sync()
        _ = try await adopt(recovered, database: reopened, folder: folder.url)
        let uploaded = try #require(await server.allRows(table: table.name).first)
        #expect(!SyncMapping.isDeleted(uploaded))
        let document = try #require(uploaded["document_json"]?.string)
        #expect(try document == TeamProfileDocument.encode(recovered))
        #expect(try await reopened.syncPendingCount() == 0)

        // Future saves must no longer disappear behind the old baseline.
        var edited = recovered
        edited.houseStyle = "Edited after recovery"
        try await reopened.saveSyncProfile(edited)
        try await sync.sync()
        let updated = try #require(await server.allRows(table: table.name).first?["document_json"]?.string)
        #expect(try TeamProfileDocument.applying(updated, to: edited).houseStyle == edited.houseStyle)
        #expect(try await reopened.syncPendingCount() == 0)
    }

    @Test("Children arriving after the parent scan are parked and applied after reopening")
    func deferredParents() async throws {
        let source = try SyncTestFolder(), receiver = try SyncTestFolder()
        let sourceServer = StubSyncServer(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: source.url.appendingPathComponent("profile.db").path)
        try raw.executeScript("""
            INSERT INTO ig_accounts(id, username) VALUES (1, 'brand');
            INSERT INTO ig_media(id, account_id, media_id) VALUES (1, 1, 'late-media');
            INSERT INTO ig_report_media(id, account_id, shortcode) VALUES (1, 1, 'late-report');
            INSERT INTO taste_studies(media_id, category_key, studied_at) VALUES (1, 'fight', '2026-10-06');
            INSERT INTO reel_traits(video_kind, video_id, version, traits_json, computed_at) VALUES
                ('instagram', '1', 1, '{}', '2026-10-06'), ('imported', '1', 1, '{}', '2026-10-06');
            """)
        try await engine(source, sourceServer, scope).sync()
        for row in await sourceServer.allRows(table: "ig_accounts") { try await server.seed(row, table: "ig_accounts") }
        // Finish the empty join, so this is the single scan in an ordinary cycle.
        try await engine(receiver, server, scope).sync()
        await server.onNextPull(table: "taste_studies") {
            for name in ["ig_media", "ig_report_media", "taste_studies", "reel_traits"] {
                for row in await sourceServer.allRows(table: name) { try await server.seed(row, table: name) }
            }
        }
        try await engine(receiver, server, scope).sync()
        let receiverRaw = try SQLiteConnection(path: receiver.url.appendingPathComponent("profile.db").path)
        #expect(try receiverRaw.query("SELECT * FROM sync_pending_parents").count == 3)
        #expect(try receiverRaw.query("SELECT * FROM taste_studies").isEmpty)
        #expect(try receiverRaw.query("SELECT * FROM reel_traits").isEmpty)
        let studyTable = try SyncTable.named("taste_studies"), traitsTable = try SyncTable.named("reel_traits")
        let studyCursor = try await receiver.database.syncCursor(table: studyTable)
        let traitsCursor = try await receiver.database.syncCursor(table: traitsTable)
        #expect(studyCursor != nil && traitsCursor != nil)
        let reopened = try Database(path: receiver.url.appendingPathComponent("profile.db"))
        let sync = SyncEngine(database: reopened, client: server.client(), scope: scope)
        try await sync.sync()
        #expect(try receiverRaw.query("SELECT * FROM sync_pending_parents").isEmpty)
        #expect(try receiverRaw.query("SELECT * FROM taste_studies").count == 1)
        #expect(try receiverRaw.query("SELECT * FROM reel_traits").count == 2)
        #expect(try await reopened.syncCursor(table: studyTable) == studyCursor)
        #expect(try await reopened.syncCursor(table: traitsTable) == traitsCursor)
        #expect(try await reopened.syncPendingCount() == 0)
        #expect(await sync.changedTables.isSuperset(of: ["taste_studies", "reel_traits"]))
        try await sync.sync()
        #expect(await sync.changedTables.isEmpty)
    }

    @Test("A join preserves edits made after its initial sequence boundary, including retries", arguments: [false, true])
    func joinTimeRowEdit(interrupt: Bool) async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let table = try SyncTable.named("people")
        try await server.seed(SyncMapping.wire(local: ["key": .text("match"), "name": .text("Team name")],
            syncID: UUID().uuidString.lowercased(), scope: scope, table: table), table: table.name)
        let path = folder.url.appendingPathComponent("profile.db").path
        let raw = try SQLiteConnection(path: path)
        try raw.execute("INSERT INTO people(key, name) VALUES ('match', 'Old local')")
        await server.onNextPull {
            let connection = try SQLiteConnection(path: path)
            try connection.execute("UPDATE people SET name = 'Edited during join'")
            if interrupt { throw URLError(.networkConnectionLost) }
        }
        if interrupt {
            await #expect(throws: URLError.self) { try await self.engine(folder, server, scope).sync() }
        }
        let reopened = try Database(path: folder.url.appendingPathComponent("profile.db"))
        try await SyncEngine(database: reopened, client: server.client(), scope: scope).sync()
        #expect(try raw.query("SELECT name FROM people").first?["name"]?.stringValue == "Edited during join")
        #expect(await server.allRows(table: "people").first?["name"]?.string == "Edited during join")
        #expect(try await reopened.syncPendingCount() == 0)
    }

    @Test("Own JSON echoes ignore key order but genuine nested changes still refresh")
    func canonicalJSONEcho() async throws {
        let folder = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
        try raw.executeScript("""
            INSERT INTO ig_accounts(id, username) VALUES (1, 'brand');
            INSERT INTO ig_media(id, account_id, media_id, stats_json)
                VALUES (1, 1, 'media', '{"z":2,"a":{"second":2,"first":1}}');
            """)
        let sync = engine(folder, server, scope)
        try await sync.sync()
        #expect(await sync.changedTables.isEmpty)
        try raw.execute("UPDATE ig_media SET stats_json = '{\"z\":3,\"a\":{\"second\":2,\"first\":1}}'")
        try await sync.sync()
        #expect(await sync.changedTables.isEmpty)
        var remote = try #require(await server.allRows(table: "ig_media").first)
        remote["stats_json"] = .string("{\"a\":{\"first\":99,\"second\":2},\"z\":3}")
        try await server.seed(remote, table: "ig_media")
        try await sync.sync()
        #expect(await sync.changedTables.contains("ig_media"))
    }
}

extension SyncEngineTests {
    @Test("Two Macs analyzing identical footage in the same second keep both runs and scenes")
    func footageRunsConverge() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        for (raw, id, path) in [(rawA, 10, "/private/tmp/mac-a.mov"), (rawB, 90, "/private/tmp/mac-b.mov")] {
            try raw.execute("INSERT INTO videos(id, hash, filename, path) VALUES (?, 'same-footage', 'Fight.mov', ?)", [.integer(Int64(id)), .text(path)])
            try raw.execute("""
                INSERT INTO analysis_runs(id, video_id, name, created_at)
                VALUES (?, ?, 'Same name', '2026-10-07 12:00:00')
                """, [.integer(Int64(id)), .integer(Int64(id))])
            try raw.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) VALUES (?, ?, 0, 10)", [.integer(Int64(id)), .integer(Int64(id))])
        }
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        try await eb.sync()
        for raw in [rawA, rawB] {
            #expect(try raw.query("SELECT * FROM videos").count == 1)
            #expect(try raw.query("SELECT * FROM analysis_runs").count == 2)
            #expect(try raw.query("SELECT * FROM scenes").count == 2)
            #expect(try raw.query("PRAGMA foreign_key_check").isEmpty)
        }
        #expect(try rawA.query("SELECT path FROM videos").first?["path"]?.stringValue == "/private/tmp/mac-a.mov")
        #expect(try rawB.query("SELECT path FROM videos").first?["path"]?.stringValue == "/private/tmp/mac-b.mov")
        let firstA = try #require(try await a.database.fetchAnalysisRuns().first)
        let firstB = try #require(try await b.database.fetchAnalysisRuns().first)
        let identityA = try rawA.query("SELECT sync_id FROM analysis_runs WHERE id = ?", [.integer(firstA.id)]).first?["sync_id"]?.stringValue
        let identityB = try rawB.query("SELECT sync_id FROM analysis_runs WHERE id = ?", [.integer(firstB.id)]).first?["sync_id"]?.stringValue
        #expect(identityA == identityB)
        #expect(try await a.database.syncPendingCount() == 0)
        #expect(try await b.database.syncPendingCount() == 0)
    }

    @Test("Footage arrives without a path; later hash import adopts its row and analysis")
    func footageBeforeFileAndImport() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        let file = b.url.appendingPathComponent("local.mov")
        try Data("identical footage fixture".utf8).write(to: file)
        let hash = try ContentHash.fingerprint(of: file)
        try rawA.execute("INSERT INTO videos(id, hash, filename, path, duration) VALUES (7, ?, 'Shared.mov', '/other-mac/secret.mov', 10)", [.text(hash)])
        try rawA.execute("INSERT INTO analysis_runs(id, video_id, name) VALUES (7, 7, 'Shared analysis')")
        try rawA.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) VALUES (7, 7, 0, 10)")
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        let missing = try #require(try await b.database.fetchVideos().first)
        #expect(missing.path == nil)
        #expect(!missing.isPresent)
        #expect(throws: CocoaError.self) { try missing.requirePresent() }
        let identity = try #require(try rawB.query("SELECT sync_id FROM videos").first?["sync_id"]?.stringValue)
        let scenes = try await b.database.fetchScenes()
        #expect(scenes.count == 1)
        #expect(scenes.first?.isPresent == false)
        var clip = TimelineClip()
        clip.sceneID = scenes.first?.id
        var document = TimelineDocument()
        document.videoTrack = [clip]
        #expect(FootageAvailability.missingSource(document: document, scenes: scenes) == "Shared.mov")
        let adopted = try await b.database.registerVideo(hash: hash, filename: file.lastPathComponent, path: file.path,
                                                         duration: 10, width: 1920, height: 1080, wide: true)
        #expect(adopted == missing.id)
        #expect(try await b.database.video(id: adopted)?.isPresent == true)
        #expect(try rawB.query("SELECT sync_id FROM videos").first?["sync_id"]?.stringValue == identity)
        #expect(try rawB.query("SELECT * FROM videos").count == 1)
        #expect(try await b.database.fetchScenes().first?.isPresent == true)
        try await eb.sync()
        #expect(await server.allRows(table: "videos").allSatisfy { $0["path"] == nil })
        try FileManager.default.removeItem(at: file)
        #expect(try await b.database.video(id: adopted)?.isPresent == false)
    }

    @Test("Scenes park until a missing run arrives, including nullable self and person references")
    func footageParkedParents() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        try raw.execute("INSERT INTO videos(id, hash, filename, path) VALUES (1, 'parked', 'Shared.mov', '/mac-a.mov')")
        try raw.execute("INSERT INTO analysis_runs(id, video_id, name) VALUES (1, 1, 'Run')")
        try raw.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) VALUES (1, 1, 0, 10)")
        try raw.execute("INSERT INTO person_markers(video_id, at_time, x, y, width, height) VALUES (1, 0, 0, 0, 1, 1)")
        try await a.database.bindSync(to: scope)
        try await a.database.canonicalizeSyncIdentities(scope: scope)
        var runs: [SyncMapping.WireRow] = []
        for name in ["videos", "analysis_runs", "scenes", "person_markers"] {
            let table = try SyncTable.named(name)
            let changes = try await a.database.pendingSyncChanges(scope: scope, limit: 200, table: table)
            for change in changes {
                if name == "analysis_runs" { runs.append(change.wire) }
                else { try await server.seed(change.wire, table: name) }
            }
        }
        let eb = engine(b, server, scope)
        try await eb.sync()
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        #expect(try rawB.query("SELECT * FROM scenes").isEmpty)
        #expect(try rawB.query("SELECT * FROM sync_pending_parents WHERE \"table\" = 'scenes'").count == 1)
        #expect(try rawB.query("SELECT * FROM person_markers WHERE person_id IS NULL").count == 1)
        let cursor = try await b.database.syncCursor(table: SyncTable.named("scenes"))
        for run in runs { try await server.seed(run, table: "analysis_runs") }
        try await eb.sync()
        #expect(try rawB.query("SELECT * FROM scenes").count == 1)
        #expect(try rawB.query("SELECT * FROM sync_pending_parents").isEmpty)
        #expect(try await b.database.syncCursor(table: SyncTable.named("scenes")) == cursor)
        #expect(try await b.database.syncPendingCount() == 0)
    }
}

extension SyncEngineTests {
    @Test("Duplicate fight event natural keys preserve both rows and do not stall later cycles")
    func duplicateFightEventKeys() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        try raw.execute("INSERT INTO videos(id, hash, filename, path) VALUES (1, 'fight', 'Fight.mov', NULL)")
        for points in [1.0, 2.0] {
            try raw.execute("INSERT INTO fight_events(video_id, at_time, fighter_key, action, points) VALUES (1, 1.2345678901234567, 'blue', 'hit', ?)", [.real(points)])
        }
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        let rows = try await b.database.fetchFightEvents()
        #expect(rows.count == 2)
        #expect(await server.allRows(table: "fight_events").count == 2)
        #expect(try await a.database.syncPendingCount() == 0)
        #expect(await ea.changedTables.isEmpty)
    }

    @Test("Two members' transcription segments and turns stay in complete independent sets")
    func independentTranscriptionSets() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        for (folder, label, date) in [(a, "A", "2026-10-07T10:00:00Z"), (b, "B", "2026-10-07T11:00:00Z")] {
            let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
            try raw.execute("INSERT INTO videos(id, hash, filename, path) VALUES (1, 'same', 'Interview.mov', NULL)")
            try await folder.database.replaceTranscripts(videoID: 1, language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 1, text: label + "1"), TranscriptSegment(start: 1, end: 2, text: label + "2")], provider: "test", model: label)
            try raw.execute("UPDATE transcripts SET transcription_created_at = ?", [.text(date)])
            try raw.execute("""
                INSERT INTO speaker_turns(video_id, start_time, end_time, cluster, transcription_key, transcription_created_at)
                SELECT video_id, start_time, end_time, 1, transcription_key, transcription_created_at FROM transcripts
                """)
        }
        let ea = engine(a, server, scope), eb = engine(b, server, scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        try await eb.sync()
        for folder in [a, b] {
            let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
            #expect(try raw.query("SELECT * FROM transcripts").count == 4)
            let sets = try await folder.database.transcriptionSets(videoID: 1)
            #expect(sets.count == 2)
            for set in sets {
                let rows = try await folder.database.fetchTranscripts(videoID: 1, transcriptionKey: set.id)
                #expect(rows.count == 2)
                #expect(Set(rows.map { String($0.text.prefix(1)) }).count == 1)
                #expect(try await folder.database.fetchSpeakerTurns(videoID: 1, transcriptionKey: set.id).count == 2)
            }
            #expect(try await folder.database.fetchTranscripts(videoID: 1).map(\.text) == ["B1", "B2"])
            #expect(try await folder.database.transcriptSegments(videoID: 1, start: 0, end: 2).map(\.text) == ["B1", "B2"])
            #expect(try await folder.database.syncPendingCount() == 0)
        }
    }

    @Test("First synced run defaults are consumed once and never apply to locally analyzed footage")
    func firstSyncedRunDefaultOnly() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        let raw = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        try raw.executeScript("""
            INSERT INTO videos(id, hash, filename, path) VALUES (1, 'new', 'New.mov', NULL);
            INSERT INTO analysis_runs(video_id, name, created_at) VALUES (1, 'Old', '2026-10-06'), (1, 'New', '2026-10-07');
            """)
        try await engine(a, server, scope).sync()
        try await engine(b, server, scope).sync()
        #expect(try await a.database.consumeSyncedRunDefaults().isEmpty)
        let defaults = try await b.database.consumeSyncedRunDefaults()
        let newest = try #require(try await b.database.fetchAnalysisRuns().first)
        #expect(defaults[newest.videoID] == newest.id)
        // A user can now clear the selection. The next cycle does not select again.
        try await engine(b, server, scope).sync()
        #expect(try await b.database.consumeSyncedRunDefaults().isEmpty)
    }

    @Test("A teammate's Drive copy cannot overwrite this Mac's existing copy")
    func prefersLocalDriveCopy() async throws {
        let a = try SyncTestFolder(), b = try SyncTestFolder(), server = StubSyncServer()
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        for (folder, drive) in [(a, "drive-A"), (b, "drive-B")] {
            let raw = try SQLiteConnection(path: folder.url.appendingPathComponent("profile.db").path)
            try raw.execute("INSERT INTO videos(id, hash, filename, path, drive_file_id, drive_link) VALUES (1, 'same', 'Same.mov', NULL, ?, ?)", [.text(drive), .text(drive + "-link")])
        }
        try await engine(a, server, scope).sync()
        try await engine(b, server, scope).sync()
        #expect(try await b.database.video(id: 1)?.driveFileID == "drive-B")
        #expect(try await b.database.video(id: 1)?.driveLink == "drive-B-link")
    }
}
