import SwiftUI
import AVKit

/// Async, disk-cached video frame thumbnail.
struct VideoThumbnail: View {
    @Environment(AppStore.self) private var store
    let url: URL
    let time: Double
    var cornerRadius: CGFloat = 6

    @State private var image: NSImage?

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
            guard image == nil else { return }
            if let data = await store.thumbnails.thumbnail(for: url, at: time),
               let loaded = NSImage(data: data) {
                image = loaded
            }
        }
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

            VideoPlayer(player: player)
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
