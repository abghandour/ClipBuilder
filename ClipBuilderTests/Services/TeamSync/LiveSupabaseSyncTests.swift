import Foundation
import Testing
@testable import Clip_Builder

/// Two members against a real Supabase stack with the repo's migrations applied.
/// Skipped unless `CLIPBUILDER_LIVE_SUPABASE_URL` and `_KEY` are set; run with
/// `scripts/test.sh -only-testing:ClipBuilderTests/LiveSupabaseSyncTests \
///   TEST_RUNNER_CLIPBUILDER_LIVE_SUPABASE_URL=http://127.0.0.1:54321 \
///   TEST_RUNNER_CLIPBUILDER_LIVE_SUPABASE_KEY=<anon key>` after `supabase start`.
struct LiveSupabaseSyncTests {
    static var environment: (url: URL, key: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CLIPBUILDER_LIVE_SUPABASE_URL"], let url = URL(string: raw),
              let key = env["CLIPBUILDER_LIVE_SUPABASE_KEY"], !key.isEmpty else { return nil }
        return (url, key)
    }

    /// Password sign-up works on a local stack with confirmations disabled.
    private func signUp(_ label: String) async throws -> (email: String, client: SupabaseClient) {
        let (url, key) = try #require(Self.environment)
        let email = "\(label)-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let anonymous = SupabaseClient(baseURL: url, apiKey: key)
        let data = try await anonymous.request(path: "auth/v1/signup", method: "POST", body: [
            "email": .string(email), "password": .string("Live-Sync-Test-Passw0rd!")
        ])
        let session = try JSONDecoder().decode(SupabaseClient.Session.self, from: data)
        let token = try #require(session.access_token)
        return (email, SupabaseClient(baseURL: url, apiKey: key, accessToken: token))
    }

    private func rows(_ client: SupabaseClient, table: String, teamID: UUID) async throws -> [SyncMapping.WireRow] {
        let data = try await client.request(path: "rest/v1/\(table)", query: [
            .init(name: "select", value: "*"), .init(name: "team_id", value: "eq.\(teamID.uuidString.lowercased())")
        ])
        return try JSONDecoder().decode([SyncMapping.WireRow].self, from: data)
    }

    @Test("Two members converge footage, analysis, transcription sets and fight events through a real server",
          .enabled(if: LiveSupabaseSyncTests.environment != nil))
    func twoMembersLive() async throws {
        let alice = try await signUp("alice"), bob = try await signUp("bob"), carol = try await signUp("carol")
        #expect(try await alice.client.schemaVersion() == SyncEngine.understoodSchemaVersion)

        let teamID = try await alice.client.createTeam(name: "Live \(UUID().uuidString.prefix(6))")
        let invite = try await alice.client.createInvite(teamID: teamID, email: bob.email)
        #expect(try await bob.client.redeemInvite(code: invite) == teamID)
        let scope = SyncScope(teamID: teamID, profileID: UUID())

        let a = try SyncTestFolder(), b = try SyncTestFolder()
        let ea = SyncEngine(database: a.database, client: alice.client, scope: scope)
        let eb = SyncEngine(database: b.database, client: bob.client, scope: scope)

        // Footage both Macs hold (same content, different paths) and footage only A holds.
        func file(_ folder: SyncTestFolder, _ name: String) throws -> String {
            let url = folder.url.appendingPathComponent(name)
            try Data(repeating: 7, count: 64).write(to: url)
            return url.path
        }
        let sharedA = try await a.database.registerVideo(hash: "shared", filename: "Interview.mov", path: file(a, "Interview.mov"),
                                                         duration: 12.5, width: 1920, height: 1080, wide: true)
        let onlyA = try await a.database.registerVideo(hash: "only-a", filename: "Fight.mov", path: file(a, "Fight.mov"),
                                                       duration: 300.25, width: 1920, height: 1080, wide: true)
        let sharedB = try await b.database.registerVideo(hash: "shared", filename: "Interview copy.mov", path: file(b, "Interview copy.mov"),
                                                         duration: 12.5, width: 1920, height: 1080, wide: true)
        let rawA = try SQLiteConnection(path: a.url.appendingPathComponent("profile.db").path)
        let rawB = try SQLiteConnection(path: b.url.appendingPathComponent("profile.db").path)
        try rawA.execute("INSERT INTO analysis_runs(video_id, name, created_at) VALUES (?, 'A run', '2026-10-08T09:00:00Z')", [.integer(sharedA)])
        try rawA.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) SELECT ?, id, 0, 5.5 FROM analysis_runs WHERE video_id = ?", [.integer(sharedA), .integer(sharedA)])
        try rawA.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) SELECT ?, id, 5.5, 12.5 FROM analysis_runs WHERE video_id = ?", [.integer(sharedA), .integer(sharedA)])
        try rawA.execute("INSERT INTO analysis_runs(video_id, name, created_at) VALUES (?, 'Fight run', '2026-10-08T09:30:00Z')", [.integer(onlyA)])
        try rawA.execute("INSERT INTO scenes(video_id, run_id, start_time, end_time) SELECT ?, id, 10, 20 FROM analysis_runs WHERE video_id = ?", [.integer(onlyA), .integer(onlyA)])
        for points in [1.0, 2.0] {
            try rawA.execute("INSERT INTO fight_events(video_id, at_time, fighter_key, action, points) VALUES (?, 1.2345678901234567, 'blue', 'hit', ?)",
                             [.integer(onlyA), .real(points)])
        }
        for (folder, id, label, date) in [(a, sharedA, "A", "2026-10-08T10:00:00Z"), (b, sharedB, "B", "2026-10-08T11:00:00Z")] {
            try await folder.database.replaceTranscripts(videoID: id, language: "en", isTranslation: false,
                segments: [TranscriptSegment(start: 0, end: 1, text: label + "1"), TranscriptSegment(start: 1, end: 2, text: label + "2")],
                provider: "test", model: label)
            let raw = folder === a ? rawA : rawB
            try raw.execute("UPDATE transcripts SET transcription_created_at = ? WHERE video_id = ?", [.text(date), .integer(id)])
        }
        _ = try await a.database.addLesson(text: "Live lesson", pinned: true, evidence: "A")

        try await a.database.bindSync(to: scope)
        try await b.database.bindSync(to: scope)
        try await ea.sync()
        try await eb.sync()
        try await ea.sync()
        try await eb.sync()

        // B adopted A's copy of the shared file and keeps its own path.
        let bShared = try #require(try await b.database.video(id: sharedB))
        #expect(bShared.path?.hasSuffix("Interview copy.mov") == true)
        #expect(bShared.isPresent)
        #expect(try rawB.query("SELECT COUNT(*) AS n FROM scenes WHERE video_id = ?", [.integer(sharedB)]).first?["n"]?.intValue == 2)
        // A-only footage arrives as metadata without a path and is not admitted.
        let bOnly = try #require(try await b.database.fetchVideos().first { $0.hash == "only-a" })
        #expect(bOnly.path == nil)
        #expect(!bOnly.isPresent)
        #expect(bOnly.duration == 300.25)
        #expect(try rawB.query("SELECT COUNT(*) AS n FROM scenes WHERE video_id = ?", [.integer(bOnly.id)]).first?["n"]?.intValue == 1)
        #expect(try await b.database.fetchFightEvents().count == 2)
        #expect(try await a.database.fetchFightEvents().count == 2)
        // Two transcription sets stay independent; the newest is the default on both.
        for (folder, id) in [(a, sharedA), (b, sharedB)] {
            #expect(try await folder.database.transcriptionSets(videoID: id).count == 2)
            #expect(try await folder.database.fetchTranscripts(videoID: id).map(\.text) == ["B1", "B2"])
        }
        #expect(Set(try await b.database.fetchLessons().map(\.text)) == ["Live lesson"])
        #expect(try await a.database.syncPendingCount() == 0)
        #expect(try await b.database.syncPendingCount() == 0)

        // No echo: another cycle on each side changes nothing.
        let quietA = SyncEngine(database: a.database, client: alice.client, scope: scope)
        try await quietA.sync()
        #expect(await quietA.changedTables.isEmpty)
        let quietB = SyncEngine(database: b.database, client: bob.client, scope: scope)
        try await quietB.sync()
        #expect(await quietB.changedTables.isEmpty)

        // Server rows carry no local paths; non-members see nothing.
        let serverVideos = try await rows(alice.client, table: "videos", teamID: teamID)
        #expect(serverVideos.count == 2)
        #expect(serverVideos.allSatisfy { $0["path"] == nil })
        #expect(serverVideos.allSatisfy { $0["team_id"]?.string?.lowercased() == teamID.uuidString.lowercased() })
        #expect(try await rows(carol.client, table: "videos", teamID: teamID).isEmpty)
        #expect(try await rows(carol.client, table: "scenes", teamID: teamID).isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await carol.client.createInvite(teamID: teamID, email: "nobody@example.com")
        }
    }
}
