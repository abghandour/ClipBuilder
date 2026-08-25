import SwiftUI
import AVKit

/// Instagram tab: browse reels (with stats) for saved accounts — the user's
/// own or any public account — and turn a high performer into a structural
/// template for the AI Wizard.
struct InstagramView: View {
    @Environment(AppStore.self) private var store

    private enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case views = "Views"
        case likes = "Likes"
        case comments = "Comments"
        case quality = "Quality"
        var id: String { rawValue }
    }

    @State private var sortOrder: SortOrder = .recent
    @State private var addingAccount = false
    @State private var removingAccount: IGAccountRecord?
    @State private var newHandle = ""
    @State private var detailMedia: IGMediaRecord?
    /// Reels ticked for batch taste learning (the Learn toolbar menu).
    @State private var learnSelection: Set<Int64> = []
    /// Reels that already taught the taste profile — badge on their cards.
    @State private var studiedIDs: Set<Int64> = []

    private var sortedMedia: [IGMediaRecord] {
        switch sortOrder {
        case .recent:
            return store.igMedia   // already posted_at DESC from the DB
        case .views:
            return store.igMedia.sorted { ($0.stats.views ?? -1) > ($1.stats.views ?? -1) }
        case .likes:
            return store.igMedia.sorted { ($0.stats.likes ?? -1) > ($1.stats.likes ?? -1) }
        case .comments:
            return store.igMedia.sorted { ($0.stats.comments ?? -1) > ($1.stats.comments ?? -1) }
        case .quality:
            return store.igMedia.sorted { ReelPerformance.score($0.stats) > ReelPerformance.score($1.stats) }
        }
    }

    private var selectedAccount: IGAccountRecord? {
        store.igAccounts.first { $0.id == store.igSelectedAccountID }
    }

    var body: some View {
        Group {
            if store.igAccounts.isEmpty {
                onboarding
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Instagram")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $addingAccount) { addAccountSheet }
        .sheet(item: $detailMedia) { media in
            InstagramDetailSheet(media: media, account: selectedAccount)
        }
        .task { studiedIDs = await store.tasteStudiedMediaIDs() }
        .onChange(of: store.isStudyingTaste) { _, running in
            if !running {
                Task { studiedIDs = await store.tasteStudiedMediaIDs() }
            }
        }
        .confirmationDialog("Remove @\(removingAccount?.username ?? "")?",
                            isPresented: Binding(get: { removingAccount != nil },
                                                 set: { if !$0 { removingAccount = nil } })) {
            Button("Remove Account", role: .destructive) {
                if let account = removingAccount { store.removeInstagramAccount(account) }
                removingAccount = nil
            }
            Button("Cancel", role: .cancel) { removingAccount = nil }
        } message: {
            Text("The account's fetched reels, stats, and cached templates are removed from the app. Learned taste lessons are kept.")
        }
    }

    private func learnSelected() {
        let items = sortedMedia.filter { learnSelection.contains($0.id) }
        store.learnFromReels(items)
        learnSelection = []
    }

    private func learnTopPerformers() {
        let top = sortedMedia
            .sorted { ReelPerformance.score($0.stats) > ReelPerformance.score($1.stats) }
            .prefix(5)
        store.learnFromReels(Array(top))
    }

    private var subtitle: String {
        guard let account = selectedAccount else { return "No account" }
        var text = "@\(account.username)"
        if let followers = account.followers {
            text += " · \(followers.compactFormatted) followers"
        }
        return text
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Account", selection: Binding(
                    get: { store.igSelectedAccountID },
                    set: { store.selectInstagramAccount($0) }
                )) {
                    ForEach(store.igAccounts) { account in
                        Label("@\(account.username)",
                              systemImage: account.isOwn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .tag(Int64?.some(account.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Add Account…") { addingAccount = true }
                if let account = selectedAccount {
                    Button("Remove @\(account.username)…", role: .destructive) {
                        removingAccount = account
                    }
                }
            } label: {
                Text("Accounts")
            }
            .help("Switch, add, or remove accounts")
        }
        ToolbarItem {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort: \(sortOrder.rawValue)")
            }
            .help("Order reels by recency or performance")
        }
        ToolbarItem {
            Menu {
                Button("Learn from Selected (\(learnSelection.count))") { learnSelected() }
                    .disabled(learnSelection.isEmpty || store.isStudyingTaste)
                Button("Learn from Top 5 Quality Reels") { learnTopPerformers() }
                    .disabled(store.isStudyingTaste || sortedMedia.isEmpty)
                if !learnSelection.isEmpty {
                    Divider()
                    Button("Clear Selection") { learnSelection = [] }
                }
            } label: {
                if store.isStudyingTaste {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Learning…")
                    }
                } else {
                    Label("Learn", systemImage: "graduationcap")
                }
            }
            .help("Teach the taste profile from reels: tick reels with the circle on each card, or learn from the five strongest normalized save/share/comment performers. Each reel is classified into a video type (fight highlights, interviews, …) whose rubric it refines.")
        }
        ToolbarItem(placement: .primaryAction) {
            if store.isFetchingInstagram {
                Button {
                    store.cancelInstagramFetch()
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Stop")
                    }
                }
                .help(store.igLog.last ?? "Fetching…")
            } else {
                Button {
                    if let account = selectedAccount {
                        store.refreshInstagram(username: account.username)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(selectedAccount == nil)
                .help("Fetch the latest reels and stats")
            }
        }
    }

    private var onboarding: some View {
        ContentUnavailableView {
            Label("Instagram", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Browse reels and their stats from your account or any public account, then use a high performer as a template for your next video.\n\nFetching works best with browser cookies configured in Settings → Instagram.")
        } actions: {
            Button("Add Account…") { addingAccount = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            if sortedMedia.isEmpty && !store.isFetchingInstagram {
                ContentUnavailableView("No Reels Yet", systemImage: "play.rectangle.on.rectangle",
                                       description: Text("Press Refresh to fetch reels for this account."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)],
                          spacing: 16) {
                    ForEach(sortedMedia) { media in
                        let selected = learnSelection.contains(media.id)
                        ReelCard(media: media,
                                 analyzed: store.igTemplatedMediaIDs.contains(media.id))
                            .onTapGesture { detailMedia = media }
                            .overlay(alignment: .topLeading) {
                                Button {
                                    if selected {
                                        learnSelection.remove(media.id)
                                    } else {
                                        learnSelection.insert(media.id)
                                    }
                                } label: {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, selected ? Color.accentColor
                                                                          : Color.black.opacity(0.45))
                                        .shadow(radius: 2)
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                                .help("Select for taste learning (Learn menu in the toolbar)")
                            }
                            .overlay(alignment: .topTrailing) {
                                if studiedIDs.contains(media.id) {
                                    Image(systemName: "graduationcap.fill")
                                        .font(.caption)
                                        .padding(5)
                                        .background(.purple.opacity(0.85), in: Circle())
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                        .help("This reel has taught the taste profile")
                                }
                            }
                    }
                }
                .padding()
            }
            if store.isFetchingInstagram, let last = store.igLog.last {
                HStack(spacing: 8) {
                    Text(last)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    LogActions(lines: store.igLog) { store.igLog = [] }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Instagram Account")
                .font(.headline)
            TextField("@handle", text: $newHandle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(submitNewHandle)
            Text("Your own handle or any public account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    addingAccount = false
                    newHandle = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") { submitNewHandle() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newHandle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func submitNewHandle() {
        let handle = newHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        store.addInstagramAccount(handle: handle)
        addingAccount = false
        newHandle = ""
    }
}

/// One reel in the grid: cached thumbnail, duration badge, stats, caption.
private struct ReelCard: View {
    let media: IGMediaRecord
    let analyzed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if media.duration > 0 {
                    DurationBadge(seconds: media.duration)
                }
            }
            .overlay(alignment: .topLeading) {
                if analyzed {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white, .green)
                        .padding(6)
                        .help("Template analyzed")
                }
            }

            statsRow

            if !media.caption.isEmpty {
                Text(media.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let posted = media.postedAt {
                Text(posted.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = media.thumbnailURL, let image = NSImage(contentsOf: url) {
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "play.rectangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            if let views = media.stats.views {
                statBadge("eye", views)
            }
            if let likes = media.stats.likes {
                statBadge("heart", likes)
            }
            if let comments = media.stats.comments {
                statBadge("bubble.right", comments)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func statBadge(_ symbol: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(count.compactFormatted)
                .monospacedDigit()
        }
    }
}

/// Detail sheet: player (when downloaded) or thumbnail, full caption + stats,
/// and the template actions (Analyze → Create with Wizard).
private struct InstagramDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let media: IGMediaRecord
    let account: IGAccountRecord?

    @State private var player: AVPlayer?
    /// Category key this reel's taste study landed in (nil = never studied).
    @State private var studiedCategoryKey: String?
    /// "provider|model" for AI actions in this sheet; "" = automatic.
    @State private var modelChoice = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    /// Cached template analysis, decoded for the summary section.
    @State private var template: ReelTemplate?
    /// Local file once downloaded (tracked here because `media` is a snapshot).
    @State private var localURL: URL?

    private var modelOverride: (provider: String?, model: String?) {
        ModelPicker.parse(modelChoice)
    }

    private var studiedCategoryLabel: String? {
        guard let key = studiedCategoryKey else { return nil }
        return store.activeProfile.tasteCategories.first { $0.key == key }?.label
            ?? key.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(account.map { "@\($0.username)" } ?? "Reel")
                        .font(.headline)
                    if let posted = media.postedAt {
                        Text(posted.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let player {
                        PlayerView(player: player)
                    } else if let url = media.thumbnailURL, let image = NSImage(contentsOf: url) {
                        // The still is the link: click-through to Instagram.
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.title3)
                                    .padding(6)
                                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let permalink = media.permalink, let url = URL(string: permalink) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .help("Open on Instagram")
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 300, height: 533)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 12) {
                    statsGrid
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(media.caption.isEmpty ? "No caption" : media.caption)
                                .font(.callout)
                                .foregroundStyle(media.caption.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let template {
                                Divider()
                                templateSummary(template)
                            }
                        }
                    }
                    Divider()
                    templateActions
                }
                .frame(width: 280)
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear {
            localURL = media.localVideoURL
            if let url = localURL {
                let player = AVPlayer(url: url)
                player.play()
                self.player = player
            }
        }
        .onDisappear { player?.pause() }
        .onExitCommand { dismiss() }
        .task {
            studiedCategoryKey = await store.tasteStudyCategory(mediaID: media.id)
            template = await store.instagramTemplate(mediaID: media.id)
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
        }
        .onChange(of: store.isStudyingTaste) { _, running in
            guard !running else { return }
            Task { studiedCategoryKey = await store.tasteStudyCategory(mediaID: media.id) }
        }
        .onChange(of: isAnalyzing) { _, running in
            guard !running else { return }
            Task { template = await store.instagramTemplate(mediaID: media.id) }
        }
    }

    private var isAnalyzing: Bool { store.igAnalyzingMediaIDs.contains(media.id) }
    private var isDownloading: Bool { store.igDownloadingMediaIDs.contains(media.id) }
    private var hasTemplate: Bool { store.igTemplatedMediaIDs.contains(media.id) }

    /// What the analysis distilled — hook, pacing, structure — so the
    /// template can be judged before generating anything from it.
    private func templateSummary(_ template: ReelTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Template", systemImage: "checkmark.seal.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
            summaryRow("Hook", "\(template.hook.type) — \(template.hook.description)")
            summaryRow("Pacing", "\(template.cutCount) cuts"
                + " (\(template.cutsPerMinute.formatted(.number.precision(.fractionLength(0...1))))/min)"
                + " · \(template.pacingCurve)")
            if !template.structure.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Structure").font(.caption2.bold()).foregroundStyle(.secondary)
                    ForEach(Array(template.structure.enumerated()), id: \.offset) { _, phase in
                        Text("\(phase.start.timecode)–\(phase.end.timecode)  \(phase.phase): \(phase.description)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            summaryRow("Why it works", template.whyItWorks)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(trimmed).font(.caption2)
            }
        }
    }

    /// Analyze → template ready → Generate Video.
    @ViewBuilder
    private var templateActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isAnalyzing {
                ModelPicker(title: "Model", task: "analysis", selection: $modelChoice,
                            includeAutomatic: true, availableProviders: availableProviders)
                    .controlSize(.small)
                    .help("Model used when analyzing this reel or learning from it")
            }
            if isAnalyzing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.igLog.last ?? "Analyzing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") { store.cancelInstagramAnalysis(mediaID: media.id) }
                        .controlSize(.small)
                }
            } else if hasTemplate {
                HStack {
                    Button {
                        store.useTemplateInWizard(media: media)
                        dismiss()
                    } label: {
                        Label("Generate Video", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        store.useTemplateInBuilder(media: media)
                        dismiss()
                    } label: {
                        Label("Edit Video", systemImage: "timeline.selection")
                    }
                    .help("Plan a timeline from this template and edit it manually")
                }
                Button("Re-analyze") {
                    store.analyzeInstagramTemplate(media: media, force: true,
                                                   provider: modelOverride.provider,
                                                   model: modelOverride.model)
                }
                .controlSize(.small)
                tasteButton
                fileActions
            } else {
                Button {
                    store.analyzeInstagramTemplate(media: media,
                                                   provider: modelOverride.provider,
                                                   model: modelOverride.model)
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                Text("Downloads the reel and studies its hook, pacing, and structure so the Wizard can replicate them with your footage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tasteButton
                fileActions
            }
        }
    }

    /// Study this reel as a taste exemplar — independent of the template
    /// analysis, so it's offered in both states.
    @ViewBuilder
    private var tasteButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = studiedCategoryLabel {
                Label("In taste profile · \(label)", systemImage: "graduationcap.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .help("This reel has already taught the taste profile — its lessons live in the \"\(label)\" video type (Settings → Taste)")
            }
            HStack(spacing: 6) {
                Button(studiedCategoryKey == nil ? "Learn from This Reel" : "Learn Again",
                       systemImage: "graduationcap") {
                    store.studyTasteExemplar(media: media,
                                             provider: modelOverride.provider,
                                             model: modelOverride.model)
                }
                .disabled(store.isStudyingTaste)
                .help("Teach the taste profile from this reel — what makes its moments good is distilled into a video-type rubric (Settings → Taste) that guides every analysis and generation")
                if store.isStudyingTaste {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .controlSize(.small)
        }
    }

    /// Local-file row: download for inline playback, then reveal in Finder.
    @ViewBuilder
    private var fileActions: some View {
        HStack(spacing: 6) {
            if let localURL {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                }
                .help("Reveal the downloaded reel file")
            } else if isDownloading {
                ProgressView().controlSize(.small)
                Text(store.igLog.last ?? "Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task {
                        if let url = await store.downloadInstagramReel(media: media) {
                            localURL = url
                            let player = AVPlayer(url: url)
                            player.play()
                            self.player = player
                        }
                    }
                }
                .help("Download the reel for inline playback without analyzing it")
            }
        }
        .controlSize(.small)
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            statRow("Views", media.stats.views)
            statRow("Likes", media.stats.likes)
            statRow("Comments", media.stats.comments)
            if media.source == "graph" {
                statRow("Reach", media.stats.reach)
                statRow("Saves", media.stats.saves)
                statRow("Shares", media.stats.shares)
            }
            if media.duration > 0 {
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(media.duration.timecode).monospacedDigit()
                }
            }
            if let rank = viewsRank {
                GridRow {
                    Text("Rank").foregroundStyle(.secondary)
                    Text(rank)
                        .help("Where this reel's view count sits among the account's fetched reels — engagement like this also weights taste learning")
                }
            }
        }
        .font(.callout)
    }

    /// "#3 of 42 by views · top 7%" among the account's fetched reels.
    private var viewsRank: String? {
        guard let views = media.stats.views else { return nil }
        let counts = store.igMedia.compactMap(\.stats.views)
        guard counts.count >= 5 else { return nil }
        let rank = counts.filter { $0 > views }.count + 1
        let percent = max(1, Int((Double(rank) / Double(counts.count) * 100).rounded()))
        return "#\(rank) of \(counts.count) by views · top \(percent)%"
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: Int?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value.formatted()).monospacedDigit()
            }
        }
    }
}
