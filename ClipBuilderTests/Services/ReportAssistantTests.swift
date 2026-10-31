import Foundation
import Testing
@testable import Clip_Builder

@Suite("Report assistant")
struct ReportAssistantTests {
    private var account: IGAccountRecord { IGAccountRecord(id: 1, username: "fixture", kind: "own") }
    private var date: Date { Date(timeIntervalSince1970: 1_790_000_000) }

    private func fixture(posts: Int = 2) -> InstagramReport {
        var report = InstagramReport(period: .last30, periodLabel: "Last 30 Days", generatedAt: date)
        report.overview.kpis = [.init(label: "Followers", value: "1,200", delta: .init(amount: 200, percent: 20))]
        report.overview.followerSeries = [.init(date: date.addingTimeInterval(-86400), value: 1000), .init(date: date, value: 1200)]
        report.overview.contentPublished = [.init(label: "This month", total: 4, reels: 2, feed: 1, carousels: 1)]
        report.overview.engagement = [.init(label: "Last 30 Days", posts: 4, likes: 80, comments: 10, shares: 7, saves: 9, reach: 1200, views: 1800)]
        report.posts.rows = (0..<posts).map { index in
            .init(media: IGReportMediaRow(id: Int64(index), accountID: 1, shortcode: "p\(index)", mediaType: "VIDEO", productType: "REELS",
                caption: String(repeating: "z", count: 100), captionTruncated: false, postedAt: date,
                likeCount: 20, commentsCount: 2, source: "graph", metrics: ["reach": Double(100 + index), "views": 150, "saved": 4]))
        }
        report.community.rankingsPeriod = [.init(username: "reader", score: 10, early: 1, textComments: 2, emojiComments: 1, textReplies: 0, emojiReplies: 0)]
        report.community.topCommenters = [.init(username: "reader", comments: 3, replies: 0, topPosts: [])]
        report.audience.age = [.init(label: "25–34", value: 600)]
        report.audience.engagedGender = [.init(label: "F", value: 42)]
        return report
    }

    @Test func contextIncludesAnalyticsAndMissingValues() {
        let text = ReportAssistant.context(report: fixture(), account: account)
        for expected in ["@fixture", "Last 30 Days", "Followers: 1,200; delta 200.0 (20.0%)", "1000.0 followers", "1200.0 followers",
                         "total 4, reels 2", "likes 80", "saves 9", "Top posts by reach", "Top posts by engagement", "shares no data",
                         "@reader: score 10", "25–34: 600.0", "F: 42.0"] {
            #expect(text.contains(expected), "Missing \(expected)")
        }
        #expect(!text.contains(String(repeating: "z", count: 81)))
    }

    @Test func postsHaveOneSharedLimit() {
        let report = fixture(posts: 100)
        let text = ReportAssistant.context(report: report, account: account, posts: 5)
        #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("Post ") }.count == 5)
        #expect(text.contains("Post 99:"))
        #expect(!ReportAssistant.context(report: report, account: account, posts: -1).contains("Post "))
        let standard = ReportAssistant.context(report: report, account: account)
        #expect(standard.components(separatedBy: "\n").filter { $0.hasPrefix("Post ") }.count == 60)
    }

    @Test func emptyReportSaysNoData() {
        let report = InstagramReport(period: .last7, periodLabel: "Last 7 Days", generatedAt: date)
        #expect(!report.hasData)
        let text = ReportAssistant.context(report: report, account: account)
        #expect(text.lowercased().contains("no data"))
        #expect(text.contains("Last 7 Days"))
    }

    @Test func promptAndCatalogUseReportTask() {
        let prompt = ReportAssistant.prompt("Which posts worked?", report: fixture(), account: account)
        #expect(prompt.contains("Using only the data below"))
        #expect(prompt.contains("Say what is missing"))
        #expect(prompt.contains("Which posts worked?"))
        #expect(AITask.configurable.contains(.report))
        #expect(AITask.report.label == "AI Report")
        #expect(AICatalog.taskDefaults["report"] == "claude")
        #expect(AICatalog.recommendedChains["report"]?.map(\.provider) == ["claude", "antigravity", "gemini"])
        #expect(AppJobKind.report.shortTitle == "AI Report")
        let record = AIReportRecord(accountID: 1, periodKey: "last30", prompt: "Report", markdown: "# Report", provider: "claude")
        #expect(AppJobResult.report(record).needsReview)
    }

    @Test func savedReportsRoundTripAndCascade() async throws {
        let directory = try TempDirectory(prefix: "AIReports")
        let database = try Database(path: directory.url.appendingPathComponent("test.sqlite"))
        let accountID = try await database.upsertIGAccount(username: "fixture", kind: "own", displayName: nil, igUserID: nil, followers: nil)
        var record = AIReportRecord(accountID: accountID, periodKey: "last30", prompt: "Report", markdown: "# Numbers", provider: "claude", createdAt: date)
        try await database.saveIGAIReport(record)
        let saved = try await database.fetchIGAIReports(accountID: accountID)
        #expect(saved == [record])
        record.markdown = "# Updated"
        try await database.saveIGAIReport(record)
        #expect(try await database.fetchIGAIReports(accountID: accountID) == [record])
        try await database.deleteIGAIReport(id: record.id)
        #expect(try await database.fetchIGAIReports(accountID: accountID).isEmpty)
        try await database.saveIGAIReport(record)
        try await database.deleteIGAccount(id: accountID)
        #expect(try await database.fetchIGAIReports(accountID: accountID).isEmpty)
    }
}
