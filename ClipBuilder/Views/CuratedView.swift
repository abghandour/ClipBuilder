import AVKit
import SwiftUI

/// Curated Scenes: the staging area between raw analysis and generation.
/// Scenes promoted here are the keepers — each can be trimmed/extended and
/// framed (Center Stage) until it's good to go, and the AI Wizard can be
/// told to draw from only these.
struct CuratedView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedSceneID: Int64?

    private var curatedScenes: [SceneRecord] {
        store.scenes.filter { $0.curated && !$0.ignored }
    }

    var body: some View {
        Group {
            if curatedScenes.isEmpty {
                ContentUnavailableView(
                    "No curated scenes yet",
                    systemImage: "checkmark.seal",
                    description: Text("Promote keepers from Raw Scenes — the seal button on a scene card, or right-click → Add to Curated. Here they can be trimmed, extended, and framed; the AI Wizard can then be told to use curated scenes only."))
            } else {
                HSplitView {
                    sceneList
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 420, maxHeight: .infinity)
                    if let scene = curatedScenes.first(where: { $0.id == selectedSceneID }) {
                        CuratedSceneEditor(scene: scene)
                            .id(scene.id)
                            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a scene", systemImage: "checkmark.seal")
                            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Curated Scenes")
        .navigationSubtitle("\(curatedScenes.count) scenes")
    }

    private var sceneList: some View {
        List(selection: $selectedSceneID) {
            ForEach(curatedScenes) { scene in
                HStack(spacing: 8) {
                    VideoThumbnail(url: scene.videoURL,
                                   time: (scene.startTime + scene.endTime) / 2)
                        .frame(width: 34, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.videoFilename)
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(scene.startTime.timecode)–\(scene.endTime.timecode) · "
                             + String(format: "%.1fs", scene.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if scene.centerStagePathJSON != nil {
                        Image(systemName: "camera.metering.center.weighted")
                            .foregroundStyle(.secondary)
                            .help("Has a Center Stage camera path")
                    }
                    if scene.startTime != scene.originalStart || scene.endTime != scene.originalEnd {
                        Image(systemName: "timeline.selection")
                            .foregroundStyle(.orange)
                            .help("Range edited from the analyzed original")
                    }
                }
                .tag(scene.id)
                .contextMenu {
                    Button("Remove from Curated") {
                        if selectedSceneID == scene.id { selectedSceneID = nil }
                        store.curateScene(scene, curated: false)
                    }
                    Button("Add to Builder") {
                        store.builder.addScene(scene)
                        store.requestedSection = .builder
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Raw Scenes → "Curate": the full workbench in a sheet — analyze the
/// scene's framing, apply Center Stage, trim — then save it as curated.
struct CurateSceneSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sceneID: Int64

    var body: some View {
        VStack(spacing: 0) {
            if let scene = store.scenes.first(where: { $0.id == sceneID }) {
                CuratedSceneEditor(scene: scene, promoteMode: !scene.curated)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button(scene.curated ? "Done" : "Save as Curated") {
                        if !scene.curated {
                            store.curateScene(scene, curated: true)
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            } else {
                ContentUnavailableView("Scene not found", systemImage: "questionmark.square")
                    .frame(maxHeight: .infinity)
                Button("Close") { dismiss() }
                    .padding()
            }
        }
        .frame(width: 660, height: 780)
    }
}

/// One scene's workbench: play the effective range with the real framing,
/// trim/extend it on the source filmstrip, pin framing hints on the paused
/// frame, and (re)compute its Center Stage path. Used inside the Curated
/// section and (in promote mode) as the Raw Scenes "Curate" modal.
struct CuratedSceneEditor: View {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    /// Promote mode: shown from Raw Scenes before the scene is curated —
    /// the header's Remove button is hidden (the sheet has Save/Cancel).
    var promoteMode = false

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var currentTime = 0.0
    @State private var rangeEndObserver: Any?
    @State private var isPlayingRange = false
    @State private var editStart = 0.0
    @State private var editEnd = 0.0
    @State private var cameraPreset = "balanced"
    @State private var isComputingPath = false
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
            setUpPlayer()
            hints = await store.centerStageHints(for: scene.videoID)
            await reloadPortraits()
        }
        // The applied range comes back through a scenes refresh — resync the
        // drafts so "Apply" correctly disables again.
        .onChange(of: scene.startTime) { editStart = scene.startTime }
        .onChange(of: scene.endTime) { editEnd = scene.endTime }
        .task(id: suggestionKey) {
            suggestionDraft = nil
            guard let video, video.wide, (player?.rate ?? 0) == 0 else {
                suggestionCrop = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestionCrop = await CenterStageService.stillFrameCrop(
                source: video.url, at: currentTime,
                focusPortraits: focusPortraits,
                avoidPortraits: avoidPortraits,
                tuning: .named(cameraPreset))
        }
        .onDisappear {
            tearDownPlayer()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.videoFilename)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(scene.startTime.timecode)–\(scene.endTime.timecode) · "
                     + String(format: "%.1fs", scene.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !promoteMode {
                Button("Remove from Curated", systemImage: "seal") {
                    store.curateScene(scene, curated: false)
                }
                .controlSize(.small)
            }
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
                Picker("Camera", selection: $cameraPreset) {
                    Text("Smooth").tag("smooth")
                    Text("Balanced").tag("balanced")
                    Text("Fast").tag("fast")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                if isComputingPath {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(scene.centerStagePathJSON == nil
                       ? "Compute Framing Path" : "Recompute Framing Path") {
                    let sceneID = scene.id
                    let videoID = scene.videoID
                    let start = scene.startTime
                    let end = scene.endTime
                    let camera = cameraPreset
                    isComputingPath = true
                    Task {
                        await store.computeCameraPath(sceneID: sceneID, videoID: videoID,
                                                      start: start, end: end, camera: camera)
                        isComputingPath = false
                    }
                }
                .controlSize(.small)
                .disabled(isComputingPath)
                .help("Track the people across this scene's range and store the camera's pan/zoom path — honoring markers, ignored people, and your pinned hints")
            }
        }
    }

    // MARK: - Player

    private func setUpPlayer() {
        tearDownPlayer()
        guard let video else { return }
        let newPlayer = AVPlayer(url: video.url)
        newPlayer.seek(to: CMTime(seconds: scene.startTime, preferredTimescale: 600))
        player = newPlayer
        currentTime = scene.startTime
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main) { time in
            Task { @MainActor in currentTime = time.seconds }
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

    private var suggestionKey: String {
        "\(scene.id)|\((currentTime * 2).rounded())|\(hints.count)|\(cameraPreset)|\(isPlayingRange)"
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
