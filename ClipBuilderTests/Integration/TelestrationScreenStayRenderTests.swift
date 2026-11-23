import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Screen-fixed stay rendering", .enabled(if: FixtureVideo.integrationsAvailable))
struct TelestrationScreenStayRenderTests {
    private nonisolated struct Probe: Sendable {
        var yellow: CGRect?
        var redX: Double
    }

    @concurrent
    private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=1280x720:r=30:d=7",
            "-f", "lavfi", "-i", "color=c=red:s=80x160:r=30:d=7",
            "-filter_complex", "[0:v][1:v]overlay=x='500+40*t':y=340[v]",
            "-map", "[v]", "-an", "-t", "7", "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", url.path], timeout: 60)
    }

    @concurrent
    private func probe(_ url: URL, time: Double, folder: URL, area: Int? = nil) async throws -> Probe {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: output) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-frames:v", "1", "-vf", (area.map { "crop=640:360:0:\($0 * 360)," } ?? "") + "format=rgb24", "-f", "rawvideo", output.path], timeout: 60)
        let bytes = [UInt8](try Data(contentsOf: output))
        #expect(bytes.count == 640 * 360 * 3)
        guard bytes.count == 640 * 360 * 3 else { return Probe(yellow: nil, redX: -1) }
        var left = 640, right = -1, top = 360, bottom = -1
        var redSum = 0, redCount = 0
        for y in 0..<360 {
            for x in 0..<640 {
                let i = (y * 640 + x) * 3
                if bytes[i] > 190 && bytes[i + 1] > 190 && bytes[i + 2] < 80 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
                if y == 220 && bytes[i] > 170 && bytes[i + 1] < 70 && bytes[i + 2] < 70 {
                    redSum += x; redCount += 1
                }
            }
        }
        let box = right >= left ? CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1) : nil
        return Probe(yellow: box, redX: redCount == 0 ? -1 : Double(redSum) / Double(redCount))
    }

    private func document(source: URL, speed: Double, prepass: Bool, linger: Double?) -> TimelineDocument {
        let drawing = Telestration(time: 1, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.35, y: 0.35), CGPoint(x: 0.55, y: 0.35)],
            color: .yellow, width: 0.016, linger: linger)], stay: 0.5, drawSpeed: 0.5, fade: 0.2)
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: drawing.duration)
        hold.videoFile = source.path
        hold.wide = true
        hold.captions = "none"
        hold.hold = true
        hold.telestration = drawing
        hold.cameraPath = [.init(t: 0, x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                           .init(t: drawing.duration, x: 0.25, y: 0.25, w: 0.5, h: 0.5)]
        var tail = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 1.6, startTime: drawing.duration)
        tail.videoFile = source.path
        tail.wide = true
        tail.captions = "none"
        tail.speed = speed
        tail.sourceEnd = 1 + tail.duration * speed
        tail.cameraPath = [.init(t: 0, x: 0.25, y: 0.25, w: 0.5, h: 0.5),
                           .init(t: tail.duration * speed, x: 0.45, y: 0.3, w: 0.4, h: 0.4)]
        var document = Fixtures.timelineDocument(clips: [hold, tail])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        // Exercise both an implicit canvas and explicit full-screen rows.
        // Paused stored paths retain their source clock on the fused route.
        document.cropBlocks = prepass ? [] : [
            .init(layout: .fullScreen, startTime: 0, duration: drawing.duration + 0.3),
            .init(layout: .fullScreen, startTime: drawing.duration + 0.3, duration: 1.3)]
        return document
    }

    private nonisolated static func stayPath(duration: Double) -> FeedCameraPath {
        let path: [CameraPathKeyframe] = [.init(t: 0, x: 0.25, y: 0.25, w: 0.5, h: 0.5),
            .init(t: duration, x: 0.45, y: 0.3, w: 0.4, h: 0.4)]
        return FeedCameraPath(keyframes: path, samples: [], trackedShare: 1,
            sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
    }

    @Test("Each tracked layout picture keeps its stay through another contact hold")
    func layoutAndCompanionStayAcrossContact() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("two-stays.mp4")
        try await source(input)
        let original = document(source: input, speed: 1, prepass: true, linger: 1.2)
        var doc = CenterStageContinuityRenderTests.twoAreas(input: input)
        let plan = doc.videoTrack[0].framingPlan
        let tracks = (0..<2).map { track in
            original.videoTrack.map { item in
                var item = item
                item.uid = UUID()
                item.track = track
                item.sourceStart = (item.sourceStart ?? 0) + Double(track * 2)
                item.sourceEnd = (item.sourceEnd ?? 0) + Double(track * 2)
                item.framingPlan = plan
                return item
            }
        }
        let resume = original.videoTrack[0].duration
        let pieces = try #require(StrikeFreezeRules.sharedPieces(tracks,
            pauses: [.init(time: resume + 0.3, duration: 0.6)]))  // at least minimumPiece after the resume
        doc.videoTrack = pieces.flatMap { $0 }.map { item in
            var item = item
            item.cameraPath = nil
            return item
        }
        let messages = Mutex<[String]>([])
        let output = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, duration in
            Self.stayPath(duration: duration)
        }) {
            try await renderer(folder: folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in messages.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let fellBack = messages.withLock { $0.contains(TelestrationScreenStay.fallbackMessage) }
        #expect(!fellBack)
        for area in 0..<2 {
            let held = try await probe(output.url, time: resume - 1.0 / 30, folder: folder, area: area)
            for time in [resume, resume + 0.3, resume + 0.7, resume + 1.0] {
                let later = try await probe(output.url, time: time, folder: folder, area: area)
                sameBounds(try #require(held.yellow), try #require(later.yellow))
            }
            let gone = try await probe(output.url, time: resume + 1.9, folder: folder, area: area)
            #expect(gone.yellow == nil)
        }
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: resume + 0.4, to: resume + 1.4)
        let preview = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, duration in
            Self.stayPath(duration: duration)
        }) {
            try await renderer(folder: folder).render(document: window.document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, lingering: window.lingering, lingerHolds: window.lingerHolds,
                continuity: window.continuity, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: preview.url) }
        for area in 0..<2 {
            let full = try await probe(output.url, time: resume + 0.6, folder: folder, area: area)
            let part = try await probe(preview.url, time: 0.2, folder: folder, area: area)
            sameBounds(try #require(full.yellow), try #require(part.yellow))
        }
    }

    /// Segment graphs are passed as a file; read it while it still exists.
    private nonisolated static func inlined(_ command: [String]) -> [String] {
        guard let index = command.firstIndex(of: "-/filter_complex"), index + 1 < command.count,
              let graph = try? String(contentsOfFile: command[index + 1], encoding: .utf8) else { return command }
        return command + ["-filter_complex", graph]
    }

    private func renderer(folder: URL) -> MultitrackRenderer {
        MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent(UUID().uuidString)),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
    }

    private func sameBounds(_ a: CGRect, _ b: CGRect) {
        #expect(abs(a.minX - b.minX) <= 2)
        #expect(abs(a.maxX - b.maxX) <= 2)
        #expect(abs(a.minY - b.minY) <= 2)
        #expect(abs(a.maxY - b.maxY) <= 2)
    }

    @Test("Last pause, first motion and later motion keep the same figure while the camera pans and zooms",
          arguments: [1.0, 0.5, 2.0], [false, true])
    func cameraMotion(speed: Double, prepass: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        let document = document(source: input, speed: speed, prepass: prepass, linger: 1.2)
        let resume = document.videoTrack[0].duration
        let commands = Mutex<[[String]]>([])
        let rendered = try await FFmpeg.$commandCompleted.withValue({ command in commands.withLock { $0.append(Self.inlined(command)) } }) {
            try await renderer(folder: folder).render(document: document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        let held = try await probe(rendered.url, time: resume - 1.0 / 30, folder: folder)
        let first = try await probe(rendered.url, time: resume, folder: folder)
        let later = try await probe(rendered.url, time: resume + 0.5, folder: folder)
        sameBounds(try #require(held.yellow), try #require(first.yellow))
        sameBounds(try #require(held.yellow), try #require(later.yellow))
        #expect(first.redX > 0 && later.redX > 0 && abs(first.redX - later.redX) > 15)
        #expect(try await probe(rendered.url, time: resume + 1.4, folder: folder).yellow == nil)
        let captured = commands.withLock { $0 }
        #expect(!captured.contains { $0.last?.hasSuffix("burned.mov") == true && $0.contains("[drawing]") })
        let graphs = captured.compactMap { command -> String? in
            guard let index = command.firstIndex(of: "-filter_complex"), index + 1 < command.count else { return nil }
            return command[index + 1]
        }
        let stayGraphs = graphs.filter { $0.contains("[v0_before_stay]") }
        #expect(!stayGraphs.isEmpty)
        for graph in stayGraphs {
            let steps = graph.split(separator: ";").map(String.init)
            let framedIndex = steps.firstIndex { $0.hasSuffix("[v0_before_stay]") }
            let drawingIndex = steps.firstIndex { $0.hasPrefix("[v0_before_stay]setpts=") }
            let overlayIndex = steps.firstIndex { $0.hasPrefix("[v0_b0][v0_m0]overlay=") }
            let framed = try #require(framedIndex)
            let drawing = try #require(drawingIndex)
            let overlay = try #require(overlayIndex)
            #expect(framed < drawing && drawing < overlay)
            // A crop in this graph must produce the picture consumed by
            // the stay, never crop an already drawn figure.
            // A run's pieces are framed by scale (eval=frame) then an exact crop.
            for crop in steps.indices where steps[crop].contains("crop@area") || steps[crop].contains("exact=1") {
                #expect(crop <= framed)
            }
        }
        #expect(stayGraphs.contains { $0.contains("crop@area") || $0.contains("exact=1") })
        let window = MultitrackRenderer.windowed(document, scenes: [], from: resume + 0.2, to: resume + 1.5)
        let preview = try await renderer(folder: folder).render(document: window.document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, lingering: window.lingering, lingerHolds: window.lingerHolds, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        let previewFigure = try await probe(preview.url, time: 0.3, folder: folder)
        sameBounds(try #require(held.yellow), try #require(previewFigure.yellow))
        #expect(try await probe(preview.url, time: 1.1, folder: folder).yellow == nil)
    }

    @Test("Without a stay the existing moving graph and decoded picture are unchanged")
    func noStay() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        var graphs: [[String]] = []
        var probes: [Probe] = []
        for linger in [Double?.none, Double?.some(0)] {
            let document = document(source: input, speed: 1, prepass: false, linger: linger)
            let commands = Mutex<[[String]]>([])
            let output = try await FFmpeg.$commandCompleted.withValue({ command in commands.withLock { $0.append(Self.inlined(command)) } }) {
                try await renderer(folder: folder).render(document: document, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
            }
            defer { try? FileManager.default.removeItem(at: output.url) }
            probes.append(try await probe(output.url, time: document.videoTrack[0].duration + 0.5, folder: folder))
            let movingGraphs = commands.withLock { $0 }.compactMap { command -> String? in
                guard let index = command.firstIndex(of: "-filter_complex"), index + 1 < command.count else { return nil }
                let graph = command[index + 1]
                // Moving pieces: the unpaused route (sendcmd) or a run's piece
                // (scale with eval=frame); the drawn hold's own graph is not one.
                let moving = graph.contains("sendcmd") || (graph.contains("eval=frame") && !graph.contains("drawing"))
                return moving ? graph : nil
            }
            #expect(!movingGraphs.isEmpty)
            #expect(movingGraphs.allSatisfy { !$0.contains("before_stay") && !$0.contains("drawing") })
            graphs.append(movingGraphs.sorted())
        }
        #expect(graphs[0] == graphs[1])
        #expect(probes.allSatisfy { $0.yellow == nil })
        #expect(probes[0].redX > 0 && abs(probes[0].redX - probes[1].redX) <= 2)
    }

    @Test("An unsupported hold falls back to a source burn while tracking the clean picture")
    func fallbackTracksCleanSource() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("moving.mp4")
        try await source(input)
        var document = document(source: input, speed: 1, prepass: true, linger: 1.2)
        document.videoTrack[0].framingPlan = .static(window: .init(), fit: .blurredFill, feather: 0, blur: 0)
        document.videoTrack[1].cameraPath = nil
        document.videoTrack[1].centerStage = true
        let tracked = Mutex<[(URL, Double)]>([])
        let commands = Mutex<[[String]]>([])
        let logs = Mutex<[String]>([])
        let output = try await CenterStageService.$trackingInputObserver.withValue({ source, start, _ in
            tracked.withLock { $0.append((source, start)) }
        }) {
            try await FFmpeg.$commandCompleted.withValue({ command in commands.withLock { $0.append(Self.inlined(command)) } }) {
                try await renderer(folder: folder).render(document: document, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, centerStageCamera: "steady", preview: true,
                    emit: { line in logs.withLock { $0.append(line) } })
            }
        }
        defer { try? FileManager.default.removeItem(at: output.url) }
        let inputs = tracked.withLock { $0 }
        #expect(inputs.count == 1)
        #expect(inputs.first?.0 == input && inputs.first?.1 == 1)
        #expect(logs.withLock { $0.contains(TelestrationScreenStay.fallbackMessage) })
        let burns = commands.withLock { $0.filter { $0.contains("[drawing]") && $0.last?.hasSuffix("burned.mov") == true } }
        #expect(burns.count == 1)
        let burn = try #require(burns.first)
        let sourceIndex = try #require(burn.firstIndex(of: "-i")) + 1
        #expect(burn[sourceIndex] == input.path)
        #expect(inputs.first?.0.path != burn.last)
    }
}
