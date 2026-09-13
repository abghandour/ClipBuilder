import SwiftUI
import AppKit

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
    @State private var tracksScrollPosition = ScrollPosition()
    @State private var scrollbarPosition = ScrollPosition()
    @State private var visibleRect: CGRect?

    private struct HorizontalViewport: Equatable {
        var rect: CGRect
        var offset: Double
    }

    private static let rulerHeight: CGFloat = 26
    static let cropLaneHeight: CGFloat = 52
    private static let soundLaneHeight: CGFloat = 40
    private static let textLaneHeight: CGFloat = 40
    private static let headerWidth: CGFloat = 148
    private static let scrollbarHeight: CGFloat = 14

    var body: some View {
        let model = store.builder
        let contentWidth = max(800, CGFloat(model.totalDuration + 15) * model.pointsPerSecond)
        let layout = model.timelineLayout()

        // Three bands share one horizontal offset: the pinned ruler + Screen
        // row on top, the vertically scrolling tracks in the middle, and a
        // pinned horizontal scrollbar at the bottom. Only the top band and
        // the scrollbar own a horizontal ScrollView; the tracks band follows
        // their offset so it never shows a second scrollbar.
        GeometryReader { viewport in
            let viewportRect = visibleRect ?? CGRect(
                x: store.timelineScrollX, y: 0,
                width: max(1, viewport.size.width - Self.headerWidth), height: 0)
            VStack(spacing: 0) {
                pinnedTop(model: model, contentWidth: contentWidth)
                Divider()
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        trackHeaders(model: model, layout: layout)
                            .frame(width: Self.headerWidth)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
                                ForEach(0..<model.document.trackCount, id: \.self) { track in
                                    VideoTrackLane(track: track, layout: layout.videoTracks[track],
                                                   contentWidth: contentWidth,
                                                   visibleRect: viewportRect,
                                                   cullClips: model.document.videoTrack.count >= 40,
                                                   onPlayClip: onPlayClip)
                                }
                                SoundLane(contentWidth: contentWidth, height: Self.soundLaneHeight)
                                OverlayLane(layout: layout, contentWidth: contentWidth)
                            }
                            .padding(.top, BuilderTimelineModel.laneSpacing)
                            .overlay(alignment: .topLeading) {
                                PlayheadLine()
                            }
                            .padding(.bottom, 8)
                        }
                        .scrollIndicators(.hidden)
                        .scrollDisabled(true)
                        .scrollPosition($tracksScrollPosition)
                    }
                }
                .scrollPosition($verticalScrollPosition)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    Double(geometry.contentOffset.y)
                } action: { _, offset in
                    store.timelineScrollY = max(0, offset)
                }
                Divider()
                scrollbar(contentWidth: contentWidth)
            }
            .onAppear(perform: restoreScrollPosition)
            .onChange(of: store.openTimelineID) { restoreScrollPosition() }
            .onChange(of: store.activeProjectID) { restoreScrollPosition() }
            .background(.background)
        }
    }

    /// Ruler and Screen row: always visible, and the band that owns the
    /// horizontal scroll (trackpad swipes here move every band).
    private func pinnedTop(model: BuilderTimelineModel, contentWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
                PlayheadTimecode()
                    .frame(height: Self.rulerHeight)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TimelineTrackStyle.ruler, in: TimelineTrackStyle.headerShape)
                CropLaneHeader()
                    .frame(height: Self.cropLaneHeight)
            }
            .frame(width: Self.headerWidth)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
                    TimeRuler(contentWidth: contentWidth)
                        .frame(width: contentWidth, height: Self.rulerHeight)
                        .background(TimelineTrackStyle.ruler, in: TimelineTrackStyle.laneShape)
                    CropLane(contentWidth: contentWidth, height: Self.cropLaneHeight)
                }
                .overlay(alignment: .topLeading) {
                    PlayheadLine()
                }
            }
            .scrollIndicators(.hidden)
            .scrollPosition($horizontalScrollPosition)
            .onScrollGeometryChange(for: HorizontalViewport.self) { geometry in
                HorizontalViewport(rect: geometry.visibleRect, offset: Double(geometry.contentOffset.x))
            } action: { _, viewport in
                visibleRect = viewport.rect
                let x = max(0, viewport.offset)
                store.timelineScrollX = x
                tracksScrollPosition.scrollTo(x: x)
                scrollbarPosition.scrollTo(x: x)
            }
        }
        .frame(height: Self.rulerHeight + BuilderTimelineModel.laneSpacing + Self.cropLaneHeight)
    }

    /// A horizontal scroller that is only ever as tall as its indicator,
    /// pinned under the tracks so the scrollbar never leaves the screen.
    private func scrollbar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.headerWidth)
            ScrollView(.horizontal) {
                Color.clear.frame(width: contentWidth, height: 1)
            }
            .scrollIndicators(.visible)
            .scrollPosition($scrollbarPosition)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.x)
            } action: { _, offset in
                // Dragging the indicator drives the pinned band, which
                // fans the offset out to the tracks.
                let x = max(0, offset)
                if abs(x - store.timelineScrollX) > 0.5 { horizontalScrollPosition.scrollTo(x: x) }
            }
        }
        .frame(height: Self.scrollbarHeight)
    }

    private func restoreScrollPosition() {
        visibleRect = nil
        horizontalScrollPosition.scrollTo(x: store.timelineScrollX)
        tracksScrollPosition.scrollTo(x: store.timelineScrollX)
        scrollbarPosition.scrollTo(x: store.timelineScrollX)
        verticalScrollPosition.scrollTo(y: store.timelineScrollY)
    }

    /// Pinned headers for the scrolling band: one per video track, then Sound and Overlays.
    @ViewBuilder
    private func trackHeaders(model: BuilderTimelineModel, layout: TimelineLayoutSnapshot) -> some View {
        VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
            ForEach(0..<model.document.trackCount, id: \.self) { track in
                TrackHeader(track: track)
                    .frame(height: layout.videoTracks[track].laneHeight)
            }
            laneHeader(title: "Sound", systemImage: "music.note", shade: TimelineTrackStyle.sound)
                .frame(height: Self.soundLaneHeight)
            laneHeader(title: "Overlays", systemImage: "square.2.layers.3d", shade: TimelineTrackStyle.overlays)
                .frame(height: CGFloat(layout.overlayRowCount)
                       * BuilderTimelineModel.overlayRowHeight)
        }
        .padding(.top, BuilderTimelineModel.laneSpacing)
    }

    private func laneHeader(title: String, systemImage: String, shade: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shade, in: TimelineTrackStyle.headerShape)
    }
}

/// The same neutral shade joins each pinned header to its video lane.
private enum TimelineTrackStyle {
    // Alternate light/dark values so neighbouring tracks are easy to separate.
    static func background(track: Int) -> Color {
        let shades = [0.025, 0.17, 0.065, 0.21, 0.105, 0.25]
        return Color.primary.opacity(shades[track % shades.count])
    }

    static let ruler = Color.primary.opacity(0.045)
    static let screen = Color.primary.opacity(0.12)
    static let sound = Color.primary.opacity(0.035)
    static let overlays = Color.primary.opacity(0.19)

    static var headerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6)
    }

    static var laneShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6)
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
                Text(settings.label?.isEmpty == false
                     ? settings.label!
                     : "Track \(Self.numerals[safe: track] ?? "\(track + 1)")")
                    .font(.caption.bold())
                    .help("Click the header to highlight this track's crop area")
                TrackAreaLabel(track: track, highlighted: highlighted)
                let cutaways = model.document.cutaways(inTrack: track).count
                if cutaways > 0 {
                    Text("\(cutaways) B-roll")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("B-roll on this track covers its area for a while; it never moves the clips around it")
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(highlighted ? Color.green.opacity(0.18) : Color.clear,
                    in: TimelineTrackStyle.headerShape)
        .background(TimelineTrackStyle.background(track: track), in: TimelineTrackStyle.headerShape)
        .overlay {
            TimelineTrackStyle.headerShape
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
                .help("Mute footage in this area")
            if hasFullScreen {
                Picker("Wide position", selection: Binding(
                    get: { settings.defaultPosition },
                    set: { value in model.updateTrackSettings(track) { $0.defaultPosition = value } })) {
                    Text("Top").tag("top")
                    Text("Center").tag("center")
                    Text("Bottom").tag("bottom")
                }
                .help("Place wide footage at the top, center, or bottom of the full screen")
            }
            Picker("Captions", selection: Binding(
                get: { settings.captions },
                set: { value in model.updateTrackSettings(track) { $0.captions = value } })) {
                Text("None").tag("none")
                Text("Top").tag("top")
                Text("Middle").tag("middle")
                Text("Bottom").tag("bottom")
            }
            .help("Place captions for footage in this area")
            EffectControls(effect: Binding(
                get: { model.document.trackSettings[safe: track]?.effect },
                set: { value in model.updateTrackSettings(track) { $0.effect = value } }))
            if hasFullScreen {
                HStack {
                    Toggle("Default crop", isOn: Binding(
                        get: { settings.defaultCropXFrac != nil },
                        set: { value in
                            model.updateTrackSettings(track) { $0.defaultCropXFrac = value ? 0.5 : nil }
                        }))
                        .help("Crop wide footage to fill the full screen by default")
                    if let crop = settings.defaultCropXFrac {
                        Slider(value: Binding(
                            get: { crop },
                            set: { value in model.updateTrackSettings(track) { $0.defaultCropXFrac = value } }),
                            in: 0...1)
                            .frame(width: 120)
                            .accessibilityLabel("Default horizontal crop")
                            .help("Horizontal crop position: 0…1")
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

/// Hands back the window a view is in. SwiftUI's context menu carries no
/// event, so the lane converts `NSEvent.mouseLocation` through its OWN
/// window rather than whichever window happens to be key.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    final class Reader: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: Reader, context: Context) {
        nsView.onResolve = onResolve
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
    let visibleRect: CGRect
    let cullClips: Bool
    let onPlayClip: (TimelineClip) -> Void

    @State private var isDropTarget = false
    @State private var interactingClips: Set<UUID> = []
    @State private var hoverX: CGFloat = 0
    /// The lane's frame in window coordinates, and the window it is in, so
    /// a context click's real position can be turned back into a time.
    @State private var laneFrame: CGRect = .zero
    @State private var laneWindow: NSWindow?

    private func visibleClips(model: BuilderTimelineModel) -> [TimelineClip] {
        // Keep the full destination lane alive during scene drops, including
        // offscreen targets reached by edge scrolling. Filter preserves z-order.
        guard cullClips, !isDropTarget else { return layout.clips }
        let lower = visibleRect.minX - visibleRect.width
        let upper = visibleRect.maxX + visibleRect.width
        return layout.clips.filter { clip in
            if model.selection == .clip(clip.uid) || interactingClips.contains(clip.uid) { return true }
            let x = CGFloat(clip.startTime) * model.pointsPerSecond
            let width = max(24, CGFloat(clip.duration) * model.pointsPerSecond)
            return x + width >= lower && x <= upper
        }
    }

    /// Where the pointer is right now, as a timeline time in this lane.
    /// AppKit reports the mouse in screen coordinates; converting through
    /// the window gives the same x SwiftUI's global space uses, and only x
    /// maps to time.
    private func contextClickTime(pointsPerSecond: Double) -> Double {
        var x = hoverX
        if let window = laneWindow, laneFrame != .zero {
            let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            x = inWindow.x - laneFrame.minX
        }
        return max(0, BuilderTimelineModel.snap(Double(x / pointsPerSecond)))
    }

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            TimelineTrackStyle.laneShape
                .fill(TimelineTrackStyle.background(track: track))
                .overlay {
                    if isDropTarget {
                        TimelineTrackStyle.laneShape.fill(.primary.opacity(0.1))
                    }
                }
            ForEach(visibleClips(model: model)) { clip in
                TimelineClipBlock(clip: clip,
                                  row: layout.rows[clip.uid] ?? 0,
                                  bandOffset: layout.mainRowsOffset,
                                  onPlay: onPlayClip,
                                  onInteractionChange: { id, active in
                                      if active { interactingClips.insert(id) }
                                      else { interactingClips.remove(id) }
                                  })
            }
            // B-roll rides above the main rows in its own thin band and
            // never takes part in packing.
            ForEach(layout.cutaways) { clip in
                TimelineClipBlock(clip: clip,
                                  row: layout.cutawayRows[clip.uid] ?? 0,
                                  stripBand: true,
                                  onPlay: onPlayClip,
                                  onInteractionChange: { id, active in
                                      if active { interactingClips.insert(id) }
                                      else { interactingClips.remove(id) }
                                  })
            }
        }
        .frame(width: contentWidth, height: layout.laneHeight, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { laneFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in laneFrame = frame }
                    .background(WindowReader { laneWindow = $0 })
            }
        )
        .dropDestination(for: String.self) { items, location in
            guard let payload = items.first,
                  let parsed = TimelineDropPayload.parse(payload),
                  let scene = model.scenes.first(where: { $0.id == parsed.sceneID }) else { return false }
            let time = BuilderTimelineModel.snap(Double(location.x / model.pointsPerSecond))
            // Only where the Screen row gives this track an area.
            guard model.canPlace(track: track, at: time) else { return false }
            if parsed.cutaway {
                // Option-drag: B-roll with the default window.
                _ = model.addCutaway(source: .scene(scene), at: time, track: track)
            } else {
                model.addScene(scene, at: time, track: track)
            }
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .onContinuousHover { phase in
            // A fallback for the context menu when there is no window to
            // ask (previews, tests): the last place the pointer was.
            if case .active(let point) = phase { hoverX = point.x }
        }
        .contextMenu {
            // This builder runs when the menu opens, while the pointer is
            // still on the spot that was right-clicked, so the real event
            // location can be read here (only x matters: it is what maps to
            // a time, and the track comes from the lane itself).
            let clickedTime = contextClickTime(pointsPerSecond: model.pointsPerSecond)
            Button("Cover with B-roll…") {
                model.brollRequest = BuilderTimelineModel.BRollRequest(time: clickedTime, track: track)
            }
            .help("Open the B-roll picker at \(clickedTime.timecode) on this track")
        }
    }
}

/// One clip block: thumbnail background, badges, move/trim gestures.
struct TimelineClipBlock: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip
    let row: Int
    /// B-roll draws as a thinner strip above the track's main rows.
    var stripBand: Bool = false
    /// How far the main rows sit below the top of the lane (the strip band).
    var bandOffset: CGFloat = 0

    /// Where this block sits inside its lane — the strip band for B-roll,
    /// below it for main clips. Drag geometry measures from here.
    private var blockY: CGFloat {
        stripBand ? CGFloat(row) * BuilderTimelineModel.stripHeight + 2
                  : bandOffset + CGFloat(row) * BuilderTimelineModel.rowHeight + 3
    }

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
    let onInteractionChange: (UUID, Bool) -> Void

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
        let blockHeight = stripBand ? BuilderTimelineModel.stripHeight - 4
            : BuilderTimelineModel.rowHeight - 6
        let clipName = clip.bumper ? "Bumper · " + store.bumperDisplayName(for: clip)
            : model.scene(for: clip)?.videoFilename ?? clip.videoFile ?? "Untitled"
        let accessibilityValue = "Track \(clip.track + 1), starts at \(clip.startTime.timecode), "
            + String(format: "%.1f seconds", clip.duration)

        ZStack(alignment: .bottomLeading) {
            if let url = model.sourceURL(for: clip), !clip.bumper || FileManager.default.fileExists(atPath: url.path) {
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
                    if clip.bumper {
                        Label("Bumper · " + store.bumperDisplayName(for: clip), systemImage: "film.stack")
                            .font(.caption2).foregroundStyle(.white)
                            .padding(3).background(.purple, in: .capsule)
                        if !FileManager.default.fileExists(atPath: clip.videoFile ?? "") {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow).help("Bumper file is missing")
                        }
                    }
                    if clip.isCutaway {
                        Text("B")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .background(.orange, in: .capsule)
                            .help("B-roll: it covers this track's area and never moves the clips around it")
                        if clip.coverAllAreas {
                            Text("all areas")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .background(.orange.opacity(0.55), in: .capsule)
                                .help("This B-roll covers the whole screen, not just this track's area")
                        }
                    }
                    if clip.wide && !clip.bumper && !clip.isCutaway {
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
                    if model.document.isCoveredByBumper(clip) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple)
                            .help("A bumper covers part of this clip; that stretch is not shown or heard")
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
        .overlay {
            // Shade the stretches a bumper covers, so hidden footage reads
            // as hidden rather than quietly missing from the render.
            let coverage = model.document.bumperCoverage(of: clip)
            if !coverage.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(Array(coverage.enumerated()), id: \.offset) { _, range in
                        Rectangle()
                            .fill(Color.purple.opacity(0.45))
                            .frame(width: max(2, CGFloat(range.upperBound - range.lowerBound) * pps))
                            .offset(x: CGFloat(range.lowerBound - clip.startTime) * pps)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        // The fill-scaled thumbnail overflows the block (a 20 s clip's 16:9
        // frame is hundreds of points tall); clipShape hides that but hit
        // testing does not, so without this a long clip catches clicks
        // meant for the lanes above it.
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder((isSelected || isFocused) ? Color.accentColor
                              : (clip.isCutaway ? Color.orange.opacity(0.9) : .white.opacity(0.15)),
                              style: StrokeStyle(lineWidth: (isSelected || isFocused) ? 2 : 1,
                                                 dash: clip.isCutaway ? [4, 3] : []))
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
                        if !isTrimming { onInteractionChange(clip.uid, true) }
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
                y: blockY + (isDragging ? dragOffset.height : 0))
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
                if !isDragging { onInteractionChange(clip.uid, true) }
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                let newStart = BuilderTimelineModel.snap(
                    clip.startTime + Double(value.translation.width / pps))
                let newTrack = model.trackIndex(fromTrack: clip.track,
                                                verticalDelta: value.translation.height,
                                                blockOffset: blockY)
                model.selection = .clip(clip.uid)
                model.placeClip(clip.uid, startTime: newStart, track: newTrack)
                model.focusedTrack = model.clip(clip.uid)?.track ?? clip.track
                isDragging = false
                dragOffset = .zero
            })
        .contextMenu {
            Button("Play") { onPlay(clip) }
            Button("Duplicate") { model.duplicateClip(clip.uid) }
            if !clip.bumper {
                Divider()
                if clip.isCutaway {
                    Button("Make Main Clip") { model.setClipRole(clip.uid, role: .main) }
                        .help("Puts this clip back in the track's sequence, which repacks the track from the start. It keeps no captions, Center Stage or free crops.")
                } else {
                    Button("Make B-roll") { model.setClipRole(clip.uid, role: .cutaway) }
                        .help("Turns this clip into B-roll pinned to its time: it drops captions, Center Stage and free crops, is muted, and the track repacks without it.")
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.removeClip(clip.uid) }
        }
        .help(model.scene(for: clip)?.videoFilename ?? clip.videoFile ?? "")
        .focusable()
        .focused($isFocused)
        .onChange(of: isDragging || isTrimming || isFocused) { _, active in
            onInteractionChange(clip.uid, active)
        }
        .onDisappear { onInteractionChange(clip.uid, false) }
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
            @unknown default:
                break
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

/// Header for the Screen row: the name, plus an Add menu listing the
/// Screen Crop resources.
struct CropLaneHeader: View {
    @Environment(AppStore.self) private var store

    @State private var showAdd = false

    var body: some View {
        let model = store.builder
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .foregroundStyle(.secondary)
            Text("Screen")
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
            .help("Add a Screen Crop layout or a bumper at the playhead. Layouts come from Resources > Screen Crop, bumpers from Resources > Bumpers.")
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
                    Divider()
                    Text("Bumpers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    if store.bumpers.isEmpty {
                        Text("Add short videos under Resources > Bumpers")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(store.bumpers) { bumper in
                        Button(bumper.displayName) {
                            model.addBumper(bumper)
                            showAdd = false
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .disabled(bumper.duration == nil)
                    }
                }
                .padding(10)
                .frame(width: 220)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(TimelineTrackStyle.screen, in: TimelineTrackStyle.headerShape)
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
            TimelineTrackStyle.laneShape
                .fill(TimelineTrackStyle.screen)
            ForEach(model.document.cropBlocks) { block in
                CropBlockView(block: block, height: height,
                              isLast: block.uid == model.document.cropBlocks.last?.uid,
                              contentWidth: contentWidth)
            }
            // Bumpers sit above the layouts: while one plays, nothing else
            // on the timeline is shown or heard.
            ForEach(model.timelineLayout().bumpers) { bumper in
                BumperBlockView(clip: bumper, height: height)
            }
        }
        // A block can be wider than the lane (a crop that runs past the
        // content width); anchoring at the leading edge keeps its label in
        // view instead of centring the overflow and hiding it.
        .frame(width: contentWidth, height: height, alignment: .topLeading)
    }
}

/// A bumper on the cropping row: full-screen, top priority, movable in
/// time and trimmable at its right edge. Selecting it opens the inspector.
struct BumperBlockView: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip
    let height: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .clip(clip.uid)
        let width = max(24, CGFloat(clip.duration) * pps + (isTrimming ? trimDelta : 0))
        let missing = !FileManager.default.fileExists(atPath: clip.videoFile ?? "")
        let name = store.bumperDisplayName(for: clip)

        HStack(spacing: 6) {
            if let url = model.sourceURL(for: clip), !missing {
                VideoThumbnail(url: url, time: 0, cornerRadius: 3)
                    .frame(width: (height - 14) * 9 / 16, height: height - 14)
            } else {
                Image(systemName: "film.stack")
                    .frame(width: (height - 14) * 9 / 16, height: height - 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Bumper · \(name)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if missing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help("Bumper file is missing")
                    }
                }
                Text(String(format: "%.1fs · ", clip.duration) + clip.bumperMode.badge)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .frame(width: width, height: height - 8, alignment: .leading)
        .clipped()
        .background(Color.purple.opacity(missing ? 0.5 : 0.85), in: RoundedRectangle(cornerRadius: 5))
        // The whole block is the hit target for selecting and moving; the
        // thumbnail and labels inside must not swallow the press.
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.25),
                              lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
        // Move: the press anywhere on the block starts a drag; a plain
        // click selects. High priority so the block wins over the lane
        // and the scroll view, which otherwise claimed the first pixels.
        .highPriorityGesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging { model.selection = .clip(clip.uid) }
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                model.placeClip(clip.uid, startTime: clip.startTime + Double(value.translation.width / pps), track: 0)
                isDragging = false
                dragOffset = 0
            })
        .onTapGesture { model.selection = .clip(clip.uid) }
        .overlay(alignment: .trailing) {
            // Trim: a narrow grip on the right edge, added after the move
            // gesture so it takes precedence only inside its own strip.
            Rectangle()
                .fill(.white.opacity(isSelected ? 0.5 : 0.25))
                .frame(width: 6)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -3))
                .resizeCursorOnHover()
                .highPriorityGesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isTrimming = true
                        trimDelta = value.translation.width
                    }
                    .onEnded { value in
                        model.trimClip(clip.uid, duration: clip.duration + Double(value.translation.width / pps))
                        isTrimming = false
                        trimDelta = 0
                    })
                .help("Drag to change how long the bumper plays")
        }
        .offset(x: CGFloat(clip.startTime) * pps + (isDragging ? dragOffset : 0), y: 4)
        .opacity(isDragging ? 0.75 : 1)
        .zIndex(100 + clip.startTime)
        .contextMenu {
            Picker("Behavior", selection: Binding(
                get: { clip.bumperMode },
                set: { model.setBumperMode(clip.uid, mode: $0) })) {
                ForEach(BumperMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Button("Duplicate") { model.duplicateClip(clip.uid) }
            Divider()
            Button("Delete", role: .destructive) { model.removeClip(clip.uid) }
        }
        .help("Bumper, \(clip.bumperMode.title.lowercased()): plays full screen and alone for \(String(format: "%.1f", clip.duration)) seconds. Drag to move; drag the right edge to trim.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bumper \(name)")
        .accessibilityValue("Starts at \(clip.startTime.timecode), " + String(format: "%.1f seconds", clip.duration))
        .accessibilityHint("Covers every track while it plays.")
        .accessibilityAction(named: "Move earlier") { model.nudgeBumper(clip.uid, by: -0.5) }
        .accessibilityAction(named: "Move later") { model.nudgeBumper(clip.uid, by: 0.5) }
        .accessibilityAction(named: "Delete") { model.removeClip(clip.uid) }
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
        let looks: [Int: String] = Dictionary(uniqueKeysWithValues:
            (0..<block.layout.areaCount).compactMap { index -> (Int, String)? in
                guard let effect = model.document.trackSettings[safe: index]?.effect,
                      effect.preset != "none", effect.intensity > 0 else { return nil }
                return (index, EffectCatalog.preset(for: effect.preset)?.name ?? effect.preset)
            })
        let lookSummary = looks.isEmpty ? "" : " · \(looks.count) \(looks.count == 1 ? "look" : "looks")"
        // The last block reads as "to the end": it fills the visible row.
        let naturalWidth = CGFloat(block.duration) * pps
        let room = contentWidth - CGFloat(block.startTime) * pps
        let baseWidth = isLast ? max(naturalWidth, room) : naturalWidth
        let width = max(24, min(baseWidth, max(24, room)) + (isTrimming ? trimDelta : 0))
        let tint: Color = block.layout.isFullScreen ? .gray : .cyan

        HStack(spacing: 6) {
            CropLayoutDiagram(areas: areas, highlightedIndex: model.highlightedTrack,
                              fullScreen: block.layout.isFullScreen, looks: looks)
                .frame(width: (height - 14) * 9 / 16, height: height - 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.layout.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text((missing ? "Layout missing — shown full screen"
                     : block.layout.isFullScreen ? "1 area"
                     : areas.map(\.name).joined(separator: " · ")) + lookSummary)
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
        .help("\(block.layout.displayName) from \(block.startTime.timecode) to \(block.endTime.timecode)"
              + looks.keys.sorted().map { " · Area \($0 + 1): \(looks[$0] ?? "")" }.joined())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop \(block.layout.displayName)")
        .accessibilityValue("Starts at \(block.startTime.timecode), \(String(format: "%.1f", block.duration)) seconds, \(block.layout.areaCount) areas" + lookSummary)
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
    var looks: [Int: String] = [:]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.black.opacity(0.35))
            if fullScreen || areas.isEmpty {
                RoundedRectangle(cornerRadius: 2)
                    .fill(highlightedIndex == 0 ? Color.green.opacity(0.85) : Color.white.opacity(0.25))
                    .padding(1)
                if looks[0] != nil {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                }
            } else {
                ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                    ScreenCropPolygon(points: area.points)
                        .fill(index == highlightedIndex ? Color.green.opacity(0.85) : Color.white.opacity(0.25))
                    ScreenCropPolygon(points: area.points)
                        .stroke(.white.opacity(0.7), lineWidth: 0.5)
                    if looks[index] != nil {
                        ScreenCropPolygon(points: area.points)
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                    }
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
            TimelineTrackStyle.laneShape
                .fill(TimelineTrackStyle.sound)
            ForEach(model.document.soundTrack) { item in
                SoundBlock(item: item, height: height)
            }
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
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
            TimelineTrackStyle.laneShape
                .fill(TimelineTrackStyle.overlays)
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
        .frame(width: contentWidth, height: CGFloat(layout.overlayRowCount) * rowHeight, alignment: .topLeading)
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
