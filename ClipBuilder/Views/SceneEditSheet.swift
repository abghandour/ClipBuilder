import SwiftUI
import AVKit

/// Edit Scene: framing, Center Stage, and trim in a single workbench.
struct SceneEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sceneID: Int64

    var body: some View {
        VStack(spacing: 0) {
            if let scene = store.scenes.first(where: { $0.id == sceneID }) {
                SceneEditor(scene: scene)
                HStack {
                    Toggle("Favorite", isOn: Binding(
                        get: { scene.favorite },
                        set: { store.favoriteScene(scene, favorite: $0) }
                    ))
                    .toggleStyle(.button)
                    .help("Keep this scene in Favorites; trims and framing are saved independently")
                    Spacer()
                    Button("Done") { dismiss() }
                    .help("Close the scene editor; trim and framing changes are saved as you edit")
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            } else {
                ContentUnavailableView("Scene not found", systemImage: "questionmark.square")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 660, height: 780)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
    }
}

/// One scene's workbench: play the effective range with the real framing,
/// trim/extend it on the source filmstrip, pin framing hints on the paused
/// frame, and (re)compute its Center Stage path.
struct SceneEditor: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var clock = PlaybackClock()
    @State private var rangeEndObserver: Any?
    @State private var isPlayingRange = false
    @State private var editStart = 0.0
    @State private var editEnd = 0.0
    @State private var cameraPreset = "balanced"
    private var cameraJob: AppJob? { store.jobs.latest(.cameraPath, subjectGroupID: String(scene.id)) }
    private var isComputingPath: Bool { cameraJob?.status == .running }
    @State private var hints: [CameraHint] = []
    @State private var suggestionCrop: CGRect?
    @State private var suggestionDraft: CGRect?
    @State private var focusPortraits: [Data] = []
    @State private var avoidPortraits: [Data] = []

    private var video: VideoRecord? {
        store.videos.first { $0.id == scene.videoID }
    }

    private var rangeEdited: Bool {
        abs(editStart - scene.startTime) > 0.05 || abs(editEnd - scene.endTime) > 0.05
    }

    private var hasOverride: Bool {
        scene.startTime != scene.originalStart || scene.endTime != scene.originalEnd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            playerArea
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))

            controlsRow

            if let video {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scene range — drag to trim or extend into the source footage")
                        .font(.caption.weight(.medium))
                    VideoTrimSlider(url: video.url, duration: video.duration,
                                    start: $editStart, end: $editEnd) { time in
                        scrub(to: time)
                    }
                    HStack {
                        Text("Analyzed: \(scene.originalStart.timecode)–\(scene.originalEnd.timecode)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if hasOverride || rangeEdited {
                            Button("Reset to Analyzed") {
                                editStart = scene.originalStart
                                editEnd = scene.originalEnd
                                store.setSceneEditRange(scene, start: scene.originalStart,
                                                        end: scene.originalEnd)
                            }
                            .controlSize(.small)
                        }
                        Button("Apply Range") {
                            store.setSceneEditRange(scene, start: editStart, end: editEnd)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(!rangeEdited)
                        .help("Save the new range — the scene plays, renders, and gets picked with these bounds; its camera path recomputes to match")
                    }
                }
            }

            if !scene.tags.isEmpty {
                SceneTagLine(tags: scene.tags)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .task(id: scene.id) {
            editStart = scene.startTime
            editEnd = scene.endTime
            cameraPreset = scene.centerStagePath?.camera ?? cameraPreset
            await setUpPlayer()
            hints = await store.centerStageHints(for: scene.videoID)
            await reloadPortraits()
        }
        // The applied range comes back through a scenes refresh — resync the
        // drafts so "Apply" correctly disables again.
        .onChange(of: scene.startTime) { editStart = scene.startTime }
        .onChange(of: scene.endTime) { editEnd = scene.endTime }
        // Keyed on the playback clock inside a leaf view, so the 10 Hz
        // ticks don't re-evaluate this whole editor.
        .background {
            ClockKeyedTask(clock: clock, extra: suggestionKey) { time in
                suggestionDraft = nil
                guard let video, video.wide, (player?.rate ?? 0) == 0 else {
                    suggestionCrop = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                suggestionCrop = await CenterStageService.stillFrameCrop(
                    source: video.url, at: time,
                    focusPortraits: focusPortraits,
                    avoidPortraits: avoidPortraits,
                    tuning: .named(cameraPreset))
            }
        }
        .onDisappear {
            tearDownPlayer()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(scene.videoFilename)
                        .font(.headline)
                        .lineLimit(1)
                    if let score = scene.score {
                        ScoreBadge(score: score)
                            .help("Entertainment score")
                    }
                    if (scene.excitement ?? 0) >= 0.35 {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("The crowd reacted during this scene")
                    }
                }
                Text("\(scene.startTime.timecode)–\(scene.endTime.timecode) · "
                     + String(format: "%.1fs", scene.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let narrative = scene.narrative {
                    // The story is exactly the context trimming needs —
                    // keep the payoff it describes inside the range.
                    Text(narrative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(narrative)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        PlayerView(player: player)
            .overlay {
                if let video {
                    GeometryReader { geo in
                        let videoRect = AVMakeRect(
                            aspectRatio: CGSize(width: max(1, video.width),
                                                height: max(1, video.height)),
                            insideRect: CGRect(origin: .zero, size: geo.size))
                        // Playing: the scene's real camera path rides along.
                        if isPlayingRange, video.wide,
                           let path = scene.centerStagePath, let player {
                            SwiftUI.TimelineView(.animation) { _ in
                                let t = player.currentTime().seconds - scene.startTime
                                if let crop = CenterStageService.interpolated(path.keyframes, at: t) {
                                    let rect = CGRect(
                                        x: videoRect.minX + crop.x * videoRect.width,
                                        y: videoRect.minY + crop.y * videoRect.height,
                                        width: crop.w * videoRect.width,
                                        height: crop.h * videoRect.height)
                                    ZStack(alignment: .topLeading) {
                                        Path { dim in
                                            dim.addRect(videoRect)
                                            dim.addRect(rect)
                                        }
                                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                                        Rectangle()
                                            .strokeBorder(.yellow, lineWidth: 3)
                                            .frame(width: rect.width, height: rect.height)
                                            .position(x: rect.midX, y: rect.midY)
                                    }
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        // Paused: the framing box — a nearby hint (editable)
                        // or the computed suggestion; drag either to pin.
                        if !isPlayingRange, video.wide, video.height > 0 {
                          ClockReader(clock: clock) { currentTime in
                            let widthPerHeight = (9.0 / 16.0)
                                * Double(video.height) / Double(max(1, video.width))
                            if let hint = hints.first(where: { abs($0.atTime - currentTime) < 0.5 }) {
                                CameraFrameBox(rect: CGRect(x: hint.x, y: hint.y,
                                                            width: hint.width, height: hint.height),
                                               color: .orange, label: "Camera hint",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    if let index = hints.firstIndex(where: { $0.id == hint.id }) {
                                        hints[index].x = updated.minX
                                        hints[index].y = updated.minY
                                        hints[index].width = updated.width
                                        hints[index].height = updated.height
                                    }
                                } onCommit: { updated in
                                    var changed = hint
                                    changed.x = updated.minX
                                    changed.y = updated.minY
                                    changed.width = updated.width
                                    changed.height = updated.height
                                    Task { hints = await store.updateCameraHint(changed) }
                                }
                            } else if let crop = suggestionDraft ?? suggestionCrop {
                                CameraFrameBox(rect: crop, color: .cyan,
                                               label: "Center Stage — drag to pin",
                                               videoRect: videoRect,
                                               widthPerHeight: widthPerHeight) { updated in
                                    suggestionDraft = updated
                                } onCommit: { updated in
                                    let time = currentTime
                                    suggestionDraft = nil
                                    Task {
                                        hints = await store.addCameraHint(videoID: scene.videoID,
                                                                          at: time, rect: updated)
                                    }
                                }
                            }
                          }
                        }
                    }
                }
            }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Button {
                if isPlayingRange { stopRangePlayback() } else { playRange() }
            } label: {
                Label(isPlayingRange ? "Stop" : "Play Scene",
                      systemImage: isPlayingRange ? "stop.fill" : "play.fill")
            }
            .help("Play the scene's current range — with a camera path, the real framing rides over the video")

            Spacer()

            if video?.wide == true {
                if isComputingPath {
                    ProgressView().controlSize(.small)
                    Text(cameraJob?.statusLine ?? "Tracking…").font(.caption).lineLimit(1)
                    if let cameraJob { Button("Stop") { store.jobs.cancel(cameraJob.id) } }
                } else if scene.centerStagePathJSON != nil {
                    Label("Center Stage ready", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Menu("Adjust Framing", systemImage: "slider.horizontal.3") {
                        Picker("Camera movement", selection: $cameraPreset) {
                            Text("Smooth").tag("smooth")
                            Text("Balanced").tag("balanced")
                            Text("Fast").tag("fast")
                        }
                        Divider()
                        Button("Recompute Center Stage") {
                            computeFraming()
                        }
                    }
                    .help("Change the camera movement or recompute Center Stage framing")
                } else {
                    Button("Create Center Stage Framing", systemImage: "viewfinder") {
                        computeFraming()
                    }
                    .controlSize(.small)
                    .help("Create the scene’s saved 9:16 Center Stage framing path")
                }
            }
        }
    }

    private func computeFraming() {
        store.startCameraPath(sceneID: scene.id, videoID: scene.videoID,
                              start: scene.startTime, end: scene.endTime, camera: cameraPreset)
    }

    // MARK: - Player

    private func setUpPlayer() async {
        tearDownPlayer()
        guard let video else { return }
        guard await DrivePlayback.prepare(video.url) else { return }
        guard let asset = try? await DriveLocalAsset.make(video.url) else { return }
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        await newPlayer.seek(to: CMTime(seconds: scene.startTime, preferredTimescale: 600))
        player = newPlayer
        clock.time = scene.startTime
        let clock = clock
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main) { time in
            Task { @MainActor in clock.update(time.seconds) }
        }
    }

    private func tearDownPlayer() {
        stopRangePlayback()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func scrub(to time: Double) {
        guard let player else { return }
        stopRangePlayback()
        player.pause()
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func playRange() {
        guard let player, scene.endTime > scene.startTime else { return }
        stopRangePlayback()
        rangeEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: scene.endTime, preferredTimescale: 600))],
            queue: .main) {
            Task { @MainActor in stopRangePlayback() }
        }
        player.seek(to: CMTime(seconds: scene.startTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
        isPlayingRange = true
    }

    private func stopRangePlayback() {
        if let rangeEndObserver, let player {
            player.removeTimeObserver(rangeEndObserver)
        }
        rangeEndObserver = nil
        if isPlayingRange {
            player?.pause()
            isPlayingRange = false
        }
    }

    // MARK: - Framing references

    /// Suggestion recompute key minus the clock, which `ClockKeyedTask` adds.
    private var suggestionKey: String {
        let hintShape = hints.map { "\($0.atTime)@\($0.x),\($0.y),\($0.width),\($0.height)" }.joined(separator: ";")
        return "\(scene.id)|\(hintShape)|\(cameraPreset)|\(isPlayingRange)|\(focusPortraits.count)|\(avoidPortraits.count)"
    }

    private func reloadPortraits() async {
        guard let video else { return }
        let markers = await store.personMarkers(for: scene.videoID)
        let named = markers.filter { $0.personID != nil && !$0.ignored }
        let ignored = markers.filter(\.ignored)
        focusPortraits = named.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: named,
                                             duration: video.duration)
        avoidPortraits = ignored.isEmpty ? []
            : await Analyzer.markerPortraits(url: video.url, markers: ignored,
                                             duration: video.duration)
    }
}
