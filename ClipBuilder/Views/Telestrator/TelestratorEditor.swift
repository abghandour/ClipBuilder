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
    var playStarted: Date?
    let sourceDuration: Double
    let aspect: CGFloat
    @ObservationIgnored private var loadRevision = 0
    private var dragOriginal: Telestration?
    @ObservationIgnored private var dragStart: CGPoint?
    @ObservationIgnored private var dragPoints: [CGPoint] = []
    @ObservationIgnored private var controlOriginal: Telestration?

    init(initialTime: Double, duration: Double, aspect: CGFloat, existing: Telestration?) {
        sourceDuration = duration
        self.aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        drawing = existing ?? Telestration(time: initialTime)
        drawing.time = TelestrationRules.sourceTime(drawing.time, duration: duration)
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
    var lastFrameTime: Double { TelestrationRules.sourceTime(.greatestFiniteMagnitude, duration: sourceDuration, frameRate: frameRate) }

    func load(url: URL) async {
        loadRevision += 1
        let revision = loadRevision, time = drawing.time
        error = nil
        playStarted = nil
        do {
            let frame = try await TelestratorFrameLoader.load(url: url, time: time, duration: sourceDuration)
            guard !Task.isCancelled, revision == loadRevision, drawing.time == time else { return }
            frameRate = frame.frameRate
            image = frame.image
            loadedTime = frame.time
            drawing.time = frame.time
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

    func remember() { undoDrawing = controlOriginal ?? drawing; playStarted = nil }

    func setTime(_ time: Double) {
        let target = TelestrationRules.sourceTime(time, duration: sourceDuration, frameRate: frameRate)
        guard target != drawing.time else { return }
        remember()
        drawing.time = target
    }

    func step(_ count: Int) { setTime(drawing.time + Double(count) / frameRate) }

    func controlEditing(_ editing: Bool) {
        if editing { controlOriginal = drawing; playStarted = nil }
        else if let original = controlOriginal {
            if original != drawing { undoDrawing = original }
            controlOriginal = nil
        }
    }

    func beginDrag(at point: CGPoint) {
        guard ready, playStarted == nil, !isDragging else { return }
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
        playStarted = nil
    }

    func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard drawing.figures.indices.contains(index), drawing.figures.indices.contains(target) else { return }
        remember()
        drawing.figures.swapAt(index, target)
        if selected == index { selected = target }
        else if selected == target { selected = index }
    }

    func togglePlay() { playStarted = playStarted == nil ? .now : nil }
}
