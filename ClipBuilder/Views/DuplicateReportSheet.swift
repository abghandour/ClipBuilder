import SwiftUI

/// Duplicate scan report: groups of videos the AI judged to be the same
/// footage imported more than once, with a KEEP badge on the recommended
/// copy. Report-only — nothing is deleted; Reveal in Finder hands the
/// cleanup decision to the user.
struct DuplicateReportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isRunning = false
    @State private var statusLine = ""
    @State private var errorMessage: String?
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var groups: [DuplicateFinder.Group]?

    private var videosByID: [Int64: VideoRecord] {
        Dictionary(uniqueKeysWithValues: store.videos.map { ($0.id, $0) })
    }

    var body: some View {
        Group {
            if let groups {
                report(groups)
            } else {
                setup
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 280, idealHeight: 400)
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "dedupe",
                                                        available: availableProviders)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan for Duplicates")
                .font(.title3.bold())
            Text("Compares the library's \(store.videos.count) videos — metadata plus one frame each — and reports footage imported more than once (re-downloads, different resolutions, shorter cuts), recommending which copy to keep. Nothing is deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ModelPicker(title: "Model", task: "dedupe", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusLine.isEmpty ? "Comparing videos…" : statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isRunning ? "Scanning…" : "Scan Library") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || store.videos.count < 2)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func report(_ groups: [DuplicateFinder.Group]) -> some View {
        if groups.isEmpty {
            ContentUnavailableView("No duplicates found",
                                   systemImage: "checkmark.circle",
                                   description: Text("Every video in the library looks like distinct footage."))
                .padding()
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text("KEEP marks the recommended copy. Nothing is deleted — reveal a lesser copy in Finder to clean up yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                if !group.reason.isEmpty {
                                    Text(group.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(group.videoIDs, id: \.self) { videoID in
                                    if let video = videosByID[videoID] {
                                        HStack(spacing: 10) {
                                            VideoThumbnail(url: video.url, time: video.duration / 2)
                                                .frame(width: 72, height: 40)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(video.filename)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                Text("\(video.width)×\(video.height) · \(video.duration.timecode)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if videoID == group.keepID {
                                                Text("KEEP")
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(.green.opacity(0.2),
                                                                in: Capsule())
                                                    .foregroundStyle(.green)
                                            }
                                            Button("Reveal", systemImage: "folder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([video.url])
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.borderless)
                                            .help("Show this file in Finder")
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom)
            }
        }
    }

    private func run() {
        let (provider, model) = ModelPicker.parse(modelTag)
        isRunning = true
        errorMessage = nil
        Task {
            do {
                groups = try await store.findDuplicateVideos(
                    provider: provider, model: model) { message in
                    if let line = AIProgressLine.from(message) { Task { @MainActor in statusLine = line } }
                }
            } catch {
                errorMessage = error.userMessage
            }
            isRunning = false
        }
    }
}
