import SwiftUI

/// The multi-track timeline: time ruler, the cropping row, one video lane
/// per crop area, a sound lane, and an overlay lane, all inside one
/// horizontal scroller with pinned track headers on the left. Clips are absolutely positioned views
/// (startTime × points-per-second) with drag-to-move, drag-between-tracks,
/// and a trailing trim handle — the SwiftUI port of the web builder timeline.
struct TimelineView: View {
    @Environment(AppStore.self) private var store
    let onPlayClip: (TimelineClip) -> Void
    @State private var verticalScrollPosition = ScrollPosition()
    @State private var horizontalScrollPosition = ScrollPosition()

    private static let rulerHeight: CGFloat = 26
    static let cropLaneHeight: CGFloat = 52
    private static let soundLaneHeight: CGFloat = 40
    private static let textLaneHeight: CGFloat = 40
    private static let headerWidth: CGFloat = 148

    var body: some View {
        let model = store.builder
        let contentWidth = max(800, CGFloat(model.totalDuration + 15) * model.pointsPerSecond)
        let layout = model.timelineLayout()

        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                headerColumn(model: model, layout: layout)
                    .frame(width: Self.headerWidth)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
                        TimeRuler(contentWidth: contentWidth)
                            .frame(width: contentWidth, height: Self.rulerHeight)
                        CropLane(contentWidth: contentWidth, height: Self.cropLaneHeight)
                        ForEach(0..<model.document.trackCount, id: \.self) { track in
                            VideoTrackLane(track: track, layout: layout.videoTracks[track],
                                           contentWidth: contentWidth,
                                           onPlayClip: onPlayClip)
                        }
                        SoundLane(contentWidth: contentWidth, height: Self.soundLaneHeight)
                        OverlayLane(layout: layout, contentWidth: contentWidth)
                    }
                    .overlay(alignment: .topLeading) {
                        PlayheadLine()
                    }
                    .padding(.bottom, 8)
                }
                .scrollPosition($horizontalScrollPosition)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    Double(geometry.contentOffset.x)
                } action: { _, offset in
                    store.timelineScrollX = max(0, offset)
                }
            }
        }
        .scrollPosition($verticalScrollPosition)
        .onScrollGeometryChange(for: Double.self) { geometry in
            Double(geometry.contentOffset.y)
        } action: { _, offset in
            store.timelineScrollY = max(0, offset)
        }
        .onAppear(perform: restoreScrollPosition)
        .onChange(of: store.openTimelineID) { restoreScrollPosition() }
        .onChange(of: store.activeProjectID) { restoreScrollPosition() }
        .background(.background)
    }

    private func restoreScrollPosition() {
        horizontalScrollPosition.scrollTo(x: store.timelineScrollX)
        verticalScrollPosition.scrollTo(y: store.timelineScrollY)
    }

    @ViewBuilder
    private func headerColumn(model: BuilderTimelineModel, layout: TimelineLayoutSnapshot) -> some View {
        VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
            PlayheadTimecode()
                .frame(height: Self.rulerHeight)
                .padding(.leading, 8)
            CropLaneHeader()
                .frame(height: Self.cropLaneHeight)
            ForEach(0..<model.document.trackCount, id: \.self) { track in
                TrackHeader(track: track)
                    .frame(height: CGFloat(layout.videoTracks[track].rowCount)
                           * BuilderTimelineModel.rowHeight)
            }
            laneHeader(title: "Sound", systemImage: "music.note")
                .frame(height: Self.soundLaneHeight)
            laneHeader(title: "Overlays", systemImage: "square.2.layers.3d")
                .frame(height: CGFloat(layout.overlayRowCount)
                       * BuilderTimelineModel.overlayRowHeight)
        }
    }

    private func laneHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Track header

/// Left-pinned header for one video track: mute, sequential/free toggle, and
/// the layer settings popover. Clicking it focuses the track, which paints
/// the track's crop area green on the cropping row.
struct TrackHeader: View {
    @Environment(AppStore.self) private var store
    let track: Int

    @State private var showSettings = false

    private static let numerals = ["I", "II", "III", "IV", "V", "VI"]

    var body: some View {
        let model = store.builder
        let settings = model.document.trackSettings[safe: track] ?? TrackSettings()
        let sequential = model.document.trackSequential[safe: track] ?? true
        let highlighted = model.highlightedTrack == track
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Track \(Self.numerals[safe: track] ?? "\(track + 1)")")
                    .font(.caption.bold())
                    .help("Click the header to highlight this track's crop area")
                TrackAreaLabel(track: track, highlighted: highlighted)
                Spacer()
                Button("Track Settings", systemImage: "gearshape") {
                    showSettings = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Volume, sequential playback, and other track settings")
                .popover(isPresented: $showSettings) {
                    TrackSettingsPopover(track: track)
                }
            }
            HStack(spacing: 6) {
                Button(settings.muted ? "Unmute Track" : "Mute Track",
                       systemImage: settings.muted ? "speaker.slash.fill" : "speaker.wave.2") {
                    model.updateTrackSettings(track) { $0.muted.toggle() }
                }
                .foregroundStyle(settings.muted ? .red : .secondary)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(settings.muted ? "Unmute layer" : "Mute layer")

                Button(sequential ? "Sequential" : "Free placement") {
                    model.setTrackSequential(!sequential, track: track)
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(sequential ? "Sequential: clips snap end-to-end automatically"
                                 : "Free placement: clips stay where you drop them")
                Spacer()
            }
        }
        .padding(6)
        .background(highlighted ? Color.green.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(highlighted ? Color.green.opacity(0.7) : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusTrack(track) }
    }
}

/// The area name a track shows at the playhead. A leaf view, like
/// PlayheadTimecode, so scrubbing re-evaluates only this label and not the
/// header column and every lane with it.
private struct TrackAreaLabel: View {
    @Environment(AppStore.self) private var store
    let track: Int
    let highlighted: Bool

    var body: some View {
        let model = store.builder
        if let areaName = model.area(forTrack: track, at: model.playhead)?.name {
            Text(areaName)
                .font(.caption2)
                .foregroundStyle(highlighted ? Color.green : .secondary)
                .lineLimit(1)
                .help("This track shows the \"\(areaName)\" area at the playhead")
        }
    }
}

/// Per-layer settings: mute, default wide position, layer captions, default crop.
struct TrackSettingsPopover: View {
    @Environment(AppStore.self) private var store
    let track: Int

    var body: some View {
        let model = store.builder
        let settings = model.document.trackSettings[safe: track] ?? TrackSettings()
        // Wide-clip defaults (slot band, 9:16 crop) only matter under a
        // Full Screen block; areas frame clips with their own camera.
        let hasFullScreen = model.document.cropBlocks.contains { $0.layout.isFullScreen }
        Form {
            Toggle("Muted", isOn: Binding(
                get: { settings.muted },
                set: { value in model.updateTrackSettings(track) { $0.muted = value } }))
            if hasFullScreen {
                Picker("Wide position", selection: Binding(
                    get: { settings.defaultPosition },
                    set: { value in model.updateTrackSettings(track) { $0.defaultPosition = value } })) {
                    Text("Top").tag("top")
                    Text("Center").tag("center")
                    Text("Bottom").tag("bottom")
                }
            }
            Picker("Captions", selection: Binding(
                get: { settings.captions },
                set: { value in model.updateTrackSettings(track) { $0.captions = value } })) {
                Text("None").tag("none")
                Text("Top").tag("top")
                Text("Middle").tag("middle")
                Text("Bottom").tag("bottom")
            }
            if hasFullScreen {
                HStack {
                    Toggle("Default crop", isOn: Binding(
                        get: { settings.defaultCropXFrac != nil },
                        set: { value in
                            model.updateTrackSettings(track) { $0.defaultCropXFrac = value ? 0.5 : nil }
                        }))
                    if let crop = settings.defaultCropXFrac {
                        Slider(value: Binding(
                            get: { crop },
                            set: { value in model.updateTrackSettings(track) { $0.defaultCropXFrac = value } }),
                            in: 0...1)
                            .frame(width: 120)
                    }
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - Time ruler

/// Second ticks (major every 5s with labels); click/drag scrubs the playhead.
struct TimeRuler: View {
    @Environment(AppStore.self) private var store
    let contentWidth: CGFloat

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        Canvas { context, size in
            let seconds = Int(size.width / pps) + 1
            for second in 0...seconds {
                let x = CGFloat(second) * pps
                let isMajor = second % 5 == 0
                let tickHeight: CGFloat = isMajor ? 10 : 5
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                context.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.8 : 0.4)), lineWidth: 1)
                if isMajor {
                    context.draw(Text(Double(second).timecode)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary),
                                 at: CGPoint(x: x + 2, y: 6), anchor: .leading)
                }
            }
            for marker in model.document.pacing.markers(until: model.totalDuration) {
                let x = CGFloat(marker) * pps
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: 0))
                context.stroke(path, with: .color(.orange.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .contentShape(Rectangle())
        .resizeCursorOnHover()
        .help("Click or drag to move the playhead")
        .accessibilityLabel("Timeline playhead")
        .accessibilityValue(model.playhead.timecode)
        .accessibilityHint("Adjust to move the playhead by half a second")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                model.playhead = BuilderTimelineModel.snap(model.playhead + 0.5)
            case .decrement:
                model.playhead = BuilderTimelineModel.snap(model.playhead - 0.5)
            @unknown default:
                break
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Snap before writing and skip no-op writes: @Observable
                // fires on every set, and an unsnapped value invalidates
                // the playhead observers once per pixel of mouse travel.
                let time = BuilderTimelineModel.snap(Double(value.location.x / pps))
                if model.playhead != time { model.playhead = time }
            })
    }
}

/// Vertical playhead line across all lanes.
struct PlayheadLine: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        Rectangle()
            .fill(.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(model.playhead) * model.pointsPerSecond)
            .allowsHitTesting(false)
    }
}

/// Playhead readout isolated in its own view so the timeline's header (and
/// with it every lane) doesn't re-evaluate on each playhead change.
struct PlayheadTimecode: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Text(store.builder.playhead.timecode)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Video lane

/// One video track: a lane of absolutely positioned clip blocks that accepts
/// scene drops from the clip browser.
struct VideoTrackLane: View {
    @Environment(AppStore.self) private var store
    let track: Int
    let layout: TimelineLayoutSnapshot.VideoTrack
    let contentWidth: CGFloat
    let onPlayClip: (TimelineClip) -> Void

    @State private var isDropTarget = false

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(isDropTarget ? 0.55 : 0.25))
            ForEach(layout.clips) { clip in
                TimelineClipBlock(clip: clip,
                                  row: layout.rows[clip.uid] ?? 0,
                                  onPlay: onPlayClip)
            }
        }
        .frame(width: contentWidth,
               height: CGFloat(layout.rowCount) * BuilderTimelineModel.rowHeight)
        .dropDestination(for: String.self) { items, location in
            guard let payload = items.first, payload.hasPrefix("scene:"),
                  let sceneID = Int64(payload.dropFirst(6)),
                  let scene = model.scenes.first(where: { $0.id == sceneID }) else { return false }
            let time = BuilderTimelineModel.snap(Double(location.x / model.pointsPerSecond))
            // Only where the cropping row gives this track an area.
            guard model.canPlace(track: track, at: time) else { return false }
            model.addScene(scene, at: time, track: track)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}

/// One clip block: thumbnail background, badges, move/trim gestures.
struct TimelineClipBlock: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip
    let row: Int

    private struct PaceKey: Equatable {
        var videoID: Int64?
        var events: [FightEventRecord]
        var start: Double?
        var span: Double
    }

    /// Bucketed once per (clip range, events); clip blocks re-render on
    /// every drag frame and must not re-bucket the video's events each time.
    @State private var paceMemo = MemoBox<PaceKey, [Double]?>()

    /// Scored fight-action pace mapped through this clip's source range;
    /// nil when the clip's video has no scored events.
    private func clipPace(model: BuilderTimelineModel) -> [Double]? {
        let videoID = model.scene(for: clip)?.videoID
            ?? store.videos.first { $0.path == clip.videoFile }?.id
        guard let videoID, let events = store.fightEvents[videoID],
              let start = clip.sourceStart else { return nil }
        let key = PaceKey(videoID: videoID, events: events, start: start, span: clip.sourceSpan)
        return paceMemo(key) {
            let pace = FightGraphView.paceCurve(events: events, start: start,
                                                end: start + clip.sourceSpan,
                                                buckets: max(2, Int(clip.sourceSpan.rounded())))
            return pace.isEmpty ? nil : pace
        }
    }
    let onPlay: (TimelineClip) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .clip(clip.uid)
        let width = max(24, CGFloat(clip.duration) * pps + (isTrimming ? trimDelta : 0))
        let blockHeight = BuilderTimelineModel.rowHeight - 6
        let clipName = model.scene(for: clip)?.videoFilename ?? clip.videoFile ?? "Untitled"
        let accessibilityValue = "Track \(clip.track + 1), starts at \(clip.startTime.timecode), "
            + String(format: "%.1f seconds", clip.duration)

        ZStack(alignment: .bottomLeading) {
            if let url = model.sourceURL(for: clip) {
                VideoThumbnail(url: url, time: clip.sourceStart ?? 0, cornerRadius: 5)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(.gray.opacity(0.4))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .center, endPoint: .bottom)
            // Fight-action pace across this clip's source range — shows how
            // much scoring action the trim actually contains.
            if let pace = clipPace(model: model), pace.count > 1 {
                GeometryReader { proxy in
                    let size = proxy.size
                    let peak = max(1, pace.max() ?? 1)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, value) in pace.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(max(1, pace.count - 1))
                            let rise = CGFloat(value / peak) * min(16, size.height * 0.4)
                            path.addLine(to: CGPoint(x: x, y: size.height - rise))
                        }
                    }
                    .stroke(.red.opacity(0.75), lineWidth: 1)
                }
                .allowsHitTesting(false)
                .help("Fight action pace inside this clip — spikes are the scored moments")
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if clip.wide {
                        WideBadge(compact: true)
                    }
                    if clip.effectiveSpeed != 1 {
                        SpeedBadge(speed: clip.effectiveSpeed, compact: true)
                            .help("Plays at \(clip.effectiveSpeed.formatted())× speed")
                    }
                    if let score = model.scene(for: clip)?.score {
                        ScoreBadge(score: score, compact: true)
                    }
                    if clip.muted || (model.document.trackSettings[safe: clip.track]?.muted ?? false) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white)
                    }
                    if clip.transIn != nil {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if model.document.isOrphaned(clip) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help("Part of this clip has no crop area on this track and will not render")
                    }
                    Spacer(minLength: 0)
                }
                Text(String(format: "%.1fs", clip.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(4)
        }
        .frame(width: width, height: blockHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // The fill-scaled thumbnail overflows the block (a 20 s clip's 16:9
        // frame is hundreds of points tall); clipShape hides that but hit
        // testing does not, so without this a long clip catches clicks
        // meant for the lanes above it.
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder((isSelected || isFocused) ? Color.accentColor : .white.opacity(0.15),
                              lineWidth: (isSelected || isFocused) ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            // Trim handle: drag the right edge to change the clip duration.
            Rectangle()
                .fill(.white.opacity(isSelected ? 0.5 : 0.15))
                .frame(width: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        model.trimClip(clip.uid,
                                       duration: clip.duration + Double(value.translation.width / pps))
                        isTrimming = false
                        trimDelta = 0
                    })
        }
        .offset(x: CGFloat(clip.startTime) * pps + (isDragging ? dragOffset.width : 0),
                y: CGFloat(row) * BuilderTimelineModel.rowHeight + 3 + (isDragging ? dragOffset.height : 0))
        .opacity(isDragging ? 0.75 : 1)
        .zIndex(isDragging ? 10 : clip.startTime)
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            onPlay(clip)
        })
        .onTapGesture {
            model.selection = .clip(clip.uid)
            model.focusedTrack = clip.track
            isFocused = true
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                let newStart = BuilderTimelineModel.snap(
                    clip.startTime + Double(value.translation.width / pps))
                let newTrack = model.trackIndex(fromTrack: clip.track,
                                                verticalDelta: value.translation.height)
                model.selection = .clip(clip.uid)
                model.placeClip(clip.uid, startTime: newStart, track: newTrack)
                model.focusedTrack = model.clip(clip.uid)?.track ?? clip.track
                isDragging = false
                dragOffset = .zero
            })
        .contextMenu {
            Button("Play") { onPlay(clip) }
            Button("Duplicate") { model.duplicateClip(clip.uid) }
            Divider()
            Button("Delete", role: .destructive) { model.removeClip(clip.uid) }
        }
        .help(model.scene(for: clip)?.videoFilename ?? clip.videoFile ?? "")
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            model.selection = .clip(clip.uid)
            switch direction {
            case .left:
                model.placeClip(clip.uid, startTime: clip.startTime - 0.5, track: clip.track)
            case .right:
                model.placeClip(clip.uid, startTime: clip.startTime + 0.5, track: clip.track)
            case .up:
                model.placeClip(clip.uid, startTime: clip.startTime, track: max(0, clip.track - 1))
            case .down:
                model.placeClip(clip.uid, startTime: clip.startTime,
                                track: min(model.document.trackCount - 1, clip.track + 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip " + clipName)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Double-click to play. Use arrow keys to move the selected clip, or use the available actions.")
        .accessibilityAction(named: "Play") { onPlay(clip) }
        .accessibilityAction(named: "Move earlier") {
            model.placeClip(clip.uid, startTime: clip.startTime - 0.5, track: clip.track)
        }
        .accessibilityAction(named: "Move later") {
            model.placeClip(clip.uid, startTime: clip.startTime + 0.5, track: clip.track)
        }
        .accessibilityAction(named: "Trim shorter") {
            model.trimClip(clip.uid, duration: clip.duration - 0.5)
        }
        .accessibilityAction(named: "Trim longer") {
            model.trimClip(clip.uid, duration: clip.duration + 0.5)
        }
    }

}

// MARK: - Cropping row

/// Header for the cropping row: the name, plus an Add menu listing the
/// Screen Crop resources.
struct CropLaneHeader: View {
    @Environment(AppStore.self) private var store

    @State private var showAdd = false

    var body: some View {
        let model = store.builder
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .foregroundStyle(.secondary)
            Text("Cropping")
                .font(.caption)
            Spacer()
            // A plain button + popover, like the track settings gear: a
            // `Menu` here is an AppKit popup whose native view spilled over
            // the lanes beside and below it and swallowed their clicks.
            Button("Add Crop Layout", systemImage: "plus") {
                showAdd = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Add a Screen Crop layout at the playhead. Layouts come from Resources > Screen Crop.")
            .popover(isPresented: $showAdd) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(BuilderTimelineModel.availableCropLayouts(), id: \.self) { layout in
                        Button(layout.displayName) {
                            model.addCropBlock(layout)
                            showAdd = false
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    Divider()
                    Button("Split at Playhead") {
                        model.splitCropBlock()
                        showAdd = false
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                .padding(10)
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The cropping row: one block per stretch of the timeline, showing which
/// layout is on screen. Blocks tile the row gap-free; Full Screen fills in
/// wherever nothing else is placed.
struct CropLane: View {
    @Environment(AppStore.self) private var store
    let contentWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.25))
            ForEach(model.document.cropBlocks) { block in
                CropBlockView(block: block, height: height,
                              isLast: block.uid == model.document.cropBlocks.last?.uid,
                              contentWidth: contentWidth)
            }
        }
        .frame(width: contentWidth, height: height)
    }
}

/// One crop block: a small diagram of the layout's areas (the highlighted
/// track's area in green), the layout name, and a trailing handle that
/// moves the block's end.
struct CropBlockView: View {
    @Environment(AppStore.self) private var store
    let block: CropBlockItem
    let height: CGFloat
    let isLast: Bool
    let contentWidth: CGFloat

    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .crop(block.uid)
        let areas = block.layout.orderedAreas
        let missing = block.layout.isMissing
        // The last block reads as "to the end": it fills the visible row.
        let naturalWidth = CGFloat(block.duration) * pps
        let baseWidth = isLast ? max(naturalWidth, contentWidth - CGFloat(block.startTime) * pps) : naturalWidth
        let width = max(24, baseWidth + (isTrimming ? trimDelta : 0))
        let tint: Color = block.layout.isFullScreen ? .gray : .cyan

        HStack(spacing: 6) {
            CropLayoutDiagram(areas: areas, highlightedIndex: model.highlightedTrack,
                              fullScreen: block.layout.isFullScreen)
                .frame(width: (height - 14) * 9 / 16, height: height - 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.layout.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(missing ? "Layout missing — shown full screen"
                     : block.layout.isFullScreen ? "1 area"
                     : areas.map(\.name).joined(separator: " · "))
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8, alignment: .leading)
        .clipped()
        .background(tint.opacity(missing ? 0.35 : 0.5), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(isSelected ? 0.5 : 0.25))
                .frame(width: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        model.resizeCropBlock(block.uid,
                                              duration: block.duration + Double(value.translation.width / pps))
                        isTrimming = false
                        trimDelta = 0
                    })
                .help("Drag to change where this crop ends")
        }
        .offset(x: CGFloat(block.startTime) * pps, y: 4)
        .onTapGesture {
            model.selectCropBlock(block.uid)
        }
        .contextMenu {
            Menu("Change Layout") {
                ForEach(BuilderTimelineModel.availableCropLayouts(), id: \.self) { layout in
                    Button(layout.displayName) { model.setCropLayout(layout, for: block.uid) }
                }
            }
            Button("Split at Playhead") { model.splitCropBlock() }
            Divider()
            Button("Delete", role: .destructive) { model.removeCropBlock(block.uid) }
                .disabled(block.layout.isFullScreen)
        }
        .help("\(block.layout.displayName) from \(block.startTime.timecode) to \(block.endTime.timecode)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop \(block.layout.displayName)")
        .accessibilityValue("Starts at \(block.startTime.timecode), \(String(format: "%.1f", block.duration)) seconds, \(block.layout.areaCount) areas")
        .accessibilityHint("Drag the trailing edge to change its length. Use Select to change its layout.")
        .accessibilityAction(named: "Select") { model.selectCropBlock(block.uid) }
    }
}

/// A 9:16 thumbnail of a layout's areas. The area at `highlightedIndex`
/// (the focused track) is filled green; the rest are outlined.
struct CropLayoutDiagram: View {
    let areas: [ScreenCropArea]
    let highlightedIndex: Int?
    var fullScreen = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.black.opacity(0.35))
            if fullScreen || areas.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(highlightedIndex == 0 ? Color.green.opacity(0.85) : Color.white.opacity(0.25))
                    .padding(1)
            } else {
                ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                    ScreenCropPolygon(points: area.points)
                        .fill(index == highlightedIndex ? Color.green.opacity(0.85) : Color.white.opacity(0.25))
                    ScreenCropPolygon(points: area.points)
                        .stroke(.white.opacity(0.7), lineWidth: 0.5)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.white.opacity(0.6), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sound lane

struct SoundLane: View {
    @Environment(AppStore.self) private var store
    let contentWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.25))
            ForEach(model.document.soundTrack) { item in
                SoundBlock(item: item, height: height)
            }
        }
        .frame(width: contentWidth, height: height)
    }
}

struct SoundBlock: View {
    @Environment(AppStore.self) private var store
    let item: SoundItem
    let height: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .sound(item.uid)
        let width = max(24, CGFloat(item.duration) * pps + (isTrimming ? trimDelta : 0))

        HStack(spacing: 4) {
            Image(systemName: "music.note")
                .font(.caption)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Five-step volume indicator, like the web volume fader.
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level <= item.volume ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 2, height: CGFloat(3 + level * 2))
                }
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8)
        .background(Color.green.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        let newDuration = BuilderTimelineModel.snap(
                            item.duration + Double(value.translation.width / pps))
                        model.updateSound(item.uid) { $0.duration = max(0.5, newDuration) }
                        isTrimming = false
                        trimDelta = 0
                    })
        }
        .offset(x: CGFloat(item.startTime) * pps + (isDragging ? dragOffset : 0), y: 4)
        .onTapGesture {
            model.selection = .sound(item.uid)
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let newStart = BuilderTimelineModel.snap(
                    item.startTime + Double(value.translation.width / pps))
                model.updateSound(item.uid) { $0.startTime = newStart }
                isDragging = false
                dragOffset = 0
            })
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeSound(item.uid) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music \(item.name)")
        .accessibilityValue("Starts at \(item.startTime.timecode), \(String(format: "%.1f", item.duration)) seconds")
        .accessibilityHint("Drag to move or trim. Use Select to edit its settings.")
        .accessibilityAction(named: "Select") { model.selection = .sound(item.uid) }
    }
}

// MARK: - Unified overlay lane

/// One lane for texts, images, and overlay blocks. Overlapping items stack
/// into extra rows (the lane grows vertically) instead of painting over
/// each other.
struct OverlayLane: View {
    let layout: TimelineLayoutSnapshot
    let contentWidth: CGFloat

    var body: some View {
        let rowHeight = BuilderTimelineModel.overlayRowHeight
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.25))
            ForEach(layout.overlayEntries) { entry in
                let row = layout.overlayRows[entry.uid] ?? 0
                switch entry {
                case .text(let item):
                    TextBlock(item: item, row: row, height: rowHeight)
                case .image(let item):
                    ImageBlock(item: item, row: row, height: rowHeight)
                case .block(let item):
                    OverlayBlockView(item: item, row: row, height: rowHeight)
                }
            }
        }
        .frame(width: contentWidth, height: CGFloat(layout.overlayRowCount) * rowHeight)
    }
}

/// A placed overlay template: one indigo unit block on the lane.
struct OverlayBlockView: View {
    @Environment(AppStore.self) private var store
    let item: OverlayBlockItem
    let row: Int
    let height: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .overlay(item.uid)
        let width = max(24, CGFloat(item.duration) * pps + (isTrimming ? trimDelta : 0))

        HStack(spacing: 4) {
            Image(systemName: "square.2.layers.3d")
                .font(.caption)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(item.composition.texts.count + item.composition.images.count)")
                .font(.caption2.monospacedDigit())
                .opacity(0.7)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8)
        .background(Color.indigo.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        let newDuration = BuilderTimelineModel.snap(
                            item.duration + Double(value.translation.width / pps))
                        model.updateOverlayBlock(item.uid) { $0.duration = max(0.5, newDuration) }
                        isTrimming = false
                        trimDelta = 0
                    })
        }
        .offset(x: CGFloat(item.startTime) * pps + (isDragging ? dragOffset : 0),
                y: CGFloat(row) * BuilderTimelineModel.overlayRowHeight + 4)
        .onTapGesture {
            model.selection = .overlay(item.uid)
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let newStart = BuilderTimelineModel.snap(
                    item.startTime + Double(value.translation.width / pps))
                model.updateOverlayBlock(item.uid) { $0.startTime = newStart }
                isDragging = false
                dragOffset = 0
            })
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeOverlayBlock(item.uid) }
        }
        .help("\(item.name) — overlay template block")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overlay \(item.name)")
        .accessibilityValue("Starts at \(item.startTime.timecode), \(String(format: "%.1f", item.duration)) seconds")
        .accessibilityHint("Drag to move or trim. Use Select to edit its settings.")
        .accessibilityAction(named: "Select") { model.selection = .overlay(item.uid) }
    }
}

struct ImageBlock: View {
    @Environment(AppStore.self) private var store
    let item: ImageOverlayItem
    let row: Int
    let height: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .image(item.uid)
        let width = max(24, CGFloat(item.duration) * pps + (isTrimming ? trimDelta : 0))

        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.caption)
            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8)
        .background(Color.teal.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        let newEnd = BuilderTimelineModel.snap(
                            item.endTime + Double(value.translation.width / pps))
                        model.updateImage(item.uid) { $0.endTime = max($0.startTime + 0.5, newEnd) }
                        isTrimming = false
                        trimDelta = 0
                    })
        }
        .offset(x: CGFloat(item.startTime) * pps + (isDragging ? dragOffset : 0),
                y: CGFloat(row) * BuilderTimelineModel.overlayRowHeight + 4)
        .onTapGesture {
            model.selection = .image(item.uid)
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let duration = item.duration
                let newStart = BuilderTimelineModel.snap(
                    item.startTime + Double(value.translation.width / pps))
                model.updateImage(item.uid) {
                    $0.startTime = newStart
                    $0.endTime = newStart + duration
                }
                isDragging = false
                dragOffset = 0
            })
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeImage(item.uid) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image overlay \(item.displayName)")
        .accessibilityValue("Starts at \(item.startTime.timecode), \(String(format: "%.1f", item.duration)) seconds")
        .accessibilityHint("Drag to move or trim. Use Select to edit its settings.")
        .accessibilityAction(named: "Select") { model.selection = .image(item.uid) }
    }
}

// MARK: - Text block

struct TextBlock: View {
    @Environment(AppStore.self) private var store
    let item: TextOverlayItem
    let row: Int
    let height: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .text(item.uid)
        let width = max(24, CGFloat(item.duration) * pps + (isTrimming ? trimDelta : 0))

        HStack(spacing: 4) {
            Image(systemName: "textformat")
                .font(.caption)
            Text(item.text.isEmpty ? "Text" : item.text)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8)
        .background(Color.purple.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
                .resizeCursorOnHover()
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        let newEnd = BuilderTimelineModel.snap(
                            item.endTime + Double(value.translation.width / pps))
                        model.updateText(item.uid) { $0.endTime = max($0.startTime + 0.5, newEnd) }
                        isTrimming = false
                        trimDelta = 0
                    })
        }
        .offset(x: CGFloat(item.startTime) * pps + (isDragging ? dragOffset : 0),
                y: CGFloat(row) * BuilderTimelineModel.overlayRowHeight + 4)
        .onTapGesture {
            model.selection = .text(item.uid)
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let duration = item.duration
                let newStart = BuilderTimelineModel.snap(
                    item.startTime + Double(value.translation.width / pps))
                model.updateText(item.uid) {
                    $0.startTime = newStart
                    $0.endTime = newStart + duration
                }
                isDragging = false
                dragOffset = 0
            })
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeText(item.uid) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text overlay \(item.text.isEmpty ? "Text" : item.text)")
        .accessibilityValue("Starts at \(item.startTime.timecode), \(String(format: "%.1f", item.duration)) seconds")
        .accessibilityHint("Drag to move or trim. Use Select to edit its settings.")
        .accessibilityAction(named: "Select") { model.selection = .text(item.uid) }
    }
}
