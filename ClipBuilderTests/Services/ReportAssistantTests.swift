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

    // MARK: - Context and suggestions

    private func reelsAndFeed(reelReach: Double, feedReach: Double) -> InstagramReport {
        var report = fixture(posts: 0)
        report.posts.rows = [
            .init(media: IGReportMediaRow(id: 1, accountID: 1, shortcode: "r", mediaType: "VIDEO", productType: "REELS",
                caption: "", captionTruncated: false, postedAt: date, likeCount: 1, commentsCount: 0, source: "graph",
                metrics: ["reach": reelReach, "saved": 3])),
            .init(media: IGReportMediaRow(id: 2, accountID: 1, shortcode: "f", mediaType: "IMAGE", productType: "FEED",
                caption: "", captionTruncated: false, postedAt: date, likeCount: 1, commentsCount: 0, source: "graph",
                metrics: ["reach": feedReach])),
        ]
        return report
    }

    @Test func snapshotSplitsReelsFromFeed() {
        let snapshot = ReportAssistant.snapshot(report: reelsAndFeed(reelReach: 300, feedReach: 100), account: account, isLoading: false)
        #expect(snapshot.reels == 1)
        #expect(snapshot.reelsReach == 300)
        #expect(snapshot.feedReach == 100)
        #expect(snapshot.saves == 3)
        #expect(snapshot.followerDelta == 200)
    }

    @Test func summaryLineAndExamplesBecomeSuggestions() {
        let context = ReportAssistant.context(ReportAssistant.snapshot(report: reelsAndFeed(reelReach: 300, feedReach: 100),
                                                                       account: account, isLoading: false))
        #expect(context.summaryLine == "Reports · @fixture · Last 30 Days · 2 posts")
        let rows = ReportAssistant().suggestions(for: context)
        #expect(rows.map(\.title) == ReportAssistant().examples)
        #expect(rows.map(\.actionID) == ["reports.ask.0", "reports.ask.1", "reports.ask.2"])
        #expect(rows[0].id == "reports.worked.reels")
        #expect(rows[0].reason == "Reels out-reached feed 3:1 in the last 30 days")
        #expect(rows[1].reason == "3 saves across 2 posts")
        #expect(rows[2].reason == "Followers +200 (20.0%) in the last 30 days")
    }

    @Test func feedWinningChangesTheReasonAndID() {
        let context = ReportAssistant.context(ReportAssistant.snapshot(report: reelsAndFeed(reelReach: 100, feedReach: 140),
                                                                       account: account, isLoading: false))
        let first = ReportAssistant().suggestions(for: context).first
        #expect(first?.id == "reports.worked.feed")
        #expect(first?.reason == "Feed posts out-reached reels 1.4:1 in the last 30 days")
    }

    @Test func aDismissedReportRowReturnsForANewReport() {
        let rows = { (reels: Double, feed: Double) in
            ReportAssistant().suggestions(for: ReportAssistant.context(ReportAssistant.snapshot(
                report: self.reelsAndFeed(reelReach: reels, feedReach: feed), account: self.account, isLoading: false)))
        }
        let before = rows(300, 100)
        let after = rows(600, 200)
        // Same winner, same 3:1 wording: the id and reason text repeat, the report does not.
        #expect(before[0].id == after[0].id)
        #expect(before[0].reason == after[0].reason)
        #expect(before[0].dismissKey != after[0].dismissKey)
        #expect(AssistantModel.merge(rules: after, ranked: nil, dismissed: [before[0].dismissKey]).map(\.id).contains(after[0].id))
        #expect(rows(300, 100)[0].dismissKey == before[0].dismissKey)
    }

    @Test func noAccountOrNoDataIsAnInsight() {
        let none = ReportAssistant().suggestions(for: ReportAssistant.context(.init()))
        #expect(none.map(\.id) == ["reports.account.none"])
        #expect(none.first?.kind == .insight)
        let empty = InstagramReport(period: .last7, periodLabel: "Last 7 Days", generatedAt: date)
        let rows = ReportAssistant().suggestions(for: ReportAssistant.context(
            ReportAssistant.snapshot(report: empty, account: account, isLoading: false)))
        #expect(rows.map(\.id) == ["reports.data.none"])
        let loading = ReportAssistant.context(ReportAssistant.snapshot(report: nil, account: account, isLoading: true))
        #expect(ReportAssistant().suggestions(for: loading).isEmpty)
        #expect(loading.summaryLine == "Reports · @fixture · loading")
    }

    @Test func ratioFormatting() {
        #expect(ReportAssistant.ratio(300, 100) == "3:1")
        #expect(ReportAssistant.ratio(140, 100) == "1.4:1")
        #expect(ReportAssistant.ratio(5, 0) == "5:1")
    }
}
