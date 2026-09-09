import Foundation
import Testing
@testable import Clip_Builder

struct LearnedDocumentBuilderTests {
    @Test func databaseProjectionAndStableRewrite() async throws {
        let temp = try TempDirectory()
        let database = try Database(path: temp.url.appendingPathComponent("profile.db"))
        let account = try await database.upsertIGAccount(username: "private_account", kind: "own",
            displayName: "Private account", igUserID: "private-account-id", followers: 987654)
        let raw = try SQLiteConnection(path: temp.url.appendingPathComponent("profile.db").path)
        try raw.execute("INSERT INTO ig_report_media (account_id, shortcode, caption, permalink, thumbnail_path) VALUES (?, ?, ?, ?, ?)",
            [.integer(account), .text("private_shortcode"), .text("private_caption"), .text("https://private/source"), .text("/Users/private/thumb.jpg")])
        try raw.execute("INSERT INTO ig_account_snapshots (account_id, snapshot_date, followers_count) VALUES (?, ?, ?)",
            [.integer(account), .text("2026-09-09"), .integer(987654)])
        let reportID = try #require(try raw.query("SELECT id FROM ig_report_media").first?["id"]?.intValue)
        try raw.execute("INSERT INTO ig_comments (id, account_id, report_media_id, username, text, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
            [.text("comment-id"), .integer(account), .integer(reportID), .text("commenter_handle"),
             .text("private_comment"), .text("2026-09-09")])
        let id = try await database.addLesson(text: "Original rule", pinned: true, evidence: "Two reviews")
        let before = try await database.fetchLessons()
        try await database.updateLesson(id: id, text: "Rewritten rule", pinned: true)
        let after = try await database.fetchLessons()
        #expect(before.first?.learnedID == after.first?.learnedID)
        #expect(after.first?.learnedID == LearnedPreferences.stableID("Original rule"))
        let result = try await LearnedDocumentBuilder.build(profile: BrandProfile(name: "Test"), database: database,
                                                             readFrame: { _ in Data() })
        let wire = String(decoding: try JSONEncoder().encode(result.document), as: UTF8.self)
        for secret in ["private_account", "private-account-id", "private_shortcode", "private_caption", "commenter_handle", "private_comment", "/Users/", "987654", "ig_"] {
            #expect(!wire.contains(secret))
        }
        #expect(result.document.sections.first { $0.kind == .lessons }?.items.first?.text == "Rewritten rule")
    }
}
