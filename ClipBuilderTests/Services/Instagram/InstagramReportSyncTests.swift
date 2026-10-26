import Foundation
import Testing
@testable import Clip_Builder

@Suite("Instagram report sync checkpoints")
struct InstagramReportSyncTests {
    @Test("Comments checkpoint advances to now only when every fetch succeeded")
    func commentsCheckpoint() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let failed = now.addingTimeInterval(-86_400 * 20)
        #expect(InstagramReportSync.commentsCheckpoint(previous: nil, now: now, failedPostDates: []) == now)
        // A failure keeps the checkpoint just before the oldest failed post, so it is retried.
        #expect(InstagramReportSync.commentsCheckpoint(
            previous: nil, now: now, failedPostDates: [failed, now.addingTimeInterval(-60)])
            == failed.addingTimeInterval(-1))
        #expect(InstagramReportSync.commentsCheckpoint(
            previous: failed.addingTimeInterval(-86_400), now: now, failedPostDates: [failed])
            == failed.addingTimeInterval(-1))
        // Never moves backwards past the previous checkpoint.
        #expect(InstagramReportSync.commentsCheckpoint(
            previous: failed.addingTimeInterval(86_400), now: now, failedPostDates: [failed]) == nil)
    }

    @Test("Failed insight and comment requests leave the checkpoints where a later Refresh retries them")
    func failuresDoNotAdvanceCheckpoints() async throws {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let oldPosted = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 45 * 86_400).rounded(.down))
        let newPosted = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 2 * 86_400).rounded(.down))
        let media = """
            {"data":[
              {"id":"new-1","media_type":"VIDEO","media_product_type":"REELS",
               "permalink":"https://www.instagram.com/reel/NEW1/","timestamp":"\(formatter.string(from: newPosted))",
               "like_count":3,"comments_count":1},
              {"id":"old-1","media_type":"VIDEO","media_product_type":"REELS",
               "permalink":"https://www.instagram.com/reel/OLD1/","timestamp":"\(formatter.string(from: oldPosted))",
               "like_count":5,"comments_count":0}
            ]}
            """
        let refused = InstagramTestTransport.Reply.json(#"{"error":{"code":100,"message":"Unsupported request"}}"#)
        let transport = InstagramTestTransport([
            "ig-123": .json(#"{"followers_count":10,"follows_count":1,"media_count":2}"#),
            "ig-123/media": .json(media),
            "new-1/insights": refused,
            "old-1/insights": refused,
            "new-1/comments": refused,
            "old-1/comments": .json(#"{"data":[]}"#),
            "ig-123/insights": refused,
        ])
        let graph = transport.provider()
        defer { transport.finish(graph) }
        let temp = try TempDatabase()
        let accountID = try await temp.database.upsertIGAccount(username: "sync-test-\(UUID().uuidString)",
                                                                kind: "own", displayName: nil,
                                                                igUserID: "ig-123", followers: nil)
        let sync = InstagramReportSync(provider: graph, username: "sync-test")
        try await sync.run(accountID: accountID, igUserID: "ig-123", database: temp.database, log: { _ in })

        let state = try await temp.database.igSyncState(accountID: accountID)
        // Every daily-insight request failed: the day is not marked done.
        #expect(state["account_insights_last_day"] == nil)
        // The failed recent post is still after the comments checkpoint.
        let checkpoint = try #require(state["comments_synced_at"].flatMap { Database.parseISODate($0) })
        #expect(checkpoint < newPosted)
        #expect(checkpoint > oldPosted)
        // Fallback public counts do not count as fetched insights.
        #expect(try await temp.database.fetchIGReportMediaInsightDates(accountID: accountID).isEmpty)

        try await sync.run(accountID: accountID, igUserID: "ig-123", database: temp.database, log: { _ in })
        // The 45-day-old post is outside the always-refresh window, yet it is retried.
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("/old-1/insights") == true }.count == 2)
    }
}
