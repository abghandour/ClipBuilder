import SwiftUI

/// Trim controls for the selected Builder clip against its raw source
/// video — the same surfaces the Curated wizard uses: a full-clip filmstrip
/// with draggable start/end handles, a magnified 10-second loupe when the
/// selection is short, the fight-action pace sparkline on both, and the
/// fight activity graph for scored footage. Edits write straight to the
/// clip (source range and screen duration); the preview follows scrubs.
struct ClipTrimEditor: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip

    @State private var zoomWindowStart: Double = 0
    /// Selection being dragged. The strips edit this copy; the clip (and
    /// with it the timeline, preview, and graph) updates on release, so a
    /// drag never re-lays out the whole Builder per pixel.
    @State private var draft: (start: Double, end: Double)?
    @State private var pendingScrub: Double?
    /// Whether the loupe is shown — decided from the committed selection
    /// and animated, never flipped mid-drag.
    @State private var showLoupe = false

    private static let loupeSpan = 10.0

    private var model: BuilderTimelineModel { store.builder }
    private var scene: SceneRecord? { model.scene(for: clip) }

    private var video: VideoRecord? {
        if let scene { return store.videos.first { $0.id == scene.videoID } }
        return store.videos.first { $0.path == clip.videoFile }
    }

    private var videoDuration: Double {
        scene?.videoDuration ?? video?.duration ?? max(clip.sourceEnd ?? 0, (clip.sourceStart ?? 0) + clip.sourceSpan)
    }

    /// Committed range (what the clip holds).
    private var sourceStart: Double { clip.sourceStart ?? scene?.startTime ?? 0 }
    private var sourceEnd: Double { sourceStart + clip.sourceSpan }

    /// Range the strips show: the draft while dragging, else the clip's.
    private var editStart: Double { draft?.start ?? sourceStart }
    private var editEnd: Double { draft?.end ?? sourceEnd }

    private var startBinding: Binding<Double> {
        Binding(get: { editStart },
                set: { draft = (start: $0, end: editEnd) })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { editEnd },
                set: { draft = (start: editStart, end: $0) })
    }

    private var fightEvents: [FightEventRecord] {
        guard let id = scene?.videoID ?? video?.id else { return [] }
        return store.fightEvents[id] ?? []
    }

    private var loupeFits: Bool {
        sourceEnd - sourceStart < Self.loupeSpan && videoDuration > Self.loupeSpan + 0.5
    }

    var body: some View {
        if let url = model.sourceURL(for: clip), videoDuration > 0 {
            let span = min(Self.loupeSpan, videoDuration)
            VStack(alignment: .leading, spacing: 4) {
                Text(showLoupe ? "Fine trim — 10s window, 0.5s ticks"
                               : "Drag the handles to trim, or extend into the source footage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    if showLoupe {
                        VStack(spacing: 0) {
                            VideoTrimSlider(url: url, duration: span,
                                            start: startBinding, end: endBinding,
                                            pace: pace(start: zoomWindowStart, end: zoomWindowStart + span),
                                            timeOffset: zoomWindowStart,
                                            tickInterval: 0.5, rulerInterval: 0.5,
                                            minimumSpan: 0.5,
                                            showsTimes: false, stripHeight: 56,
                                            onScrub: { pendingScrub = $0 },
                                            onDragEnded: commitDraft)
                            loupeConnector(span: span)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    VideoTrimSlider(url: url, duration: videoDuration,
                                    start: startBinding, end: endBinding,
                                    pace: pace(start: 0, end: videoDuration),
                                    rulerInterval: Self.coarseRulerInterval(videoDuration),
                                    minimumSpan: 0.5,
                                    onScrub: { pendingScrub = $0 },
                                    onDragEnded: commitDraft)
                }
                .clipped()
                if !fightEvents.isEmpty {
                    // Action graph over the committed selection (a little
                    // context on each side): tap to move the preview there.
                    let pad = max(1, (sourceEnd - sourceStart) * 0.25)
                    let lower = max(0, sourceStart - pad)
                    let upper = min(videoDuration, sourceEnd + pad)
                    FightGraphView(events: fightEvents,
                                   range: lower...max(upper, lower + 1),
                                   people: store.people,
                                   height: 56,
                                   showsLegend: false) { time in
                        scrub(to: time)
                    }
                    .overlay(alignment: .top) {
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            let total = max(0.001, upper - lower)
                            let x0 = width * CGFloat((editStart - lower) / total)
                            let x1 = width * CGFloat((editEnd - lower) / total)
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.yellow.opacity(0.8), lineWidth: 1.5)
                                .frame(width: max(2, x1 - x0), height: proxy.size.height)
                                .offset(x: max(0, x0))
                        }
                        .allowsHitTesting(false)
                    }
                    .help("Fight action around this clip — tap to preview that moment")
                }
                HStack {
                    if let scene {
                        Button("Reset to Scene") {
                            model.setClipSourceRange(clip.uid, start: scene.startTime, end: scene.endTime)
                        }
                        .controlSize(.small)
                        .disabled(abs(sourceStart - scene.startTime) < 0.05
                                  && abs(sourceEnd - scene.endTime) < 0.05)
                        .help("Return to the scene's own start and end")
                    }
                    Spacer()
                    Text("\(editStart.timecode) – \(editEnd.timecode) · \(String(format: "%.1fs", (editEnd - editStart) / clip.effectiveSpeed)) on screen")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { settle(animated: false) }
            .onChange(of: clip.uid) { _, _ in
                draft = nil
                settle(animated: false)
            }
            .onChange(of: sourceStart) { _, _ in if draft == nil { settle(animated: true) } }
            .onChange(of: sourceEnd) { _, _ in if draft == nil { settle(animated: true) } }
        }
    }

    /// Release: write the draft to the clip, move the preview to where the
    /// drag ended, then let the loupe and zoom window follow the new range.
    private func commitDraft() {
        if let draft {
            model.setClipSourceRange(clip.uid, start: draft.start, end: draft.end)
        }
        let scrubTarget = pendingScrub
        draft = nil
        pendingScrub = nil
        // The clip's committed range is in the model now; settle from it.
        Task { @MainActor in
            settle(animated: true)
            if let scrubTarget { scrub(to: scrubTarget) }
        }
    }

    /// Bring the loupe visibility and its window in line with the
    /// committed selection.
    private func settle(animated: Bool) {
        let live = model.clip(clip.uid)
        let start = live?.sourceStart ?? sourceStart
        let end = start + (live?.sourceSpan ?? clip.sourceSpan)
        refreshZoomWindow(start: start, end: end, force: !showLoupe)
        let fits = end - start < Self.loupeSpan && videoDuration > Self.loupeSpan + 0.5
        guard fits != showLoupe else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { showLoupe = fits }
        } else {
            showLoupe = fits
        }
    }

    /// Fight-action pace across [start, end] of the source, for the strips'
    /// red sparkline — trim toward the spikes.
    private func pace(start: Double, end: Double) -> [Double] {
        let events = fightEvents
        guard !events.isEmpty else { return [] }
        return FightGraphView.paceCurve(events: events, start: start, end: end,
                                        buckets: max(2, Int((end - start).rounded())))
    }

    /// Keep the loupe (10s of source) around the selection, recentering
    /// only when the selection escapes it so drags stay stable.
    private func refreshZoomWindow(start: Double, end: Double, force: Bool = false) {
        let span = min(Self.loupeSpan, videoDuration)
        let fits = start >= zoomWindowStart && end <= zoomWindowStart + span
        guard force || !fits else { return }
        let mid = (start + end) / 2
        zoomWindowStart = min(max(0, mid - span / 2), max(0, videoDuration - span))
    }

    /// Move the Builder playhead to the timeline moment that shows this
    /// source time, so the preview pane follows the drag.
    private func scrub(to sourceTime: Double) {
        let live = model.clip(clip.uid) ?? clip
        let start = live.sourceStart ?? sourceStart
        let offset = (sourceTime - start) / live.effectiveSpeed
        let time = live.startTime + min(max(0, offset), max(0, live.duration - 0.01))
        model.playhead = BuilderTimelineModel.snap(time)
    }

    private static func coarseRulerInterval(_ duration: Double) -> Double {
        switch duration {
        case ..<20: return 1
        case ..<60: return 2
        case ..<180: return 5
        default: return 10
        }
    }

    /// Loupe funnel between the fine strip and the full-clip strip: the
    /// zoom strip's full width tapers to the window it magnifies below.
    private func loupeConnector(span: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let safeDuration = max(videoDuration, 0.001)
            let x0 = width * CGFloat(min(1, zoomWindowStart / safeDuration))
            let x1 = width * CGFloat(min(1, (zoomWindowStart + span) / safeDuration))
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: height))
                    path.addLine(to: CGPoint(x: x0, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.yellow.opacity(0.22), .yellow.opacity(0.05)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: x0, y: height))
                    path.move(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: x1, y: height))
                }
                .stroke(.yellow.opacity(0.6), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: x0, y: height - 0.5))
                    path.addLine(to: CGPoint(x: x1, y: height - 0.5))
                }
                .stroke(.yellow.opacity(0.8), lineWidth: 1.5)
            }
        }
        .frame(height: 16)
        .allowsHitTesting(false)
        .help("The strip above is a magnified view of this slice of the full clip")
    }
}
