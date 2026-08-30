import SwiftUI

/// Instagram → Reports: the peace-grappler analytics pages rebuilt natively
/// from the data the Refresh button stores — Overview & growth, post
/// performance, commenters & community rankings, audience demographics.
struct InstagramReportsView: View {
    @Environment(AppStore.self) private var store

    enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case posts = "Posts"
        case commenters = "Commenters"
        case audience = "Audience"
        var id: String { rawValue }
    }

    private enum RankingScope: String, CaseIterable, Identifiable {
        case period, allTime
        var id: String { rawValue }
    }

    private enum AudienceScope: String, CaseIterable, Identifiable {
        case followers = "Followers"
        case engaged = "Engaged Audience"
        var id: String { rawValue }
    }

    @AppStorage("instagram.reportPage") private var page: Page = .overview
    @State private var sortOrder = [KeyPathComparator(\InstagramReport.PostRow.date, order: .reverse)]
    @State private var rankingScope: RankingScope = .period
    @State private var audienceScope: AudienceScope = .followers
    @State private var trendScope = "Reels"
    @State private var showIgnored = false
    @State private var ignoredAccounts: [String] = []
    @State private var newIgnored = ""

    private var selectedAccount: IGAccountRecord? {
        store.igAccounts.first { $0.id == store.igSelectedAccountID }
    }

    var body: some View {
        Group {
            if let account = selectedAccount {
                if !store.isGraphAccount(account) && store.igReport?.hasData != true {
                    notConnected(account)
                } else if let report = store.igReport, report.hasData {
                    content(report, account: account)
                } else if store.isLoadingIGReport || store.isFetchingInstagram || store.isImportingPeaceGrappler {
                    working
                } else {
                    noData(account)
                }
            } else {
                ContentUnavailableView("No Account", systemImage: "chart.bar.xaxis",
                                       description: Text("Pick an account from the Accounts menu."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty states

    private func notConnected(_ account: IGAccountRecord) -> some View {
        ContentUnavailableView {
            Label("Reports need the connected account", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Reports use the official Instagram API — account insights, per-post metrics, comments and demographics are only available for your own connected account.\n\nConnect @\(account.username) in Settings → Instagram (Own Account), then press Refresh.")
        } actions: {
            SettingsLink { Text("Open Settings…") }
                .buttonStyle(.borderedProminent)
        }
    }

    private func noData(_ account: IGAccountRecord) -> some View {
        ContentUnavailableView {
            Label("No report data yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Press Refresh to fetch @\(account.username)'s posts, insights and comments. To see history from before today, import the peace-grappler reports in Settings → Instagram → Report History.")
        } actions: {
            HStack {
                Button("Refresh") { store.refreshInstagram(username: account.username) }
                    .buttonStyle(.borderedProminent)
                Button("Import Report History") { store.importPeaceGrapplerReports() }
            }
        }
    }

    private var working: some View {
        VStack(spacing: Theme.spaceM) {
            ProgressView()
            Text(store.isImportingPeaceGrappler ? "Importing report history…"
                 : store.isFetchingInstagram ? "Fetching report data…" : "Building report…")
                .foregroundStyle(.secondary)
            if let last = store.igLog.last {
                Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding()
    }

    // MARK: - Content

    private func content(_ report: InstagramReport, account: IGAccountRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spaceL) {
                header(report)
                if report.importedThrough == nil, store.canImportPeaceGrapplerHistory,
                   !store.isImportingPeaceGrappler {
                    importBanner
                }
                switch page {
                case .overview: overview(report)
                case .posts: posts(report)
                case .commenters: commenters(report)
                case .audience: audience(report)
                }
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(Theme.spaceL)
        }
    }

    /// The Graph API reaches back ~30 days for account insights; the
    /// peace-grappler reports carry the months before that.
    private var importBanner: some View {
        HStack(spacing: Theme.spaceM) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(ReportColors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Months of history are waiting in the peace-grappler reports")
                    .font(.subheadline.weight(.semibold))
                Text("The Instagram API only reaches back ~30 days for account insights. Importing the committed reports adds follower growth since April, per-post metric history, monthly commenter rankings, demographics, and the daily AI reel analyses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Import History") { store.importPeaceGrapplerReports() }
                .buttonStyle(.borderedProminent)
                .help("Reads the peace-grappler checkout (Settings → Instagram → Report History sets the folder) — safe to run again, live data always wins")
        }
        .padding(Theme.spaceL)
        .background(ReportColors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(ReportColors.accent.opacity(0.3)))
    }

    private func header(_ report: InstagramReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                Picker("Period", selection: Binding(
                    get: { store.igReportPeriod.id },
                    set: { store.setIGReportPeriod(ReportPeriod.from(id: $0)) }
                )) {
                    Text("Last 7 Days").tag(ReportPeriod.last7.id)
                    Text("Last 30 Days").tag(ReportPeriod.last30.id)
                    Text("This Month").tag(ReportPeriod.monthToDate.id)
                    Text("All Time").tag(ReportPeriod.allTime.id)
                    if !report.availableMonths.isEmpty {
                        Divider()
                        ForEach(report.availableMonths) { month in
                            Text(month.label).tag(month.id)
                        }
                    }
                }
                .frame(maxWidth: 220)
                if store.isLoadingIGReport { ProgressView().controlSize(.small) }
            }
            HStack(spacing: Theme.spaceS) {
                if let refreshed = report.lastRefreshed {
                    Text("Last refreshed \(refreshed.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Not refreshed yet — press Refresh for live data")
                }
                if let imported = report.importedThrough {
                    Text("·")
                    Text("History imported through \(imported)")
                }
                if store.isFetchingInstagram || store.isImportingPeaceGrappler, let last = store.igLog.last {
                    Text("·")
                    ProgressView().controlSize(.mini)
                    Text(last).lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overview

    private let statColumns = [GridItem(.adaptive(minimum: 150), spacing: Theme.spaceS)]

    private func overview(_ report: InstagramReport) -> some View {
        let overview = report.overview
        return VStack(alignment: .leading, spacing: Theme.spaceL) {
            LazyVGrid(columns: statColumns, spacing: Theme.spaceS) {
                ForEach(overview.kpis) { StatCard(stat: $0, accent: true) }
            }

            SectionCard(title: "Follower Growth",
                        subtitle: overview.newFollowersTotal > 0
                            ? "\(overview.newFollowersTotal.formatted()) new followers in the chart window" : nil) {
                HStack(spacing: Theme.spaceS) {
                    ForEach(overview.followerGrowth) { GrowthCardView(card: $0) }
                }
                FollowerLineChart(series: overview.followerSeries)
                if !overview.newFollowersSeries.isEmpty {
                    Text("New followers per day").font(.caption).foregroundStyle(.secondary)
                    NewFollowersChart(series: overview.newFollowersSeries)
                }
            }

            HStack(alignment: .top, spacing: Theme.spaceL) {
                SectionCard(title: "Content Published") {
                    Grid(alignment: .leading, horizontalSpacing: Theme.spaceL, verticalSpacing: 6) {
                        GridRow {
                            Text("Period").foregroundStyle(.secondary)
                            Text("Total").foregroundStyle(.secondary)
                            Text("Reels").foregroundStyle(.secondary)
                            Text("Feed").foregroundStyle(.secondary)
                            Text("Carousels").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(overview.contentPublished) { row in
                            GridRow {
                                Text(row.label)
                                Text(row.total.formatted()).monospacedDigit()
                                Text(row.reels.formatted()).monospacedDigit()
                                Text(row.feed.formatted()).monospacedDigit()
                                Text(row.carousels.formatted()).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                }
                SectionCard(title: "Content Mix", subtitle: report.periodLabel) {
                    ContentMixDonut(items: overview.contentMix)
                }
            }

            SectionCard(title: "Engagement Analytics", subtitle: "Engagement = likes + comments") {
                ForEach(overview.engagement) { window in
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Text(window.label).font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: statColumns, spacing: Theme.spaceS) {
                            StatCard(stat: .init(label: "Total Engagement", value: window.totalEngagement.formatted()), accent: true)
                            StatCard(stat: .init(label: "Likes", value: window.likes.formatted()))
                            StatCard(stat: .init(label: "Comments", value: window.comments.formatted()))
                            StatCard(stat: .init(label: "Shares", value: window.shares.formatted()))
                            StatCard(stat: .init(label: "Saves", value: window.saves.formatted()))
                            StatCard(stat: .init(label: "Reach", value: window.reach.formatted()))
                            StatCard(stat: .init(label: "Views", value: window.views.formatted()))
                            StatCard(stat: .init(label: "Posts", value: window.posts.formatted()))
                            StatCard(stat: .init(label: "Avg per Post", value: window.avgPerPost.formatted()))
                        }
                    }
                }
            }

            SectionCard(title: "Account Insights (\(report.periodLabel))",
                        subtitle: overview.accountInsightsNote ?? "Account-level totals from Instagram, with breakdowns by content type") {
                if overview.accountInsights.isEmpty {
                    EmptyNote(text: "No account insights for this period yet — they arrive with Refresh (last 30 days) or the history import.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.spaceS)], spacing: Theme.spaceS) {
                        if let rate = overview.interactionRate {
                            StatCard(stat: .init(label: "Interaction Rate", value: String(format: "%.2f%%", rate),
                                                 note: "interactions ÷ reach"), accent: true)
                        }
                        ForEach(overview.accountInsights) { StatCard(stat: $0) }
                    }
                }
            }

            if !overview.reachByType.isEmpty || !overview.viewsByType.isEmpty || !overview.interactionsByType.isEmpty {
                HStack(alignment: .top, spacing: Theme.spaceL) {
                    SectionCard(title: "Reach", subtitle: followSplit(overview.reachByFollow)) {
                        BreakdownBarChart(items: overview.reachByType,
                                          colors: [ReportColors.silver, ReportColors.pink, ReportColors.green, ReportColors.orange])
                    }
                    SectionCard(title: "Views", subtitle: followSplit(overview.viewsByFollow)) {
                        BreakdownBarChart(items: overview.viewsByType,
                                          colors: [ReportColors.silver, ReportColors.pink, ReportColors.green, ReportColors.orange])
                    }
                    SectionCard(title: "Interactions", subtitle: "By content type") {
                        BreakdownBarChart(items: overview.interactionsByType,
                                          colors: [ReportColors.silver, ReportColors.pink, ReportColors.green, ReportColors.orange])
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.spaceL) {
                SectionCard(title: "Reach by Post", subtitle: "Chronological, colored by type") {
                    ReachPerPostBars(bars: overview.reachPerPost)
                }
                if !overview.linkTaps.isEmpty {
                    SectionCard(title: "Profile Link Taps", subtitle: "By contact button") {
                        HorizontalBars(items: overview.linkTaps)
                    }
                    .frame(maxWidth: 380)
                }
            }
        }
    }

    private func followSplit(_ items: [InstagramReport.LabeledValue]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.label) \($0.intValue.compactFormatted)" }.joined(separator: " · ")
    }

    // MARK: - Posts

    private func posts(_ report: InstagramReport) -> some View {
        let posts = report.posts
        return VStack(alignment: .leading, spacing: Theme.spaceL) {
            if let benchmarks = store.igBenchmarks {
                benchmarksCard(benchmarks)
            }
            calibrationCard()
            if let status = posts.algorithmStatus {
                SectionCard(title: "Algorithm Status", subtitle: "Views of the 5 newest posts against the 5 before them") {
                    HStack(spacing: Theme.spaceL) {
                        Text("\(status.verdict) — \(status.detail)")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(status.verdict == "HIGH" ? ReportColors.green
                                             : status.verdict == "LOW" ? ReportColors.red : ReportColors.orange)
                        Spacer()
                        Text("Recent 5: \(status.recentViews.formatted()) views · Previous 5: \(status.previousViews.formatted()) views")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            SectionCard(title: "Reels", subtitle: "\(report.periodLabel) · deltas against the preceding period") {
                LazyVGrid(columns: statColumns, spacing: Theme.spaceS) {
                    ForEach(posts.reelsSummary) { StatCard(stat: $0) }
                }
            }
            SectionCard(title: "Feed Posts", subtitle: "\(report.periodLabel) · deltas against the preceding period") {
                LazyVGrid(columns: statColumns, spacing: Theme.spaceS) {
                    ForEach(posts.postsSummary) { StatCard(stat: $0) }
                }
            }

            SectionCard(title: "Daily Trends", subtitle: "Metrics bucketed by publish date") {
                Picker("Content", selection: $trendScope) {
                    Text("Reels").tag("Reels")
                    Text("Feed Posts").tag("Posts")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                let points = trendScope == "Reels" ? posts.reelsDaily : posts.postsDaily
                HStack(alignment: .top, spacing: Theme.spaceL) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reach & Views").font(.caption).foregroundStyle(.secondary)
                        DailyTrendChart(points: points, series: [
                            .init(label: "Reach", color: ReportColors.accent, keyPath: \.reach),
                            .init(label: "Views", color: ReportColors.pink, keyPath: \.views),
                        ])
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Interactions").font(.caption).foregroundStyle(.secondary)
                        DailyTrendChart(points: points, series: [
                            .init(label: "Likes", color: ReportColors.accent, keyPath: \.likes),
                            .init(label: "Comments", color: ReportColors.pink, keyPath: \.comments),
                            .init(label: "Saves", color: ReportColors.green, keyPath: \.saves),
                            .init(label: "Shares", color: ReportColors.orange, keyPath: \.shares),
                        ])
                    }
                }
            }

            SectionCard(title: "Post Performance", subtitle: "\(posts.rows.count) posts in \(report.periodLabel) · click a column to sort") {
                if posts.rows.isEmpty {
                    EmptyNote(text: "No posts in this period.")
                } else {
                    postsTable(posts.rows)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.spaceL, alignment: .top),
                                GridItem(.flexible(), spacing: Theme.spaceL, alignment: .top)],
                      alignment: .leading, spacing: Theme.spaceL) {
                rankedList("Top 10 by Engagement", subtitle: "Likes + comments · \(report.periodLabel)",
                           rows: posts.topByEngagement) { "\($0.engagement.formatted()) engagement" }
                rankedList("Top 10 Most Liked", subtitle: report.periodLabel,
                           rows: posts.topLiked) { "\($0.likes.formatted()) likes" }
                rankedList("Top 10 Most Discussed", subtitle: "All time",
                           rows: posts.topDiscussed) { "\($0.comments.formatted()) comments" }
                rankedList("Top Shared & Reposted", subtitle: report.periodLabel,
                           rows: posts.topShared) { "\($0.shares.formatted()) shares" }
            }

            if !posts.reelAnalyses.isEmpty {
                SectionCard(title: "Reel Analyses",
                            subtitle: "Imported from the peace-grappler daily video-analysis reports — each reel's AI review (score vs the account's 90-day benchmarks at the time)") {
                    VStack(alignment: .leading, spacing: Theme.spaceM) {
                        ForEach(posts.reelAnalyses) { analysis in
                            reelAnalysisRow(analysis)
                        }
                    }
                }
            }

            SectionCard(title: "Hashtag Performance", subtitle: "Top 15 by use · average reach and interactions per post") {
                if posts.hashtags.isEmpty {
                    EmptyNote(text: "No hashtags in this period's captions.")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: Theme.spaceL, verticalSpacing: 4) {
                        GridRow {
                            Text("Hashtag").foregroundStyle(.secondary)
                            Text("Posts").foregroundStyle(.secondary)
                            Text("Avg Reach").foregroundStyle(.secondary)
                            Text("Avg Interactions").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(posts.hashtags) { tag in
                            GridRow {
                                Text(tag.tag).foregroundStyle(ReportColors.accent)
                                Text(tag.count.formatted()).monospacedDigit()
                                Text(tag.avgReach.formatted()).monospacedDigit()
                                Text(tag.avgInteractions.formatted()).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// The measured numbers that steer the wizard, the critic, and captions.
    private func benchmarksCard(_ benchmarks: AccountBenchmarks) -> some View {
        SectionCard(title: "What Performs Here",
                    subtitle: "Measured from @\(benchmarks.username)'s reels — these numbers steer the AI Wizard's plan, its critic's engagement forecast, captions, and the publish sheet") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(benchmarks.summaryLines, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle").font(.callout)
                }
            }
            if !benchmarks.topTraits.isEmpty {
                Text("Top-quartile reels — " + benchmarks.topTraits.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !benchmarks.bottomTraits.isEmpty {
                Text("Bottom-quartile reels — " + benchmarks.bottomTraits.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Published reels: the critic's score and forecast against the audience.
    private func calibrationCard() -> some View {
        let published = store.generatedVideos.filter { $0.instagramMediaID != nil }
        let measured = published.compactMap { video -> (forecast: Int, actual: Int)? in
            guard let forecast = video.critique?.forecast, let actual = video.audiencePercentile else { return nil }
            return (forecast, actual)
        }
        return SectionCard(title: "Critic vs Audience",
                           subtitle: "Reels this app generated and published: the critic's score and engagement forecast next to how the audience actually responded") {
            if published.isEmpty {
                EmptyNote(text: "Publish a generated reel from the Library to start calibrating the critic.")
            } else {
                if measured.count >= 3 {
                    let error = Double(measured.reduce(0) { $0 + abs($1.forecast - $1.actual) }) / Double(measured.count)
                    Text(String(format: "Average forecast error: %.0f points over %d reels (forecast percentile vs audience percentile)",
                                error, measured.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: Theme.spaceL, verticalSpacing: 6) {
                    GridRow {
                        Text("Reel"); Text("Critic"); Text("Forecast"); Text("Audience quality"); Text("Beat")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(published) { video in
                        GridRow {
                            Text(video.filename).lineLimit(1)
                            Text(video.critique.map { "\($0.score)/100" } ?? "–").monospacedDigit()
                            Text(video.critique?.forecast.map { "\($0)" } ?? "–").monospacedDigit()
                            Text(video.audienceScore.map { String(format: "%.1f", $0) } ?? "pending").monospacedDigit()
                            Text(video.audiencePercentile.map { "\($0)% of reels" } ?? "–").monospacedDigit()
                                .foregroundStyle((video.audiencePercentile ?? 0) >= 75 ? ReportColors.green
                                                 : (video.audiencePercentile ?? 50) < 40 ? ReportColors.red : .primary)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private func postsTable(_ rows: [InstagramReport.PostRow]) -> some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { row in
                Text(row.date.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
            }
            .width(min: 90, ideal: 100)
            TableColumn("Type", value: \.type) { row in TypeBadge(type: row.type) }
                .width(min: 70, ideal: 80)
            TableColumn("Caption", value: \.caption) { row in
                HStack(spacing: Theme.spaceS) {
                    PostCell(media: row.media, showThumbnail: true)
                    Spacer(minLength: 0)
                    OpenPostButton(media: row.media)
                }
            }
            .width(min: 240, ideal: 380)
            TableColumn("Reach", value: \.reach) { Text($0.reach.formatted()).monospacedDigit() }.width(70)
            TableColumn("Views", value: \.views) { Text($0.views.formatted()).monospacedDigit() }.width(70)
            TableColumn("Likes", value: \.likes) { Text($0.likes.formatted()).monospacedDigit() }.width(60)
            TableColumn("Comments", value: \.comments) { Text($0.comments.formatted()).monospacedDigit() }.width(75)
            TableColumn("Shares", value: \.shares) { Text($0.shares.formatted()).monospacedDigit() }.width(60)
            TableColumn("Saves", value: \.saves) { Text($0.saves.formatted()).monospacedDigit() }.width(60)
            TableColumn("Quality", value: \.quality) { row in
                Text(String(format: "%.1f", row.quality)).monospacedDigit()
                    .help("Normalized save/share/comment/like score (the same one the grid's Quality sort uses)")
            }
            .width(60)
        }
        .frame(height: min(560, CGFloat(rows.count) * 46 + 32))
    }

    private func reelAnalysisRow(_ analysis: InstagramReport.ReelAnalysis) -> some View {
        let color: Color = analysis.tier.hasPrefix("Top") ? ReportColors.green
            : analysis.tier.hasPrefix("Average") ? ReportColors.orange : ReportColors.red
        return HStack(alignment: .top, spacing: Theme.spaceM) {
            VStack(spacing: 3) {
                Text("\(analysis.score)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(color)
                Text(analysis.tier)
                    .font(.badgeCompact)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .frame(width: 100)
            VStack(alignment: .leading, spacing: 3) {
                PostCell(media: analysis.media)
                if let tip = analysis.topTip {
                    Label(tip, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(ReportColors.orange)
                        .lineLimit(2)
                }
                if !analysis.good.isEmpty {
                    Text("✓ " + analysis.good.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(ReportColors.green)
                        .lineLimit(2)
                }
                if !analysis.bad.isEmpty {
                    Text("✗ " + analysis.bad.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(ReportColors.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(analysis.date).font(.caption2).foregroundStyle(.secondary)
                OpenPostButton(media: analysis.media)
            }
        }
        .help((analysis.good.map { "✓ \($0)" } + analysis.bad.map { "✗ \($0)" }
               + (analysis.topTip.map { ["💡 \($0)"] } ?? [])).joined(separator: "\n"))
    }

    private func rankedList(_ title: String, subtitle: String, rows: [InstagramReport.PostRow],
                            metric: @escaping (InstagramReport.PostRow) -> String) -> some View {
        SectionCard(title: title, subtitle: subtitle) {
            if rows.isEmpty {
                EmptyNote(text: "Nothing to rank yet.")
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: Theme.spaceS) {
                            RankBadge(rank: row.rank)
                            PostCell(media: row.media, showThumbnail: false)
                            Spacer(minLength: 4)
                            Text(metric(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            OpenPostButton(media: row.media)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Commenters

    private func commenters(_ report: InstagramReport) -> some View {
        let community = report.community
        return VStack(alignment: .leading, spacing: Theme.spaceL) {
            SectionCard(title: "Top Active Commenters (\(report.periodLabel))",
                        subtitle: community.topCommentersNote ?? "Comments and replies per account, with the posts they engage with most") {
                if community.topCommenters.isEmpty {
                    EmptyNote(text: "No comments for this period yet — Refresh fetches them for the connected account.")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: Theme.spaceL, verticalSpacing: 6) {
                        GridRow {
                            Text("#").foregroundStyle(.secondary)
                            Text("Username").foregroundStyle(.secondary)
                            Text("Comments").foregroundStyle(.secondary)
                            Text("Replies").foregroundStyle(.secondary)
                            Text("Total").foregroundStyle(.secondary)
                            Text("Top Posts Commented On").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(community.topCommenters.enumerated()), id: \.element.id) { index, row in
                            GridRow {
                                RankBadge(rank: index + 1)
                                Text("@\(row.username)").fontWeight(.medium)
                                Text(row.comments.formatted()).monospacedDigit()
                                Text(row.replies.formatted()).monospacedDigit()
                                Text(row.total.formatted()).monospacedDigit().foregroundStyle(ReportColors.accent)
                                Text(row.topPosts.joined(separator: "\n"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    .font(.callout)
                }
            }

            SectionCard(title: "Commenter Breakdown: Last 5 Posts", subtitle: "Who commented on each of the most recent posts") {
                if community.perPost.isEmpty {
                    EmptyNote(text: "No posts yet.")
                } else {
                    VStack(alignment: .leading, spacing: Theme.spaceM) {
                        ForEach(community.perPost) { post in
                            VStack(alignment: .leading, spacing: 4) {
                                PostCell(media: post.media)
                                if post.entries.isEmpty {
                                    Text("No comments fetched yet").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    Text("\(post.uniqueCount) unique commenter\(post.uniqueCount == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    BreakdownChips(items: post.entries.map {
                                        .init(label: "@\($0.label)", value: $0.value)
                                    })
                                }
                            }
                            .padding(Theme.spaceS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        }
                    }
                }
            }

            SectionCard(title: "Community Engagement Rankings",
                        subtitle: "Text comment 5 pts · text reply 7 pts · emoji comment 1 pt · emoji reply 2 pts · ×2 within 30 minutes of the post") {
                HStack {
                    Picker("Scope", selection: $rankingScope) {
                        Text(report.periodLabel).tag(RankingScope.period)
                        Text("All Time").tag(RankingScope.allTime)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer()
                    Button("Ignored Accounts…") {
                        Task { ignoredAccounts = await store.igIgnoredAccounts() }
                        showIgnored = true
                    }
                    .popover(isPresented: $showIgnored) { ignoredPopover }
                }
                if let note = community.rankingsNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                let rows = rankingScope == .allTime ? community.rankingsAllTime : community.rankingsPeriod
                if rows.isEmpty {
                    EmptyNote(text: "No ranked commenters yet.")
                } else {
                    rankingsTable(Array(rows.prefix(50)))
                }
            }

            SectionCard(title: "Followers Online Activity",
                        subtitle: community.heatmapNote ?? "When your audience comments, by weekday and hour (UTC) — a proxy for when they're online") {
                if community.heatmap.allSatisfy({ $0 == 0 }) {
                    EmptyNote(text: "No comment activity for this period yet.")
                } else {
                    CommentHeatmap(counts: community.heatmap)
                }
            }
        }
    }

    private func rankingsTable(_ rows: [IGCommenterRankingRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.spaceM, verticalSpacing: 5) {
            GridRow {
                Text("#"); Text("Username"); Text("Score"); Text("Early")
                Text("Text").help("Text comments"); Text("Emoji").help("Emoji-only comments")
                Text("Text Replies"); Text("Emoji Replies"); Text("Total")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                GridRow {
                    RankBadge(rank: index + 1)
                    Text("@\(row.username)").fontWeight(.medium)
                    Text(row.score.formatted()).monospacedDigit().foregroundStyle(ReportColors.accent)
                    Text(row.early.formatted()).monospacedDigit().foregroundStyle(ReportColors.orange)
                    Text(row.textComments.formatted()).monospacedDigit()
                    Text(row.emojiComments.formatted()).monospacedDigit()
                    Text(row.textReplies.formatted()).monospacedDigit()
                    Text(row.emojiReplies.formatted()).monospacedDigit()
                    Text(row.total.formatted()).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private var ignoredPopover: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text("Ignored Accounts").font(.headline)
            Text("Left out of the rankings and commenter lists (your own handle, bots, staff).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ignoredAccounts, id: \.self) { username in
                HStack {
                    Text("@\(username)")
                    Spacer()
                    Button {
                        store.removeIGIgnoredAccount(username)
                        ignoredAccounts.removeAll { $0 == username }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("@username", text: $newIgnored)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addIgnored)
                Button("Add", action: addIgnored)
                    .disabled(newIgnored.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func addIgnored() {
        let handle = newIgnored.trimmingCharacters(in: CharacterSet(charactersIn: "@ \n\t"))
        guard !handle.isEmpty else { return }
        store.addIGIgnoredAccount(handle)
        if !ignoredAccounts.contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) {
            ignoredAccounts.append(handle)
        }
        newIgnored = ""
    }

    // MARK: - Audience

    private func audience(_ report: InstagramReport) -> some View {
        let audience = report.audience
        let engaged = audienceScope == .engaged
        let age = engaged ? audience.engagedAge : audience.age
        let gender = engaged ? audience.engagedGender : audience.gender
        let countries = engaged ? audience.engagedCountries : audience.countries
        let cities = engaged ? audience.engagedCities : audience.cities
        let asOf = engaged ? audience.engagedAsOf : audience.asOf
        return VStack(alignment: .leading, spacing: Theme.spaceL) {
            HStack {
                Picker("Audience", selection: $audienceScope) {
                    ForEach(AudienceScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
                if let asOf {
                    Text("As of \(asOf)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: Theme.spaceL) {
                SectionCard(title: "Age Distribution", subtitle: engaged ? "Engaged audience" : "Followers") {
                    AgeBars(items: age, color: engaged ? ReportColors.pink : ReportColors.accent)
                }
                SectionCard(title: "Gender", subtitle: engaged ? "Engaged audience" : "Followers") {
                    GenderDonut(items: gender)
                }
                .frame(maxWidth: 400)
            }
            HStack(alignment: .top, spacing: Theme.spaceL) {
                SectionCard(title: "Top Countries", subtitle: "By \(engaged ? "engaged accounts" : "followers")") {
                    if countries.isEmpty { EmptyNote(text: "No country data yet.") }
                    else { HorizontalBars(items: countries, color: ReportColors.green) }
                }
                SectionCard(title: "Top Cities", subtitle: "By \(engaged ? "engaged accounts" : "followers")") {
                    if cities.isEmpty { EmptyNote(text: "No city data yet.") }
                    else { HorizontalBars(items: cities, color: ReportColors.orange) }
                }
            }
        }
    }
}
