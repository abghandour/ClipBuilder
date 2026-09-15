import SwiftUI

/// The Builder monitor, its honest preview contract, and the first-run path.
struct BuilderWorkspacePreview: View {
    @Environment(AppStore.self) private var store

    let onAddClip: () -> Void

    var body: some View {
        let model = store.builder
        let seconds = Int(AppStore.exactPreviewWindow)
        let renderingForUser = store.isBuilderPreviewRendering && store.builderPreview == nil && store.builderPreviewWindow != nil
        VStack(spacing: 0) {
            ZStack {
                PreviewPane()

                if model.document.videoTrack.isEmpty {
                    ContentUnavailableView {
                        Label("Start a cut", systemImage: "film.stack")
                    } description: {
                        Text("Choose a scene from Sources, drag it here, or add one at the playhead.")
                    } actions: {
                        Button("Add a Clip", systemImage: "plus", action: onAddClip)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.88))
                } else if renderingForUser {
                    VStack(spacing: Theme.spaceS) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Rendering \(seconds) s of final footage…")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(Theme.spaceM)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Rendering the preview")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.spaceM)
        // Any timeline change invalidates slices it touched (and stops a stale playback).
        .onChange(of: model.revision) { _, _ in store.pruneBuilderPreviewCache() }
        .onDisappear { store.stopBuilderPreview() }
    }
}

/// The final-preview controls: render the next seconds from the playhead,
/// stop or cancel a run, or replay the last one. They live in the timeline
/// controls bar so the monitor keeps its full height.
struct BuilderPreviewControls: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        let seconds = Int(AppStore.exactPreviewWindow)
        let renderingForUser = store.isBuilderPreviewRendering && store.builderPreview == nil && store.builderPreviewWindow != nil
        HStack(spacing: Theme.spaceS) {
            if renderingForUser {
                Label("Rendering \(seconds) s…", systemImage: "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Cancel", role: .cancel) { store.stopBuilderPreview() }
            } else if let preview = store.builderPreview {
                Label("Final preview \(preview.window.lowerBound.timecode)–\(preview.window.upperBound.timecode)",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                Button("Stop", systemImage: "stop.fill") { store.stopBuilderPreview() }
            } else {
                if model.document.hasAnyEffect {
                    LooksPreviewBadge()
                }
                if store.builderPreviewLastPlayed != nil {
                    Button("Replay", systemImage: "arrow.counterclockwise", action: store.replayBuilderPreview)
                        .help("Play the last preview run again from where it started.")
                }
                Button("Preview \(seconds) s", systemImage: "play.fill") { store.startBuilderPreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBuilderRendering || model.document.videoTrack.isEmpty)
                    .help(store.isBuilderRendering
                          ? "Wait for the Library render to finish."
                          : "Render \(seconds) seconds of the final video from the playhead and play it in the monitor. Cached slices play at once. Nothing is added to the Library.")
            }
        }
    }
}
