import SwiftUI

/// Generated-videos library: browse, play, copy captions, leave wizard
/// feedback, delete.
struct LibraryView: View {
    @Environment(AppStore.self) private var store

    private enum SortOrder: String, CaseIterable {
        case newest = "Newest"
        case longest = "Longest"
        case shortest = "Shortest"
    }

    @State private var sortOrder: SortOrder = .newest
    @State private var playing: GeneratedVideoRecord?
    @State private var deleting: GeneratedVideoRecord?
    @State private var feedbackTarget: GeneratedVideoRecord?
    @State private var feedbackText = ""

    private var sorted: [GeneratedVideoRecord] {
        switch sortOrder {
        case .newest: return store.generatedVideos
        case .longest: return store.generatedVideos.sorted { $0.duration > $1.duration }
        case .shortest: return store.generatedVideos.sorted { $0.duration < $1.duration }
        }
    }

    var body: some View {
        Group {
            if store.generatedVideos.isEmpty {
                ContentUnavailableView(
                    "No Generated Videos",
                    systemImage: "film.stack",
                    description: Text("Videos created by the AI Wizard will appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(sorted) { video in
                            card(for: video)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle("\(store.generatedVideos.count) videos")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .sheet(item: $playing) { video in
            PlayerSheet(url: video.url, title: video.filename)
        }
        .sheet(item: $feedbackTarget) { video in
            feedbackSheet(for: video)
        }
        .confirmationDialog(
            "Delete \(deleting?.filename ?? "video")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Remove from Library and Delete File", role: .destructive) {
                if let deleting { store.deleteGeneratedVideo(deleting, removeFile: true) }
                deleting = nil
            }
            Button("Remove from Library Only") {
                if let deleting { store.deleteGeneratedVideo(deleting, removeFile: false) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    @ViewBuilder
    private func card(for video: GeneratedVideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                playing = video
            } label: {
                VideoThumbnail(url: video.url, time: min(0.5, video.duration / 2))
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(video.duration.timecode)
                            .font(.caption2.monospacedDigit())
                            .padding(4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)

            Text(video.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if let generatedAt = video.generatedAt {
                Text(generatedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !video.caption.isEmpty {
                Text(video.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if !video.caption.isEmpty {
                    Button("Copy Caption", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(video.caption, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy the Instagram caption")
                }
                Button("Feedback", systemImage: "bubble.left") {
                    feedbackText = ""
                    feedbackTarget = video
                }
                .labelStyle(.iconOnly)
                .help("Tell the wizard what you thought — it reads this next run")

                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([video.url])
                }
                .labelStyle(.iconOnly)

                Spacer()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleting = video
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Open in Builder") {
                store.openInBuilder(video)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([video.url])
            }
        }
    }

    @ViewBuilder
    private func feedbackSheet(for video: GeneratedVideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feedback for \(video.filename)")
                .font(.headline)
            Text("The wizard treats feedback as hard constraints for future generations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $feedbackText)
                .font(.body)
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { feedbackTarget = nil }
                Button("Save Feedback") {
                    store.addFeedback(for: video, text: feedbackText)
                    feedbackTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
