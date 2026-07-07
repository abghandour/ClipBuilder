import SwiftUI

/// The multi-track timeline: time ruler, up to three video lanes, a sound
/// lane, and a text lane, all inside one horizontal scroller with pinned
/// track headers on the left. Clips are absolutely positioned views
/// (startTime × points-per-second) with drag-to-move, drag-between-tracks,
/// and a trailing trim handle — the SwiftUI port of the web builder timeline.
struct TimelineView: View {
    @Environment(AppStore.self) private var store
    let onPlayClip: (TimelineClip) -> Void

    private static let rulerHeight: CGFloat = 26
    private static let soundLaneHeight: CGFloat = 40
    private static let textLaneHeight: CGFloat = 40
    private static let headerWidth: CGFloat = 148

    var body: some View {
        let model = store.builder
        let contentWidth = max(800, CGFloat(model.totalDuration + 15) * model.pointsPerSecond)

        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                headerColumn(model: model)
                    .frame(width: Self.headerWidth)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
                        TimeRuler(contentWidth: contentWidth)
                            .frame(width: contentWidth, height: Self.rulerHeight)
                        ForEach(0..<model.document.trackCount, id: \.self) { track in
                            VideoTrackLane(track: track, contentWidth: contentWidth,
                                           onPlayClip: onPlayClip)
                        }
                        SoundLane(contentWidth: contentWidth, height: Self.soundLaneHeight)
                        TextLane(contentWidth: contentWidth, height: Self.textLaneHeight)
                    }
                    .overlay(alignment: .topLeading) {
                        PlayheadLine()
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(.background)
    }

    private func headerColumn(model: BuilderTimelineModel) -> some View {
        VStack(alignment: .leading, spacing: BuilderTimelineModel.laneSpacing) {
            Text(model.playhead.timecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: Self.rulerHeight)
                .padding(.leading, 8)
            ForEach(0..<model.document.trackCount, id: \.self) { track in
                TrackHeader(track: track)
                    .frame(height: model.laneHeight(forTrack: track))
            }
            laneHeader(title: "Sound", systemImage: "music.note")
                .frame(height: Self.soundLaneHeight)
            laneHeader(title: "Text", systemImage: "textformat")
                .frame(height: Self.textLaneHeight)
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
/// the layer settings popover.
struct TrackHeader: View {
    @Environment(AppStore.self) private var store
    let track: Int

    @State private var showSettings = false

    private static let numerals = ["I", "II", "III"]

    var body: some View {
        let model = store.builder
        let settings = model.document.trackSettings[safe: track] ?? TrackSettings()
        let sequential = model.document.trackSequential[safe: track] ?? true
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Track \(Self.numerals[safe: track] ?? "\(track + 1)")")
                    .font(.caption.bold())
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .popover(isPresented: $showSettings) {
                    TrackSettingsPopover(track: track)
                }
            }
            HStack(spacing: 6) {
                Button {
                    model.updateTrackSettings(track) { $0.muted.toggle() }
                } label: {
                    Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(settings.muted ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(settings.muted ? "Unmute layer" : "Mute layer")

                Button {
                    model.setTrackSequential(!sequential, track: track)
                } label: {
                    Text(sequential ? "SEQ" : "FREE")
                        .font(.caption2.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(sequential ? "Sequential: clips pack end-to-end" : "Free-form: clips stay where you drop them")
                Spacer()
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Per-layer settings: mute, default wide position, layer captions, default crop.
struct TrackSettingsPopover: View {
    @Environment(AppStore.self) private var store
    let track: Int

    var body: some View {
        let model = store.builder
        let settings = model.document.trackSettings[safe: track] ?? TrackSettings()
        Form {
            Toggle("Muted", isOn: Binding(
                get: { settings.muted },
                set: { value in model.updateTrackSettings(track) { $0.muted = value } }))
            Picker("Wide position", selection: Binding(
                get: { settings.defaultPosition },
                set: { value in model.updateTrackSettings(track) { $0.defaultPosition = value } })) {
                Text("Top").tag("top")
                Text("Center").tag("center")
                Text("Bottom").tag("bottom")
            }
            Picker("Captions", selection: Binding(
                get: { settings.captions },
                set: { value in model.updateTrackSettings(track) { $0.captions = value } })) {
                Text("None").tag("none")
                Text("Top").tag("top")
                Text("Middle").tag("middle")
                Text("Bottom").tag("bottom")
            }
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
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                model.playhead = max(0, Double(value.location.x / pps))
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

// MARK: - Video lane

/// One video track: a lane of absolutely positioned clip blocks that accepts
/// scene drops from the clip browser.
struct VideoTrackLane: View {
    @Environment(AppStore.self) private var store
    let track: Int
    let contentWidth: CGFloat
    let onPlayClip: (TimelineClip) -> Void

    @State private var isDropTarget = false

    var body: some View {
        let model = store.builder
        let layout = model.rowLayout(forTrack: track)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(isDropTarget ? 0.55 : 0.25))
            ForEach(model.clips(inTrack: track)) { clip in
                TimelineClipBlock(clip: clip,
                                  row: layout.rows[clip.uid] ?? 0,
                                  onPlay: onPlayClip)
            }
        }
        .frame(width: contentWidth, height: model.laneHeight(forTrack: track))
        .dropDestination(for: String.self) { items, location in
            guard let payload = items.first, payload.hasPrefix("scene:"),
                  let sceneID = Int64(payload.dropFirst(6)),
                  let scene = model.scenes.first(where: { $0.id == sceneID }) else { return false }
            model.addScene(scene, at: Double(location.x / model.pointsPerSecond), track: track)
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
    let onPlay: (TimelineClip) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var trimDelta: CGFloat = 0
    @State private var isTrimming = false

    var body: some View {
        let model = store.builder
        let pps = model.pointsPerSecond
        let isSelected = model.selection == .clip(clip.uid)
        let width = max(24, CGFloat(clip.duration) * pps + (isTrimming ? trimDelta : 0))
        let blockHeight = BuilderTimelineModel.rowHeight - 6

        ZStack(alignment: .bottomLeading) {
            if let url = model.sourceURL(for: clip) {
                VideoThumbnail(url: url, time: clip.sourceStart ?? 0, cornerRadius: 5)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(.gray.opacity(0.4))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if clip.wide {
                        badge("WIDE", color: .orange)
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
                    Spacer(minLength: 0)
                }
                Text(String(format: "%.1fs", clip.duration))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(4)
        }
        .frame(width: width, height: blockHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.15),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            // Trim handle: drag the right edge to change the clip duration.
            Rectangle()
                .fill(.white.opacity(isSelected ? 0.5 : 0.15))
                .frame(width: 5)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
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
        .zIndex(isDragging ? 10 : Double(clip.stackOrder))
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            onPlay(clip)
        })
        .onTapGesture {
            model.selection = .clip(clip.uid)
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
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
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
                .font(.system(size: 9))
            Text(item.name)
                .font(.system(size: 10))
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
                .frame(width: 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
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
    }
}

// MARK: - Text lane

struct TextLane: View {
    @Environment(AppStore.self) private var store
    let contentWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let model = store.builder
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.25))
            ForEach(model.document.textOverlays) { item in
                TextBlock(item: item, height: height)
            }
        }
        .frame(width: contentWidth, height: height)
    }
}

struct TextBlock: View {
    @Environment(AppStore.self) private var store
    let item: TextOverlayItem
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
                .font(.system(size: 9))
            Text(item.text.isEmpty ? "Text" : item.text)
                .font(.system(size: 10))
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
                .frame(width: 4)
                .padding(.vertical, 8)
                .contentShape(Rectangle().inset(by: -4))
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
        .offset(x: CGFloat(item.startTime) * pps + (isDragging ? dragOffset : 0), y: 4)
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
    }
}
