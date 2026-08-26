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

/// Copy + clear buttons for a log panel header — used beside every
/// Activity/Wizard log the app shows.
struct LogActions: View {
    let lines: [String]
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy the whole log to the clipboard")
            Button(role: .destructive) {
                clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear the log")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(lines.isEmpty)
    }
}

/// Icon + text label for toolbar bubble buttons. Toolbars render plain Label
/// buttons icon-only regardless of labelStyle, so this spells the content
/// out — with breathing room so the text doesn't touch the bubble edges.
struct ToolbarBubbleLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .padding(.horizontal, 6)
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
    /// Whose face `image` holds — the same view instance can be handed a
    /// different person (e.g. the People detail header on selection change).
    @State private var loadedPersonID: Int64?

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
            guard loadedPersonID != person.id else { return }
            image = nil
            loadedPersonID = person.id
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
        .modalCloseButton { dismiss() }
        .onAppear {
            let item = AVPlayerItem(url: url)
            if let endTime, endTime > startTime {
                item.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
            }
            let player = AVPlayer(playerItem: item)
            if startTime > 0 {
                // Seeking before the item is ready gets dropped, leaving the
                // poster on the file's first frame — wait for readiness so
                // the still shows the scene's actual start.
                let target = CMTime(seconds: startTime, preferredTimescale: 600)
                Task { [weak player, weak item] in
                    for _ in 0..<100 where item?.status != .readyToPlay {
                        if item?.status == .failed { return }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    await player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
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

/// Bare AVPlayerLayer host — no controls — for inline playback inside cards.
final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct InlinePlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// Scene playback in place of the card thumbnail: click to play exactly the
/// scene's [start, end] range, click again — or let it finish — to return
/// to the thumbnail. Wide scenes honor the analyzer's suggested 9:16 crop
/// position when one was recorded, so the preview shows the scene the way
/// it would crop in a reel.
struct SceneInlinePlayer: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            // Stays underneath as the poster while the player gets ready.
            VideoThumbnail(url: scene.videoURL, time: (scene.startTime + scene.endTime) / 2)
            if let player {
                GeometryReader { proxy in
                    let size = proxy.size
                    if scene.wide, let path = scene.centerStagePath {
                        // The stored Center Stage path: animate the visible
                        // window along the recorded pan/zoom keyframes, so
                        // the preview plays the actual moving camera.
                        SwiftUI.TimelineView(.animation) { _ in
                            let t = player.currentTime().seconds - scene.startTime
                            if let crop = CenterStageService.interpolated(path.keyframes, at: t),
                               crop.w > 0, crop.h > 0 {
                                let displayWidth = size.width / crop.w
                                let displayHeight = size.height / crop.h
                                InlinePlayerLayerView(player: player)
                                    .frame(width: displayWidth, height: displayHeight)
                                    .offset(x: -crop.x * displayWidth,
                                            y: -crop.y * displayHeight)
                            } else {
                                InlinePlayerLayerView(player: player)
                            }
                        }
                    } else if scene.wide, let crop = scene.cropXFrac,
                              let aspect = sourceAspect {
                        // Pan the full-height video so the visible window
                        // sits at the suggested crop position — the same
                        // (iw - cropW) * fraction offset the renderers use.
                        let displayWidth = size.height * aspect
                        InlinePlayerLayerView(player: player)
                            .frame(width: displayWidth, height: size.height)
                            .offset(x: -max(0, displayWidth - size.width) * crop)
                    } else {
                        InlinePlayerLayerView(player: player)
                    }
                }
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if player == nil { play() } else { stop() }
        }
        .onDisappear { stop() }
    }

    /// Source video aspect (width/height) for the crop pan.
    private var sourceAspect: Double? {
        guard let video = store.videos.first(where: { $0.id == scene.videoID }),
              video.width > 0, video.height > 0 else { return nil }
        return Double(video.width) / Double(video.height)
    }

    private func play() {
        let item = AVPlayerItem(url: scene.videoURL)
        item.forwardPlaybackEndTime = CMTime(seconds: scene.endTime, preferredTimescale: 600)
        let player = AVPlayer(playerItem: item)
        // Finishing the scene's range returns the card to its thumbnail.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main) { _ in
            stop()
        }
        // Seeking before the item is ready gets dropped and the file would
        // play from 0:00 — wait for readiness, land on the start, then roll.
        let target = CMTime(seconds: scene.startTime, preferredTimescale: 600)
        Task { [weak player, weak item] in
            for _ in 0..<100 where item?.status != .readyToPlay {
                if item?.status == .failed { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            await player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
        }
        self.player = player
    }

    private func stop() {
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player = nil
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

// MARK: - Model picker

/// The one provider/model picker used everywhere an AI action can be
/// steered: options read "Provider — Model" with ★ recommended (catalog's
/// top pick, flagged even when not installed), ★ best available (best of
/// what IS installed when the top pick is missing), and "(not installed)"
/// suffixes. Selection tags are "provider|model"; "" means automatic
/// dispatch when `includeAutomatic` is on.
struct ModelPicker: View {
    let title: String
    /// AICatalog task key ("analysis", "wizard", …) driving the ★ flags.
    let task: String
    @Binding var selection: String
    var includeAutomatic = false
    var imageCapableOnly = false
    var availableProviders: Set<String>

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Self.options(for: task, available: availableProviders,
                                 includeAutomatic: includeAutomatic,
                                 imageCapableOnly: imageCapableOnly,
                                 keeping: selection), id: \.tag) { option in
                Text(option.label).tag(option.tag)
            }
        }
    }

    static func tag(provider: String, model: String) -> String {
        "\(provider)|\(model)"
    }

    /// "provider|model" → parts; ("", nil-nil) for automatic/custom tags.
    static func parse(_ tag: String) -> (provider: String?, model: String?) {
        let parts = tag.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return (nil, nil) }
        return (String(parts[0]), String(parts[1]))
    }

    /// The catalog's true top pick for the task — flagged in the picker even
    /// when its provider isn't installed, so the ideal setup stays legible.
    static func topRecommendedTag(for task: String) -> String {
        if let entry = AICatalog.recommendedChains[task]?.first {
            return tag(provider: entry.provider, model: entry.model)
        }
        let key = AICatalog.taskDefaults[task] ?? "claude"
        return tag(provider: key, model: AICatalog.provider(key)?.defaultModel ?? "")
    }

    /// First recommended chain entry whose CLI is installed — what automatic
    /// dispatch actually runs.
    static func bestAvailableTag(for task: String, available: Set<String>) -> String {
        for entry in AICatalog.recommendedChains[task] ?? []
        where available.contains(entry.provider) {
            return tag(provider: entry.provider, model: entry.model)
        }
        let key = AICatalog.taskDefaults[task] ?? "claude"
        return tag(provider: key, model: AICatalog.provider(key)?.defaultModel ?? "")
    }

    static func options(for task: String, available: Set<String>,
                        includeAutomatic: Bool, imageCapableOnly: Bool,
                        keeping current: String? = nil) -> [(tag: String, label: String)] {
        let top = topRecommendedTag(for: task)
        let bestAvailable = bestAvailableTag(for: task, available: available)
        var result: [(tag: String, label: String)] = []
        if includeAutomatic {
            result.append(("", "Automatic (best available)"))
        }
        for provider in AICatalog.providers {
            if imageCapableOnly && !provider.supportsImages { continue }
            let installed = available.contains(provider.key)
            for model in provider.models {
                let optionTag = Self.tag(provider: provider.key, model: model)
                var label = "\(provider.label) — \(AICatalog.modelDisplayName(model))"
                if optionTag == top {
                    label += "  ★ recommended"
                } else if optionTag == bestAvailable, bestAvailable != top {
                    label += "  ★ best available"
                }
                if !installed { label += "  (not installed)" }
                result.append((optionTag, label))
            }
        }
        // Keep whatever is currently chosen selectable even if it's custom.
        if let current, !current.isEmpty, !result.contains(where: { $0.tag == current }) {
            let parsed = parse(current)
            result.append((current, [parsed.provider, parsed.model.map(AICatalog.modelDisplayName)]
                .compactMap(\.self).joined(separator: " — ")))
        }
        return result
    }

    /// Probe which provider CLIs are installed — seed pickers optimistically
    /// with every provider, then swap in the real set when this returns.
    static func probeAvailability(ai: AIService) async -> Set<String> {
        var available = Set<String>()
        for provider in AICatalog.providers {
            if await ai.isProviderAvailable(provider.key) {
                available.insert(provider.key)
            }
        }
        return available
    }
}

// MARK: - Shared badges

/// Entertainment-score chip — one color scale app-wide:
/// green ≥ 7.5, yellow ≥ 5, gray below.
struct ScoreBadge: View {
    let score: Double
    var compact = false

    static func color(for score: Double) -> Color {
        score >= 7.5 ? .green : score >= 5 ? .yellow : .gray
    }

    var body: some View {
        Text(String(format: "%.1f", score))
            .font(compact ? .system(size: 9, weight: .bold).monospacedDigit()
                          : .caption2.bold().monospacedDigit())
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, compact ? 1 : 2)
            .background(Self.color(for: score).opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(score >= 5 ? .black : .white)
    }
}

/// "WIDE" marker for 16:9 footage that will need cropping — one look
/// everywhere it appears (scene cards, browser cards, timeline blocks).
struct WideBadge: View {
    var compact = false

    var body: some View {
        Text("WIDE")
            .font(compact ? .system(size: 8, weight: .bold) : .caption2.bold())
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

/// Playback-speed marker ("0.5×") for slowed/sped clips — orange, matching
/// the ReviewSheet's slow-motion label.
struct SpeedBadge: View {
    let speed: Double
    var compact = false

    var body: some View {
        Text("\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
            .font(compact ? .system(size: 8, weight: .bold).monospacedDigit()
                          : .caption2.bold().monospacedDigit())
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

extension View {
    /// Horizontal-resize cursor while hovering — the affordance for
    /// draggable trim handles and scrubbing strips.
    func resizeCursorOnHover() -> some View {
        onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }
}

/// Fixed palette for person-marker boxes — one source of truth for every
/// view that draws them. Gray = ignored marker.
enum MarkerPalette {
    static let colors: [Color] = [.yellow, .green, .cyan, .orange,
                                  .pink, .purple, .red, .mint]

    static func color(at index: Int, ignored: Bool = false) -> Color {
        ignored ? .gray : colors[index % colors.count]
    }
}

/// Duration bubble overlaid on thumbnails — always bottom-trailing.
/// Sub-minute durations keep tenths ("3.4s"); longer ones read as m:ss.
struct DurationBadge: View {
    let seconds: Double

    var body: some View {
        Text(seconds < 60 ? String(format: "%.1fs", seconds) : seconds.timecode)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
            .padding(6)
    }
}
