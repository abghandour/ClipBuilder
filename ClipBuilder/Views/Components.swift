import SwiftUI
import AVKit

/// Live log lines in an isolated view: it reads the store array through a
/// key path in its own body, so per-line appends invalidate just this view
/// instead of the whole surrounding screen.
struct ActivityLogView: View {
    @Environment(AppStore.self) private var store
    let lines: KeyPath<AppStore, [String]>

    var body: some View {
        let log = store[keyPath: lines]
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: log.count) {
                proxy.scrollTo(log.count - 1, anchor: .bottom)
            }
        }
    }
}

/// Async, disk-cached video frame thumbnail.
struct VideoThumbnail: View {
    @Environment(AppStore.self) private var store
    let url: URL
    let time: Double
    var cornerRadius: CGFloat = 6

    @State private var image: NSImage?
    @State private var loadedKey: String?

    var body: some View {
        ZStack {
            if let image {
                // Color.clear adopts exactly the proposed size; the overlay
                // draws the aspect-fill image within it without inflating the
                // view's own layout size the way a bare .fill image does.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(url.path)|\(time)") {
            // Track which key is loaded rather than guarding on image ==
            // nil, which froze the thumbnail on its first frame when the
            // same view was later given a different time (preview scrub).
            let key = "\(url.path)|\(time)"
            guard loadedKey != key else { return }
            if let data = await store.thumbnails.thumbnail(for: url, at: time),
               let loaded = NSImage(data: data) {
                image = loaded
                loadedKey = key
            }
        }
    }
}

/// AVPlayerView wrapper used instead of SwiftUI's VideoPlayer, which crashes
/// at runtime on macOS 27 betas (the _AVKit_SwiftUI shim fails to resolve the
/// AVPlayerView superclass metadata and aborts). Referencing AVPlayerView
/// directly also guarantees AVKit is linked into the process.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Modal player used by both the Library and the scene browser.
struct PlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String
    var startTime: Double = 0

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            PlayerView(player: player)
                .frame(minWidth: 420, minHeight: 560)
        }
        .onAppear {
            let player = AVPlayer(url: url)
            if startTime > 0 {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
            }
            player.play()
            self.player = player
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// Small rounded tag chip.
struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// Flowing tag list (wraps onto multiple lines).
struct TagWrap: View {
    let tags: [String]
    var limit = 6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(limit), id: \.self) { tag in
                TagChip(tag: tag)
            }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

nonisolated extension Double {
    var timecode: String {
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
