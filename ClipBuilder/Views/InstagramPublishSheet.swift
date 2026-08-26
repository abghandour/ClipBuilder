import SwiftUI

/// Publish a Library video to the connected Instagram account as a Reel:
/// edit the caption (pre-filled with the AI's), choose feed visibility,
/// watch the upload/processing progress, and get the permalink when live.
struct InstagramPublishSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let video: GeneratedVideoRecord

    private enum Phase: Equatable {
        case idle
        case publishing
        case done(permalink: String?)
        case failed(String)
    }

    @State private var caption = ""
    @State private var shareToFeed = true
    @State private var phase: Phase = .idle
    @State private var progress: [String] = []
    @State private var publishTask: Task<Void, Never>?

    private var isPublishing: Bool { phase == .publishing }
    private var connected: Bool { store.settings.instagram.isGraphConnected }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Publish to Instagram", systemImage: "paperplane")
                    .font(.headline)
                Spacer()
                if connected {
                    Label("@\(store.settings.instagram.connectedUsername)",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(.secondary)
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
                    if !connected {
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
                        .disabled(isPublishing)
                    Text("\(caption.count)/2200")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(caption.count > 2200 ? AnyShapeStyle(.red)
                                                              : AnyShapeStyle(.tertiary))
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Toggle("Also show in the main feed", isOn: $shareToFeed)
                        .disabled(isPublishing)
                        .help("Off = the reel appears only in the Reels tab, not the profile feed")

                    if !progress.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(progress.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    switch phase {
                    case .done(let permalink):
                        HStack(spacing: 8) {
                            Label("Published", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let permalink, let url = URL(string: permalink) {
                                Link("View on Instagram", destination: url)
                            }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    default:
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                if case .done = phase {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button {
                        publish()
                    } label: {
                        if isPublishing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Publishing…")
                            }
                        } else {
                            Label("Publish Reel", systemImage: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!connected || isPublishing || caption.count > 2200)
                    .help("Upload this video to Instagram as a Reel with the caption above")
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .modalCloseButton {
            publishTask?.cancel()
            dismiss()
        }
        .onAppear { caption = video.caption }
        .onDisappear { publishTask?.cancel() }
    }

    private func publish() {
        phase = .publishing
        progress = []
        publishTask = Task {
            do {
                let result = try await store.publishReelToInstagram(
                    video: video, caption: caption, shareToFeed: shareToFeed) { message in
                    Task { @MainActor in progress.append(message) }
                }
                phase = .done(permalink: result.permalink)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.userMessage)
            }
        }
    }
}
