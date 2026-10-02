import SwiftUI

/// Publish a Library video to the connected Instagram account as a Reel:
/// edit the caption and choose feed visibility. The store owns publishing
/// after this setup closes and keeps the permalink for review.
struct InstagramPublishSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let video: GeneratedVideoRecord

    @State private var caption = ""
    @State private var shareToFeed = true

    @State private var selectedAccountID: Int64?

    private var accounts: [IGAccountRecord] { store.instagramPublishAccounts }
    private var selectedAccount: IGAccountRecord? {
        accounts.first { $0.id == selectedAccountID } ?? store.defaultInstagramPublishAccount
    }
    private var connected: Bool { selectedAccount != nil }

    /// What the account's own numbers say about timing and hashtags.
    @ViewBuilder
    private func publishTips(_ benchmarks: AccountBenchmarks) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !benchmarks.bestPostingSlots.isEmpty {
                Label("Best times to post: " + benchmarks.bestPostingSlots.map(\.label).joined(separator: ", ")
                      + " (your local time — where this account's reels reached the most)",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if benchmarks.topHashtags.contains(where: { $0.lift >= 1 }) {
                HStack(spacing: 8) {
                    Button("Add Top Hashtags") { addTopHashtags(benchmarks) }
                        .lineLimit(1)
                        .fixedSize()
                        .controlSize(.small)
                        .help("Appends the hashtags that ride this account's best-reaching posts")
                    Text(benchmarks.topHashtags.filter { $0.lift >= 1 }.prefix(5).map(\.tag).joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func addTopHashtags(_ benchmarks: AccountBenchmarks) {
        let present = Set(ReportHTML.matches(#"(#[\p{L}0-9_]+)"#, in: caption).map { $0[0].lowercased() })
        let missing = benchmarks.topHashtags.filter { $0.lift >= 1 }.prefix(6).map(\.tag)
            .filter { !present.contains($0.lowercased()) }
        guard !missing.isEmpty else { return }
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            + (caption.isEmpty ? "" : "\n") + missing.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Publish to Instagram", systemImage: "paperplane")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                if accounts.count > 1 {
                    Picker("Account", selection: $selectedAccountID) {
                        ForEach(accounts) { account in
                            Text("@\(account.username)").tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .lineLimit(1)
                    .fixedSize()
                    .help("The account this reel publishes to")
                } else if let account = selectedAccount {
                    Label("@\(account.username)", systemImage: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("The connected account this reel publishes to")
                }
            }
            .padding(16)
            Divider()

            HStack(alignment: .top, spacing: 16) {
                VideoThumbnail(url: video.url, time: min(0.5, video.duration / 2))
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(width: 160)
                    .overlay(alignment: .bottomTrailing) {
                        DurationBadge(seconds: video.duration)
                    }

                VStack(alignment: .leading, spacing: 10) {
                    if !connected, store.settings.instagram.isGraphConnected {
                        Label("Add a connected account on the Instagram screen first to publish from this profile.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if !connected {
                        Label("No Instagram account is connected. Connect a business/creator account in Settings → Instagram (the token needs the instagram_content_publish permission).",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    Text("Caption")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextEditor(text: $caption)
                        .font(.body)
                        .frame(minHeight: 100, maxHeight: 160)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    Text("\(caption.count)/2200")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(caption.count > 2200 ? AnyShapeStyle(.red)
                                                              : AnyShapeStyle(.tertiary))
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Toggle("Also show in the main feed", isOn: $shareToFeed)
                        .help("Off = the reel appears only in the Reels tab, not the profile feed")

                    if let benchmarks = store.igBenchmarks,
                       selectedAccount?.username.caseInsensitiveCompare(benchmarks.username) == .orderedSame {
                        publishTips(benchmarks)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                Spacer()
                Button("Publish Reel", systemImage: "paperplane.fill", action: publish)
                    .lineLimit(1)
                    .fixedSize()
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!connected || store.isPublishingToInstagram || caption.count > 2200)
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .onAppear {
            caption = video.caption
            selectedAccountID = store.defaultInstagramPublishAccount?.id
        }
        .onChange(of: accounts.map(\.id)) {
            selectedAccountID = selectedAccount?.id
        }
    }

    private func publish() {
        guard let account = selectedAccount else { return }
        let store = store
        let video = video, caption = caption, shareToFeed = shareToFeed
        store.jobs.start(.instagramPublish, title: "Publish to Instagram — \(video.filename)",
                         project: store.activeProject, profileGeneration: store.profileGeneration,
                         subjectID: "publish") { log in
            let result = try await store.publishReelToInstagram(video: video, caption: caption,
                                                                shareToFeed: shareToFeed, account: account, log: log)
            return .instagramPublished(permalink: result.permalink.flatMap { URL(string: $0) })
        }
        dismiss()
    }
}
