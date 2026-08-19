import SwiftUI
import AVKit
import Vision

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

/// Circular avatar showing a person's face, auto-cropped (Vision face
/// detection) from the frame where they first appear — Messages-style.
/// Falls back to initials over a neutral circle when no frame or face exists.
struct PersonFaceAvatar: View {
    @Environment(AppStore.self) private var store
    let person: PersonRecord
    var size: CGFloat = 44

    @State private var image: NSImage?

    private var initials: String {
        person.name.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined()
    }

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                Circle()
                    .fill(.quaternary)
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.36, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: person.id) {
            guard image == nil else { return }
            // A user-drawn marker is ground truth for who's in the box —
            // crop to it first, then find the face INSIDE it. Without this,
            // two people sharing a scene both get the frame's largest face.
            if let reference = await store.personMarkerReference(for: person.id),
               let frame = await ThumbnailService.jpegFrame(url: reference.url,
                                                            at: reference.marker.atTime,
                                                            maxDimension: 720),
               let portrait = Analyzer.markerPortrait(from: frame, marker: reference.marker) {
                image = Self.avatarImage(from: portrait,
                                         faceBox: await Self.detectFace(in: portrait))
                return
            }
            guard let scene = store.scenes.first(where: { $0.tags.contains(person.tag) })
            else { return }
            let time = (scene.startTime + scene.endTime) / 2
            guard let data = await store.thumbnails.thumbnail(for: scene.videoURL, at: time)
            else { return }
            // Detection runs off the main actor; the cheap crop stays here.
            image = Self.avatarImage(from: data, faceBox: await Self.detectFace(in: data))
        }
    }

    /// Largest detected face as a normalized bounding box (bottom-left
    /// origin, Vision convention); nil when no face is found.
    nonisolated private static func detectFace(in data: Data) async -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? [])
            .max { $0.boundingBox.width < $1.boundingBox.width }?
            .boundingBox
    }

    /// Square crop centered on the face (with generous headroom), falling
    /// back to a centered square when no face was detected.
    private static func avatarImage(from data: Data, faceBox: CGRect?) -> NSImage? {
        guard let source = NSImage(data: data),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let side: CGFloat
        let center: CGPoint
        if let faceBox {
            // Normalized bottom-left origin → pixel top-left origin.
            let face = CGRect(x: faceBox.minX * width,
                              y: (1 - faceBox.maxY) * height,
                              width: faceBox.width * width,
                              height: faceBox.height * height)
            side = min(max(face.width, face.height) * 2.2, min(width, height))
            center = CGPoint(x: face.midX, y: face.midY)
        } else {
            side = min(width, height)
            center = CGPoint(x: width / 2, y: height / 2)
        }
        let origin = CGPoint(x: min(max(0, center.x - side / 2), width - side),
                             y: min(max(0, center.y - side / 2), height - side))
        guard let cropped = cg.cropping(to: CGRect(origin: origin,
                                                   size: CGSize(width: side, height: side)))
        else { return source }
        return NSImage(cgImage: cropped, size: NSSize(width: side, height: side))
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
    /// Stop playback here (e.g. a scene's end) instead of running on to the
    /// end of the source file. Playing again restarts at `startTime`.
    var endTime: Double?

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

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
            let item = AVPlayerItem(url: url)
            if let endTime, endTime > startTime {
                item.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
            }
            let player = AVPlayer(playerItem: item)
            if startTime > 0 {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if endTime != nil {
                // Hitting the scene's end rewinds to its start (paused), so
                // pressing play replays the scene instead of running on.
                let start = startTime
                endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item, queue: .main) { [weak player] _ in
                    player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            player.play()
            self.player = player
        }
        .onDisappear {
            player?.pause()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
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

/// Single-line scene tag row: recognized people lead as small face avatars,
/// then as many whole tag chips as fit the width (never wrapped or
/// truncated), then a "+N" chip that reveals the complete tag list in a
/// popover.
struct SceneTagLine: View {
    @Environment(AppStore.self) private var store
    let tags: [String]

    @State private var showAll = false

    /// People the analyzer recognized in this scene, via their person: tags.
    private var people: [PersonRecord] {
        store.people.filter { tags.contains($0.tag) }
    }

    /// Chip row content — person: tags ride as avatars instead.
    private var chipTags: [String] {
        tags.filter { !$0.hasPrefix("person:") }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(people) { person in
                PersonFaceAvatar(person: person, size: 20)
                    .help(person.displayName)
            }
            // Candidates from "all chips" down to "just +N"; the first that
            // fits the remaining width wins.
            ViewThatFits(in: .horizontal) {
                ForEach(Array((0...chipTags.count).reversed()), id: \.self) { count in
                    chipRow(showing: count)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chipRow(showing count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(chipTags.prefix(count), id: \.self) { tag in
                TagChip(tag: tag)
                    .fixedSize()
            }
            if count < chipTags.count {
                Button {
                    showAll = true
                } label: {
                    Text("+\(chipTags.count - count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Show all \(chipTags.count) tags")
                .popover(isPresented: $showAll) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag)
                                .fixedSize()
                        }
                    }
                    .padding(12)
                    .frame(width: 300)
                }
            }
        }
        .fixedSize()
    }
}

nonisolated extension Double {
    var timecode: String {
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
