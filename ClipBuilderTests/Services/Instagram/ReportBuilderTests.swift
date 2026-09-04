import Foundation
import Testing
@testable import Clip_Builder

@Suite("Instagram report logic")
struct ReportBuilderTests {
    @Test("HTML helpers normalize report values")
    func htmlHelpers() {
        #expect(ReportHTML.decode("A &amp; B") == "A & B")
        #expect(ReportHTML.int("1,234") == 1234)
        #expect(ReportHTML.isoDate(fromReportDate: "Sep 4, 2026") == "2026-09-04")
        #expect(ReportHTML.capture(#"id=(\d+)"#, in: "id=42") == "42")
    }

    @Test("saved engagement HTML parses posts, KPIs, and follower history")
    func engagementParser() throws {
        let html = try fixture("engagement-report", extension: "html")
        let report = EngagementReportParser.parse(html)
        #expect(report.generatedDate == "2026-09-04")
        #expect(report.kpis["Followers"] == 1234)
        #expect(report.followerSeries.last?.value == 1234)
        #expect(report.posts.first?.shortcode == "ABC123")
        #expect(report.posts.first?.metrics["views"] == 200)
    }

    @Test("saved insights HTML parses breakdowns and demographics")
    func insightsParser() throws {
        let html = try fixture("peacegrappler-insights", extension: "html")
        let report = InsightsPageParser.parse(html)
        #expect(report.endDate == "2026-09-04")
        #expect(report.followerTrend.count == 2)
        #expect(report.reachBreakdown.first { $0.0 == "followers" }?.1 == 400)
        #expect(report.age.first?.male == 100)
        #expect(report.heatmap == [12])
    }

    @Test("regression: duplicate shortcodes collapse to one import row")
    func duplicateShortcodes() {
        let first = post(shortcode: "same", caption: "first")
        let duplicate = post(shortcode: "same", caption: "duplicate")
        let fresh = post(shortcode: "new", caption: "new")
        let unique = PeaceGrapplerImporter.uniqueNewPosts(
            [first, duplicate, fresh], knownShortcodes: ["known"]
        )
        #expect(unique.map(\.shortcode) == ["same", "new"])
        #expect(PeaceGrapplerImporter.uniqueNewPosts([first], knownShortcodes: ["same"]).isEmpty)
    }

    @Test("comment scoring handles early, reply, and emoji rules")
    func commentScoring() {
        let posted = Date(timeIntervalSince1970: 1_000)
        let earlyText = comment(id: "1", text: "Great reel", timestamp: posted.addingTimeInterval(60), ref: posted)
        let lateEmoji = comment(id: "2", text: "🔥", reply: "parent", timestamp: posted.addingTimeInterval(3600), ref: posted)
        #expect(InstagramReportBuilder.score(earlyText) == 10)
        #expect(InstagramReportBuilder.score(lateEmoji) == 2)
        #expect(InstagramReportBuilder.isEmojiOnly("🔥🔥"))
        #expect(!InstagramReportBuilder.isEmojiOnly("great 🔥"))
        let ranking = InstagramReportBuilder.rankings([earlyText, lateEmoji])
        #expect(ranking.first?.score == 12)
        let activity = InstagramReportBuilder.activity([earlyText, lateEmoji], captions: [1: "A caption"])
        #expect(activity.first?.total == 2)
    }

    private func fixture(_ name: String, extension ext: String) throws -> String {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func post(shortcode: String, caption: String) -> EngagementReportParser.Post {
        EngagementReportParser.Post(shortcode: shortcode, permalink: "https://instagram.com/reel/\(shortcode)/",
                                    postedAt: nil, productType: "REELS", caption: caption, metrics: [:])
    }

    private func comment(id: String, text: String, reply: String? = nil,
                         timestamp: Date, ref: Date) -> IGCommentRecord {
        IGCommentRecord(id: id, reportMediaID: 1, parentCommentID: reply,
                        username: "fan", text: text, likeCount: 0, hidden: false,
                        timestamp: timestamp, refTimestamp: ref)
    }
}

private final class BundleToken {}
