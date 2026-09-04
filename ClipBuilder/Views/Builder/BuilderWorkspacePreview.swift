import SwiftUI

/// The Builder monitor, its honest preview contract, and the first-run path.
struct BuilderWorkspacePreview: View {
    @Environment(AppStore.self) private var store

    let onOpenPreview: () -> Void
    let onAddClip: () -> Void

    var body: some View {
        let model = store.builder
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
                } else if !isCropEditing {
                    PreviewPlayButton(action: onOpenPreview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !model.document.videoTrack.isEmpty {
                HStack(spacing: Theme.spaceS) {
                    Label("Fast Preview — approximate", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Use Render Preview for framing, captions, transitions, and overlays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.spaceS)
                    Button("Preview", systemImage: "play.fill", action: onOpenPreview)
                        .controlSize(.small)
                }
                .padding(.horizontal, Theme.spaceS)
                .padding(.vertical, Theme.spaceXS)
                .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
        }
        .padding(Theme.spaceM)
    }

    /// Mirrors PreviewPane's crop-editor condition so the playback affordance
    /// never covers crop rectangles.
    private var isCropEditing: Bool {
        let model = store.builder
        if case .clip(let uid) = model.selection,
           let clip = model.clip(uid), clip.freeCrops?.isEmpty == false {
            return true
        }
        return false
    }
}
