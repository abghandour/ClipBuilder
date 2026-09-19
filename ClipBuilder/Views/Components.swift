import SwiftUI
import AVKit
import Vision

/// Copy and clear the messages shown by App Log.
struct LogActions: View {
    let lines: [String]
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Copy Log", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            .help("Copy the whole log to the clipboard")
            Button("Clear Log", systemImage: "trash", role: .destructive) {
                clear()
            }
            .help("Clear the log")
        }
        .labelStyle(.iconOnly)
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
    var contentMode: ContentMode = .fill
    /// Only this part of the frame (fractions, top-left origin), scaled to
    /// fill the view: a speaker's cell of a call, a tracked crop.
    var window: FreeCropRect? = nil

    @State private var image: NSImage?
    @State private var loadedKey: String?
    @State private var requestedKey: String?

    private var key: String { Self.cacheKey(url: url, time: time) }

    nonisolated static func cacheKey(url: URL, time: Double) -> String { "\(url.path)|\(time)|frame" }

    /// The frame this thumbnail would paint, if it is already in memory —
    /// drag previews are snapshotted at once and cannot wait for a load.
    nonisolated static func cachedFrame(url: URL, time: Double) -> NSImage? {
        ImageCache.cached(key: cacheKey(url: url, time: time))
    }

    var body: some View {
        ZStack {
            // A memory-cache hit paints immediately — a card scrolled back
            // into view doesn't flash its placeholder or re-read the JPEG.
            if let image = image ?? ImageCache.cached(key: key) {
                // Color.clear adopts exactly the proposed size; the overlay
                // draws the aspect-fill image within it without inflating the
                // view's own layout size the way a bare .fill image does.
                Color.clear
                    .overlay {
                        if let window {
                            GeometryReader { geo in
                                let fullWidth = geo.size.width / max(0.01, window.wFrac)
                                let fullHeight = geo.size.height / max(0.01, window.hFrac)
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: fullWidth, height: fullHeight)
                                    .offset(x: -window.xFrac * fullWidth, y: -window.yFrac * fullHeight)
                            }
                        } else {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: contentMode)
                        }
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // Fill scaling overflows the frame; keep hit testing inside it too.
        .contentShape(Rectangle())
        .task(id: key) {
            // Track which key is loaded rather than guarding on image ==
            // nil, which froze the thumbnail on its first frame when the
            // same view was later given a different time (preview scrub).
            let key = key
            guard !Task.isCancelled else { return }
            requestedKey = key
            guard loadedKey != key else { return }
            if let hit = ImageCache.cached(key: key) {
                image = hit
                loadedKey = key
                return
            }
            if let data = await store.thumbnails.thumbnail(for: url, at: time),
               let loaded = await ImageCache.image(data: data, key: key, maxPixel: 480) {
                guard !Task.isCancelled, key == requestedKey else { return }
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
    /// different person (e.g. the People detail header on selection change),
    /// and the same person can get a new hand-picked avatar.
    @State private var loadedKey: String?

    private var initials: String {
        person.name.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined()
    }

    /// Reload key: person plus their avatar override, so a fresh pick
    /// re-renders in place.
    private var avatarKey: String {
        "\(person.id)|\(person.avatarVideoID ?? -1)|\(person.avatarTime ?? -1)"
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
        .task(id: avatarKey) {
            guard loadedKey != avatarKey else { return }
            image = nil
            loadedKey = avatarKey
            // The user's hand-picked avatar frame wins over everything.
            if let videoID = person.avatarVideoID, let time = person.avatarTime,
               let video = store.videos.first(where: { $0.id == videoID }),
               let frame = await ThumbnailService.jpegFrame(url: video.url, at: time,
                                                            maxDimension: 720) {
                // Stored top-left normalized box → Vision's bottom-left.
                var faceBox = person.avatarBox.map { box in
                    CGRect(x: box.x, y: 1 - box.y - box.h, width: box.w, height: box.h)
                }
                if faceBox == nil { faceBox = await Self.detectFace(in: frame) }
                image = Self.avatarImage(from: frame, faceBox: faceBox)
                if image != nil { return }
            }
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
            // The people pass already cropped this person out of a frame:
            // that box is the right face even when a scene shows several
            // people (a podcast grid), where the largest face is anyone's.
            if let portrait = await store.personRosterPortrait(for: person.id),
               let frame = await ThumbnailService.jpegFrame(url: portrait.url, at: portrait.marker.atTime,
                                                            maxDimension: 720),
               let cropped = Analyzer.markerPortrait(from: frame, marker: portrait.marker) {
                image = Self.avatarImage(from: cropped, faceBox: await Self.detectFace(in: cropped))
                if image != nil { return }
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
    nonisolated static func detectFace(in data: Data) async -> CGRect? {
        await detectFaces(in: data).first
    }

    /// Every detected face, largest first, as normalized bounding boxes
    /// (bottom-left origin, Vision convention). The avatar picker offers
    /// each one as a candidate crop.
    ///
    /// Uses Vision's async request API: the legacy `VNImageRequestHandler`
    /// call blocks its thread while waiting on Vision's own queue, and when a
    /// roster of avatars loads at once that parks every cooperative-pool
    /// thread, so no other async work in the app (video previews included)
    /// can run until Vision returns.
    nonisolated static func detectFaces(in data: Data) async -> [CGRect] {
        let request = DetectFaceRectanglesRequest()
        guard let observations = try? await request.perform(on: data) else { return [] }
        return observations
            .map { CGRect(x: $0.boundingBox.origin.x, y: $0.boundingBox.origin.y,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.width > $1.width }
    }

    /// Square crop centered on the face (with generous headroom), falling
    /// back to a centered square when no face was detected.
    static func avatarImage(from data: Data, faceBox: CGRect?) -> NSImage? {
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

/// One color per speaker name, stable across launches, so the outline on
/// the picture and the name in the transcript column read as the same
/// person. "Unknown" stays grey.
enum SpeakerColors {
    static let palette: [Color] = [.orange, .green, .pink, .cyan, .yellow, .purple, .mint, .indigo]

    static func color(for label: String) -> Color {
        if label == TranscriptSpeakers.unknownLabel { return .gray }
        return palette[Int(SpeakerColors.index(for: label))]
    }

    /// FNV-1a over the label, folded into the palette — `hashValue` is
    /// seeded per process and would shuffle the colors on every launch.
    static func index(for label: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash % UInt64(palette.count)
    }
}

/// Modal player used by both the Library and the scene browser. With a
/// `transcriptVideoID` the transcript of the played range sits beside the
/// picture, follows playback, and seeks on click.
struct PlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let url: URL
    var transcriptVideoID: Int64? = nil
    let title: String
    var startTime: Double = 0
    /// Stop playback here (e.g. a scene's end) instead of running on to the
    /// end of the source file. Playing again restarts at `startTime`.
    var endTime: Double?
    /// When set, I and O mark in and out while watching and B adds that
    /// source range as B-roll — no sheet, no trimming detour. Returns a
    /// message when the range could not be added as asked.
    var onMarkAsBRoll: ((_ start: Double, _ end: Double) -> String?)?

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?
    @State private var playbackTime: Double?
    @State private var transcript: [TranscriptRow] = []
    @State private var transcriptLoaded = false
    @State private var speakerLabels: [Int64: String] = [:]
    @State private var speakerTurns: [SpeakerTurn] = []
    @State private var speakerRoster: [VideoPersonRecord] = []
    @State private var markIn: Double?
    @State private var markOut: Double?
    @State private var markProblem: String?

    private var currentTime: Double { player?.currentTime().seconds ?? startTime }

    /// The rows the played range touches, in order, original language only.
    private var sceneTranscript: [TranscriptRow] {
        transcript.filter { !$0.isTranslation && $0.endTime > startTime && $0.startTime < (endTime ?? .infinity) }
            .sorted { $0.startTime < $1.startTime }
    }

    private var currentRow: TranscriptRow? {
        let time = playbackTime ?? startTime
        return sceneTranscript.last { $0.startTime <= time + 0.05 }
    }

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

            HStack(spacing: 0) {
                PlayerView(player: player)
                    .frame(minWidth: 420, minHeight: 560)
                    .overlay { speakerOutline }
                if transcriptVideoID != nil {
                    Divider()
                    transcriptPanel
                }
            }

            if onMarkAsBRoll != nil {
                HStack(spacing: Theme.spaceM) {
                    Text(markProblem ?? "I marks in · O marks out · B adds it as B-roll at the playhead")
                        .font(.caption)
                        .foregroundStyle(markProblem == nil ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                    Spacer()
                    if let markIn {
                        Text("In \(markIn.timecode)")
                            .font(.caption.monospacedDigit())
                    }
                    if let markOut {
                        Text("Out \(markOut.timecode)")
                            .font(.caption.monospacedDigit())
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Theme.spaceS)
            }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoObB"), phases: .down) { press in
            guard let onMarkAsBRoll else { return .ignored }
            switch press.characters.lowercased() {
            case "i":
                markIn = currentTime
            case "o":
                markOut = currentTime
            default:
                let start = markIn ?? startTime
                let end = markOut ?? max(start + 1, currentTime)
                guard end > start + 0.1 else { return .handled }
                if let problem = onMarkAsBRoll(start, end) {
                    markProblem = problem
                } else {
                    dismiss()
                }
            }
            return .handled
        }
        .modalCloseButton { dismiss() }
        .task(id: transcriptVideoID) {
            guard let transcriptVideoID else { return }
            transcript = await store.transcriptRows(videoID: transcriptVideoID)
            transcriptLoaded = true
            let speakers = await store.speakerTurns(videoID: transcriptVideoID)
            speakerTurns = speakers.turns
            speakerRoster = speakers.roster
            speakerLabels = TranscriptSpeakers.labels(for: sceneTranscript, turns: speakers.turns,
                                                      roster: speakers.roster, people: store.people)
        }
        .task(id: url) {
            guard await DrivePlayback.prepare(url) else { return }
            guard let asset = try? await DriveLocalAsset.make(url) else { return }
            let item = AVPlayerItem(asset: asset)
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
            if transcriptVideoID != nil {
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                    Task { @MainActor in playbackTime = time.seconds }
                }
            }
            player.play()
            self.player = player
        }
        .onDisappear {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
            player = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }

    /// The video the transcript belongs to, for its layout and tiles.
    private var transcriptVideo: VideoRecord? {
        guard let transcriptVideoID else { return nil }
        return store.videos.first { $0.id == transcriptVideoID }
    }

    /// Who the speaker map says is talking right now, as an outline around
    /// their cell (or side) of the picture with their name in the corner,
    /// in the same color as their name in the transcript column. Draws the
    /// stored map, so a wrong outline shows where the map is wrong.
    @ViewBuilder
    private var speakerOutline: some View {
        if let video = transcriptVideo, !speakerTurns.isEmpty {
            GeometryReader { geo in
                let videoRect = AVMakeRect(
                    aspectRatio: CGSize(width: max(1, video.width), height: max(1, video.height)),
                    insideRect: CGRect(origin: .zero, size: geo.size))
                let time = playbackTime ?? startTime
                if let spot = SpeakerSpotlight.at(time, tiles: video.podcastTiles,
                                                  layout: video.podcastLayout.flatMap(PodcastLayout.init(rawValue:)),
                                                  seamX: video.podcastSeamX,
                                                  turns: speakerTurns, roster: speakerRoster,
                                                  people: store.people, row: currentRow) {
                    let rect = CGRect(x: videoRect.minX + spot.x * videoRect.width,
                                      y: videoRect.minY + spot.y * videoRect.height,
                                      width: spot.w * videoRect.width,
                                      height: spot.h * videoRect.height).insetBy(dx: 1.5, dy: 1.5)
                    let color = SpeakerColors.color(for: spot.label)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color, lineWidth: 3)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        Text(spot.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: rect.minX + 6, y: rect.minY + 6)
                    }
                    .animation(.easeInOut(duration: 0.15), value: spot)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The whole transcript of the played range; the line being spoken is
    /// highlighted and kept in view, and a click seeks to a line.
    private var transcriptPanel: some View {
        let rows = sceneTranscript
        let current = currentRow?.id
        return VStack(alignment: .leading, spacing: 0) {
            Text("Transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.spaceM)
                .padding(.vertical, Theme.spaceS)
            Divider()
            if rows.isEmpty {
                Text(transcriptLoaded ? "No transcript for this part. Transcribe the file from the Sources screen." : "Loading the transcript…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(Theme.spaceM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                Button {
                                    player?.seek(to: CMTime(seconds: row.startTime, preferredTimescale: 600),
                                                 toleranceBefore: .zero, toleranceAfter: .zero)
                                    playbackTime = row.startTime
                                } label: {
                                    HStack(alignment: .top, spacing: Theme.spaceS) {
                                        Text(row.startTime.timecode)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 40, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            if let speaker = speakerLabels[row.id] {
                                                Text(speaker)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(SpeakerColors.color(for: speaker))
                                            }
                                            Text(row.text)
                                                .font(.callout)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, Theme.spaceS)
                                    .padding(.vertical, 4)
                                    .background(row.id == current ? Color.accentColor.opacity(0.18) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(row.id)
                                .help("Play from \(row.startTime.timecode)")
                            }
                        }
                        .padding(Theme.spaceS)
                    }
                    .onChange(of: current) { _, id in
                        if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .frame(width: 320)
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

    @State private var playbackFetchTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            // Stays underneath as the poster while the player gets ready;
            // talk footage opens on whoever is speaking at the scene's start.
            let poster = scene.posterFrame(videoType: store.videos.first { $0.id == scene.videoID }?.type)
            VideoThumbnail(url: scene.videoURL, time: poster.time, window: poster.window)
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
        // The tap gesture is invisible to assistive tech — expose the same
        // toggle as a named, activatable element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player == nil ? "Play scene preview" : "Stop scene preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
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
        playbackFetchTask = Task {
            guard await DrivePlayback.prepare(scene.videoURL) else { return }
            guard let asset = try? await DriveLocalAsset.make(scene.videoURL) else { return }
            let item = AVPlayerItem(asset: asset)
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
    }

    private func stop() {
        playbackFetchTask?.cancel()
        playbackFetchTask = nil
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

    /// Friendly labels for the tags the podcast pass writes.
    static let labels: [String: String] = ["reel-highlight": "Reel", "q&a": "Q&A", "chapter": "Chapter"]

    var body: some View {
        Text(Self.labels[tag] ?? tag)
            .font(.caption2)
            .fontWeight(tag == "reel-highlight" ? .semibold : .regular)
            .foregroundStyle(tag == "reel-highlight" ? Color.white : .primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tag == "reel-highlight" ? Color.accentColor : Color.secondary.opacity(0.14),
                        in: Capsule())
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
        tags.filter { !$0.hasPrefix("person:") && $0 != "podcast-exchange" && $0 != "podcast:split" }
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
            for model in AICatalog.models(for: provider.key) {
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
            .font(compact ? .badgeCompact : .badge)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, compact ? 1 : 2)
            .background(Self.color(for: score).opacity(0.85),
                        in: RoundedRectangle(cornerRadius: Theme.chipRadius))
            .foregroundStyle(score >= 5 ? .black : .white)
    }
}

/// "WIDE" marker for 16:9 footage that will need cropping — one look
/// everywhere it appears (scene cards, browser cards, timeline blocks).
struct WideBadge: View {
    var compact = false

    var body: some View {
        Text("WIDE")
            .font(compact ? .badgeCompact : .badge)
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
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
            .font(compact ? .badgeCompact : .badge)
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
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
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
            .foregroundStyle(.white)
            .padding(6)
    }
}

/// A text field for a comma-separated list. Edits a local draft so the
/// separator the user just typed survives; the parsed list is written to
/// `items` as it changes. (Binding the list's joined form directly to a
/// TextField snapped "en," back to "en" on every keystroke.)
struct CommaListField: View {
    let title: String
    @Binding var items: [String]
    var lowercased = false
    var prompt: Text? = nil

    @State private var draft = ""

    init(_ title: String, items: Binding<[String]>, lowercased: Bool = false, prompt: Text? = nil) {
        self.title = title
        self._items = items
        self.lowercased = lowercased
        self.prompt = prompt
    }

    private func parse(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { lowercased ? $0.lowercased() : $0 }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        TextField(title, text: $draft, prompt: prompt)
            .onAppear { draft = items.joined(separator: ", ") }
            .onChange(of: draft) { _, value in
                let parsed = parse(value)
                if parsed != items { items = parsed }
            }
            .onChange(of: items) { _, value in
                // External change (profile switch, reset): resync the draft
                // unless it already parses to the same list.
                if parse(draft) != value { draft = value.joined(separator: ", ") }
            }
    }
}
