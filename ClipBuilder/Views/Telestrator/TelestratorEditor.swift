import AVFoundation
import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class TelestratorEditor {
    nonisolated enum Tool: String, CaseIterable {
        case select, arrow, oval, line, free, rectangle, cross, stamp

        var kind: Telestration.Figure.Kind? { Telestration.Figure.Kind(rawValue: rawValue) }
        var label: String { kind?.label ?? "Select" }
    }

    var drawing: Telestration
    var tool: Tool = .arrow
    var color: Telestration.Figure.Color = .yellow
    var width: CGFloat = 0.010
    var head = false
    var style: Telestration.Figure.Style = .flat
    var symbol = Telestration.Figure.symbols[0]
    private(set) var selected: Int?
    private(set) var undoDrawing: Telestration?
    private(set) var draft: Telestration.Figure?
    private(set) var image: CGImage?
    private(set) var loadedTime: Double?
    private(set) var frameRate = 30.0
    private(set) var error: String?
    /// What Play or a voice recording is showing; nil when the editor is still.
    nonisolated enum PlayMode: Sendable { case drawing, voice }
    private(set) var playMode: PlayMode?
    private(set) var playPlan: TelestrationPlayback.Plan?
    /// When the clock of `playPlan` started: nil until the picture is ready.
    private(set) var playStarted: Date?
    /// Made the first time a preview needs the picture to move.
    private(set) var player: AVPlayer?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// The whole clip the drawing sits in, when the editor was opened from one.
    let clipRange: ClosedRange<Double>?
    /// False where a drawing is always on a paused picture (the Builder's holds).
    let allowsMotion: Bool
    let range: ClosedRange<Double>?
    let sourceDuration: Double
    let aspect: CGFloat
    let lockTime: Bool
    @ObservationIgnored private var loadRevision = 0
    private var dragOriginal: Telestration?
    @ObservationIgnored private var dragStart: CGPoint?
    @ObservationIgnored private var dragPoints: [CGPoint] = []
    @ObservationIgnored private var controlOriginal: Telestration?

    init(initialTime: Double, duration: Double, aspect: CGFloat, existing: Telestration?,
         range: ClosedRange<Double>? = nil, clipRange: ClosedRange<Double>? = nil, lockTime: Bool = false,
         allowsMotion: Bool = true) {
        self.allowsMotion = allowsMotion
        self.range = range
        self.clipRange = clipRange
        self.lockTime = lockTime
        sourceDuration = duration
        self.aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        drawing = existing ?? Telestration(time: initialTime)
        if !allowsMotion { drawing.motion = nil }
        // A saved drawing keeps its moment: the frame rate is not known yet,
        // and clamping to an assumed 30 fps would move one near the file's end.
        // It is still held to the row it was opened from.
        if lockTime {
            drawing.time = initialTime
        } else if existing == nil || !drawing.time.isFinite {
            drawing.time = boundedTime(drawing.time)
        } else if let range {
            drawing.time = min(range.upperBound, max(range.lowerBound, drawing.time))
        }
    }

    var atLimit: Bool { drawing.figures.count >= Telestration.maximumFigures }
    var isDragging: Bool { dragOriginal != nil }
    var ready: Bool { image != nil && loadedTime == drawing.time }
    var selectedKind: Telestration.Figure.Kind? {
        guard let selected, drawing.figures.indices.contains(selected) else { return nil }
        return drawing.figures[selected].kind
    }
    var canSetHead: Bool { selectedKind == .free || tool == .free }
    var showsSymbols: Bool { selectedKind == .stamp || tool == .stamp }
    var firstFrameTime: Double { max(0, range?.lowerBound ?? 0) }
    var lastFrameTime: Double {
        max(firstFrameTime, min(range?.upperBound ?? sourceDuration,
            TelestrationRules.sourceTime(.greatestFiniteMagnitude, duration: sourceDuration, frameRate: frameRate)))
    }

    private func boundedTime(_ time: Double) -> Double {
        min(lastFrameTime, max(firstFrameTime, time.isFinite ? time : firstFrameTime))
    }

    func load(url: URL) async {
        loadRevision += 1
        let revision = loadRevision, time = drawing.time
        error = nil
        stopPlayback()
        do {
            let frame = try await TelestratorFrameLoader.load(url: url, time: time, duration: sourceDuration,
                                                            range: range, lockTime: lockTime)
            guard !Task.isCancelled, revision == loadRevision, drawing.time == time else { return }
            frameRate = frame.frameRate
            image = frame.image
            loadedTime = frame.time
            drawing.time = lockTime ? time : boundedTime(frame.time)
        } catch {
            guard !Task.isCancelled, revision == loadRevision, drawing.time == time else { return }
            image = nil
            loadedTime = nil
            self.error = "Could not load the frame: \(error.localizedDescription)"
            ErrorLog.record("Telestrator", error.localizedDescription)
        }
    }

    func select(_ index: Int?) {
        selected = index
        tool = .select
        if let index, drawing.figures.indices.contains(index) {
            color = drawing.figures[index].color
            width = drawing.figures[index].width
            head = drawing.figures[index].head ?? false
            style = drawing.figures[index].style ?? .flat
            symbol = drawing.figures[index].symbol ?? Telestration.Figure.symbols[0]
        }
    }

    func setColor(_ value: Telestration.Figure.Color) {
        color = value
        guard let selected, drawing.figures.indices.contains(selected), drawing.figures[selected].color != value else { return }
        remember()
        drawing.figures[selected].color = value
    }

    func setWidth(_ value: CGFloat) {
        width = value
        guard let selected, drawing.figures.indices.contains(selected), drawing.figures[selected].width != value else { return }
        remember()
        drawing.figures[selected].width = value
    }

    func setHead(_ value: Bool) {
        head = value
        guard let selected, selectedKind == .free, (drawing.figures[selected].head ?? false) != value else { return }
        remember()
        drawing.figures[selected].head = value
    }

    func setStyle(_ value: Telestration.Figure.Style) {
        style = value
        guard let selected, drawing.figures.indices.contains(selected),
              (drawing.figures[selected].style ?? .flat) != value else { return }
        remember()
        drawing.figures[selected].style = value
    }

    func setSymbol(_ value: String) {
        guard Telestration.Figure.symbols.contains(value) else { return }
        symbol = value
        guard let selected, selectedKind == .stamp, drawing.figures[selected].symbol != value else { return }
        remember()
        drawing.figures[selected].symbol = value
    }

    var selectedLinger: Double {
        guard let selected, drawing.figures.indices.contains(selected) else { return 0 }
        return drawing.figures[selected].linger ?? 0
    }

    func setLinger(_ value: Double) {
        guard let selected, drawing.figures.indices.contains(selected) else { return }
        let linger = value.isFinite ? min(3, max(0, value)) : 0
        guard selectedLinger != linger else { return }
        remember()
        drawing.figures[selected].linger = linger > 0 ? linger : nil
    }

    var playbackDuration: Double { drawing.duration + TelestrationRules.lingerDuration(of: drawing) }

    // MARK: Picture speed

    /// The last source second the picture may reach under this drawing.
    var footageEnd: Double { min(clipRange?.upperBound ?? sourceDuration, sourceDuration) }
    /// Source seconds left after the drawing's moment for a moving picture.
    var footageRoom: Double { TelestrationPlayback.room(after: drawing.time, end: footageEnd) }
    /// False when the chosen speed needs more footage than the clip has left:
    /// the picture then pauses instead, here and in the reel.
    var motionFits: Bool { drawing.motion == nil || drawing.sourceSpan <= footageRoom + 1e-9 }

    func setMotion(_ value: Double?) {
        let motion = allowsMotion ? Telestration(motion: value).motion : nil
        guard drawing.motion != motion else { return }
        remember()
        drawing.motion = motion
    }

    // MARK: Playback

    var isPlaying: Bool { playMode != nil }

    /// Where the picture and the animation are at `date`; nil when still.
    func moment(at date: Date) -> TelestrationPlayback.Moment? {
        guard let playPlan, let playStarted else { return nil }
        return playPlan.moment(at: date.timeIntervalSince(playStarted))
    }

    /// Plays the drawing (`.drawing`) or the whole clip with the drawing in
    /// it (`.voice`), in real time. `ready` runs once the picture is in
    /// place, just before the clock starts; false gives up. `ended` runs when
    /// playback reaches its end by itself.
    func play(url: URL, mode: PlayMode, ready prepared: (@MainActor () async -> Bool)? = nil,
              ended: (@MainActor () -> Void)? = nil) {
        stopPlayback()
        guard ready, !isDragging else { return }
        let plan = mode == .voice
            ? TelestrationPlayback.recording(drawing, range: clipRange ?? drawing.time...max(drawing.time, footageEnd))
            : TelestrationPlayback.preview(drawing, end: footageEnd)
        playMode = mode
        playPlan = plan
        playTask = Task { [weak self] in
            guard let self else { return }
            var moving: AVPlayer?
            if plan.movesPicture {
                let player = self.player ?? AVPlayer(url: url)
                self.player = player
                player.pause()
                // A recording must not hear the speakers.
                player.volume = mode == .voice ? 0 : 1
                _ = await player.seek(to: CMTime(seconds: plan.start, preferredTimescale: 60000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                moving = player
            }
            guard !Task.isCancelled else { return }
            if let prepared, !(await prepared()) {
                if !Task.isCancelled { self.stopPlayback() }
                return
            }
            guard !Task.isCancelled else { return }
            let started = Date.now
            self.playStarted = started
            Self.apply(plan.moment(at: 0), to: moving)
            for boundary in plan.boundaries + [plan.total] {
                let wait = boundary - Date.now.timeIntervalSince(started)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                if boundary < plan.total || plan.waits { Self.apply(plan.moment(at: boundary), to: moving) }
            }
            // A recording waits on the drawing until it is stopped.
            if plan.waits { return }
            self.playTask = nil
            self.stopPlayback()
            ended?()
        }
    }

    /// Stops a voice recording's playback and makes the drawing stay for as
    /// long as the recording ran past it, so the reel pauses for the voice.
    func stopRecordingPlayback() {
        let longer: Double? = {
            guard playMode == .voice, let playPlan, let playStarted else { return nil }
            return TelestrationPlayback.stay(of: drawing, covering: Date.now.timeIntervalSince(playStarted), in: playPlan)
        }()
        stopPlayback()
        guard let longer else { return }
        remember()
        drawing.stay = longer
    }

    private static func apply(_ moment: TelestrationPlayback.Moment, to player: AVPlayer?) {
        guard let player else { return }
        if moment.rate > 0 { player.playImmediately(atRate: Float(moment.rate)) } else { player.pause() }
    }

    func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        player?.pause()
        playStarted = nil
        playPlan = nil
        playMode = nil
    }

    func remember() { undoDrawing = controlOriginal ?? drawing; stopPlayback() }

    func setTime(_ time: Double) {
        guard !lockTime else { return }
        let target = boundedTime(time)
        guard target != drawing.time else { return }
        remember()
        drawing.time = target
    }

    func step(_ count: Int) { setTime(drawing.time + Double(count) / frameRate) }

    func controlEditing(_ editing: Bool) {
        if editing { controlOriginal = drawing; stopPlayback() }
        else if let original = controlOriginal {
            if original != drawing { undoDrawing = original }
            controlOriginal = nil
        }
    }

    func beginDrag(at point: CGPoint) {
        guard ready, !isPlaying, !isDragging else { return }
        if tool == .select { select(TelestrationRules.figure(at: point, in: drawing.figures, aspect: aspect)) }
        else if atLimit { return }
        dragOriginal = drawing
        dragStart = point
        dragPoints = [point]
    }

    func updateDrag(to point: CGPoint) {
        guard let original = dragOriginal, let start = dragStart else { return }
        if tool == .select {
            if let selected, original.figures.indices.contains(selected) {
                drawing.figures[selected] = TelestrationRules.moved(original.figures[selected],
                    by: TelestrationRules.translation(from: start, to: point))
            }
        } else if let kind = tool.kind {
            if kind == .free {
                if let last = dragPoints.last, TelestrationRules.distance(last, point, aspect: aspect) >= 0.001 {
                    dragPoints.append(point)
                    // Bound live gesture work as well as the stored path.
                    if dragPoints.count > 400 { dragPoints = TelestrationRules.simplify(dragPoints) }
                }
            } else {
                let end = kind == .stamp ? TelestrationRules.squareEnd(from: start, to: point, aspect: aspect) : point
                dragPoints = [start, end]
            }
            draft = Telestration.Figure(kind: kind, points: dragPoints, color: color, width: width,
                head: kind == .free && head ? true : nil, style: style == .flat ? nil : style,
                symbol: kind == .stamp ? symbol : nil)
        }
    }

    func endDrag(at point: CGPoint) {
        updateDrag(to: point)
        guard let original = dragOriginal else { return }
        if var draft, !atLimit {
            if draft.kind == .free {
                // The endpoint is kept even if the last mouse update was tiny.
                draft.points = TelestrationRules.simplify(dragPoints + [point])
            }
            if zip(draft.points, draft.points.dropFirst()).contains(where: {
                TelestrationRules.distance($0.0, $0.1, aspect: self.aspect) > 0.002
            }) {
                drawing.figures.append(draft)
                selected = drawing.figures.count - 1
            }
        }
        if original != drawing { undoDrawing = original }
        resetDrag()
    }

    func cancelDrag() {
        if let original = dragOriginal { drawing = original }
        resetDrag()
    }

    private func resetDrag() { dragOriginal = nil; dragStart = nil; dragPoints = []; draft = nil }

    func deleteSelected() {
        guard !isDragging, let selected, drawing.figures.indices.contains(selected) else { return }
        remember()
        drawing.figures.remove(at: selected)
        self.selected = nil
    }

    func clear() { remember(); drawing.figures = []; selected = nil }

    func undo() {
        guard let undoDrawing else { return }
        drawing = undoDrawing
        self.undoDrawing = nil
        selected = nil
        stopPlayback()
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard drawing.figures.indices.contains(index), drawing.figures.indices.contains(target) else { return }
        remember()
        drawing.figures.swapAt(index, target)
        if selected == index { selected = target }
        else if selected == target { selected = index }
    }

    func togglePlay(url: URL) {
        if isPlaying { stopPlayback() } else { play(url: url, mode: .drawing) }
    }
}
