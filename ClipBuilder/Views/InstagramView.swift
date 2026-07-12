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
        var id: String { rawValue }
    }

    @State private var sortOrder: SortOrder = .recent
    @State private var addingAccount = false
    @State private var newHandle = ""
    @State private var detailMedia: IGMediaRecord?

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
            .pickerStyle(.menu)
        }
        ToolbarItem {
            Menu {
                Button("Add Account…") { addingAccount = true }
                if let account = selectedAccount {
                    Button("Remove @\(account.username)", role: .destructive) {
                        store.removeInstagramAccount(account)
                    }
                }
            } label: {
                Label("Accounts", systemImage: "person.badge.plus")
            }
        }
        ToolbarItem {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
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
                        ReelCard(media: media,
                                 analyzed: store.igTemplatedMediaIDs.contains(media.id))
                            .onTapGesture { detailMedia = media }
                    }
                }
                .padding()
            }
            if store.isFetchingInstagram, let last = store.igLog.last {
                Text(last)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
                Button("Add") { submitNewHandle() }
                    .buttonStyle(.borderedProminent)
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
                    Text(media.duration.timecode)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
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
                if let permalink = media.permalink, let url = URL(string: permalink) {
                    Link("Open on Instagram", destination: url)
                        .font(.caption)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let player {
                        PlayerView(player: player)
                    } else if let url = media.thumbnailURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
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
                        Text(media.caption.isEmpty ? "No caption" : media.caption)
                            .font(.callout)
                            .foregroundStyle(media.caption.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    templateActions
                }
                .frame(width: 280)
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear {
            if let url = media.localVideoURL {
                let player = AVPlayer(url: url)
                player.play()
                self.player = player
            }
        }
        .onDisappear { player?.pause() }
    }

    private var isAnalyzing: Bool { store.igAnalyzingMediaIDs.contains(media.id) }
    private var hasTemplate: Bool { store.igTemplatedMediaIDs.contains(media.id) }

    /// Analyze → template ready → Create with Wizard.
    @ViewBuilder
    private var templateActions: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Label("Template ready", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                HStack {
                    Button("Create with Wizard") {
                        store.useTemplateInWizard(media: media)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Pre-fill Builder") {
                        store.useTemplateInBuilder(media: media)
                        dismiss()
                    }
                    .help("Plan a timeline from this template and edit it manually")
                }
                Button("Re-analyze") {
                    store.analyzeInstagramTemplate(media: media, force: true)
                }
                .controlSize(.small)
            } else {
                Button("Analyze as Template") {
                    store.analyzeInstagramTemplate(media: media)
                }
                .buttonStyle(.borderedProminent)
                Text("Downloads the reel and studies its hook, pacing, and structure so the Wizard can replicate them with your footage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
        }
        .font(.callout)
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
