import SwiftUI

/// The Builder monitor, its honest preview contract, and the first-run path.
struct BuilderWorkspacePreview: View {
    @Environment(AppStore.self) private var store

    let onAddClip: () -> Void

    var body: some View {
        let model = store.builder
        let seconds = Int(AppStore.exactPreviewWindow)
        let renderingForUser = store.isBuilderPreviewRendering && store.builderPreview == nil && store.builderPreviewWindow != nil
        VStack(spacing: Theme.spaceS) {
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

            if !model.document.videoTrack.isEmpty {
                HStack(spacing: Theme.spaceS) {
                    if let window = store.builderPreviewWindow, renderingForUser {
                        Label("Rendering \(seconds) s of final footage from \(window.lowerBound.timecode)…", systemImage: "hourglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.spaceS)
                        Button("Cancel", role: .cancel) { store.stopBuilderPreview() }
                            .controlSize(.small)
                    } else if let preview = store.builderPreview {
                        Label("Final preview \(preview.window.lowerBound.timecode)–\(preview.window.upperBound.timecode)",
                              systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                        Text(store.isBuilderPreviewRendering
                             ? "Rendering the next \(seconds) s ahead…"
                             : "Framing, captions, transitions, music and overlays as they will export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.spaceS)
                        Button("Stop", systemImage: "stop.fill") { store.stopBuilderPreview() }
                            .controlSize(.small)
                    } else {
                        if let played = store.builderPreviewLastPlayed {
                            Label("Played \(played.lowerBound.timecode)–\(played.upperBound.timecode)", systemImage: "checkmark.seal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Monitor — layout approximation", systemImage: "rectangle.dashed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if model.document.hasAnyEffect {
                            LooksPreviewBadge()
                        }
                        Text("Preview renders \(seconds) s of final footage from the playhead and plays it here. Nothing is added to the Library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.spaceS)
                        if store.builderPreviewLastPlayed != nil {
                            Button("Replay", systemImage: "arrow.counterclockwise", action: store.replayBuilderPreview)
                                .controlSize(.small)
                                .help("Play the last preview run again from where it started.")
                        }
                        Button("Preview \(seconds) s", systemImage: "play.fill") { store.startBuilderPreview() }
                            .controlSize(.small)
                            .disabled(store.isBuilderRendering)
                            .help(store.isBuilderRendering
                                  ? "Wait for the Library render to finish."
                                  : "Render \(seconds) seconds of the final video from the playhead and play it in the monitor. Cached slices play at once. Nothing is added to the Library.")
                    }
                }
                .padding(.horizontal, Theme.spaceS)
                .padding(.vertical, Theme.spaceXS)
                .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
        }
        .padding(Theme.spaceM)
        // Any timeline change invalidates slices it touched (and stops a stale playback).
        .onChange(of: model.revision) { _, _ in store.pruneBuilderPreviewCache() }
        .onDisappear { store.stopBuilderPreview() }
    }
}
