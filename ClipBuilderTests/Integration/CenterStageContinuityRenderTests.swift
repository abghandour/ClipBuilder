import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Continuous camera rendering", .enabled(if: FixtureVideo.integrationsAvailable))
struct CenterStageContinuityRenderTests {
    @Test(arguments: [1, 2], ["contact", "drawn", "both"])
    func sameFileCompanionCropsCannotBorrowAnotherPicturesClock(companions: Int, kind: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("companions.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=1280x720:r=30:d=8",
            "-vf", "drawbox=x=500:y=300:w=80:h=100:color=red:t=fill",
            "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", input.path], timeout: 60)
        let doc = try CenterStageContinuityTests.sameFileCompanions(path: input.path, companions: companions, kind: kind)
        let starts = Mutex<[Double]>([])
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, start, duration in
            starts.withLock { $0.append(start) }
            let x = 0.1 + start / 30
            return FeedCameraPath(keyframes: [0, duration].map { .init(t: $0, x: x, y: 0.1, w: 0.5, h: 0.5) },
                samples: [], trackedShare: 1, sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
        }) {
            try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let analyzed = starts.withLock { $0.sorted() }
        #expect(analyzed.count == companions + 1)
        for (index, value) in analyzed.enumerated() { #expect(abs(value - Double(index * 3)) < 1e-9) }
        let holds = doc.videoTrack.filter { $0.track == 0 && $0.hold == true }
        #expect(holds.count == (kind == "both" ? 2 : 1))
        for hold in holds {
            for time in [hold.startTime - 1.0 / 30, hold.startTime + hold.duration / 2, hold.startTime + hold.duration] {
                let measured = try await markerMoments(result.url, at: time, rows: (companions + 1) * 360, folder: folder)
                #expect(measured.count == companions + 1)
                for (track, moment) in measured.enumerated() {
                    let cropX = 0.1 + Double(track) / 10
                    let expectedX = (539.5 / 1280 - cropX) * 1280
                    #expect(abs(moment.x - expectedX) <= 1)
                }
            }
        }
    }

    @Test("The graph evaluates the affine camera at every source frame")
    func transformGraphMatchesIndependentAffineCrops() async throws {
        let folder = try TempDirectory()
        let input = folder.url.appendingPathComponent("affine.mp4")
        try await source(input)
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                    .init(t: 2, x: 0.25, y: 0.25, w: 0.4, h: 0.4)]
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let graph = RenderContext.$settings.withValue(RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)) {
            AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1280, height: 720),
                area: area, transformInterpolation: true)
        }
        let dynamic = folder.url.appendingPathComponent("dynamic.rgb")
        try await FFmpeg.run(["-y", "-i", input.path, "-vf", graph, "-frames:v", "60",
            "-pix_fmt", "rgb24", "-f", "rawvideo", dynamic.path], timeout: 60)
        let actual = try Data(contentsOf: dynamic)
        let size = 640 * 360 * 3
        try #require(actual.count == 60 * size)
        for frame in 0..<60 {
            let time = Double(frame) / 30
            // Independent matrix ramp: scale 0.625 -> 1.25; translations
            // (-80,-45) -> (-400,-225), on the half-output-pixel crop grid.
            let scale = 0.625 + 0.625 * time / 2
            let tx = 80 + 320 * time / 2, ty = 45 + 180 * time / 2
            let width = Int((2560 * scale).rounded()), height = Int((1440 * scale).rounded())
            let fixed = "format=yuv444p,scale=\(width):\(height),"
                + "crop=1280:720:\(2 * tx):\(2 * ty):exact=1,scale=640:360,setsar=1,format=yuv420p"
            let output = folder.url.appendingPathComponent("fixed.rgb")
            try await FFmpeg.run(["-y", "-ss", ContinuityFrameSelection.seek(time), "-i", input.path,
                "-vf", fixed, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", output.path], timeout: 60)
            let expected = try Data(contentsOf: output)
            let decoded = actual.subdata(in: (frame * size)..<((frame + 1) * size))
            #expect(decoded == expected, "affine crop at frame \(frame)")
        }
    }

    @Test("A five-percent crop uses bounded crop-first framing")
    func narrowCameraHasNoWholePictureUpscale() async throws {
        let folder = try TempDirectory()
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        // Portrait output from a 16:9 picture, with a moving affine zoom.
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: 0.08, h: 0.08 * 256 / 81),
                    .init(t: 1, x: 0.2, y: 0.2, w: 0.05, h: 0.05 * 256 / 81)]
        let graph = RenderContext.$settings.withValue(RenderSettings(preset: .custom, customWidth: 1080, customHeight: 1920)) {
            AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 3840, height: 2160),
                area: area, transformInterpolation: true)
        }
        #expect(graph.hasPrefix("sendcmd="))
        #expect(graph.contains("crop@area="))
        #expect(graph.contains("scale=1080:1920"))
        #expect(!graph.contains("eval=frame"), "No whole-picture scale intermediate")
        #expect(!graph.contains("fps="), "The segment owns sampling")
        let output = folder.url.appendingPathComponent("narrow.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "testsrc2=s=3840x2160:r=30:d=1",
            "-vf", graph, "-frames:v", "30", "-c:v", "libx264", "-preset", "ultrafast", output.path], timeout: 60)
        let dimensions = await FFmpeg.dimensions(of: output)
        #expect(dimensions.width == 1080)
        #expect(dimensions.height == 1920)
        let duration = await FFmpeg.duration(of: output)
        #expect(abs(duration - 1) < 1.0 / 30)
    }

    @Test("Paused zoom keeps the unsplit movie's subject position and scale",
           arguments: ["area", "full", "region", "stored"], [false, true])
    func pausedAndUnpausedZoomUseTheSameMovieCamera(route: String, drawnHold: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("zoom.mp4")
        try await source(input)
        var plain = Self.twoAreas(input: input)
        if route.hasPrefix("full") {
            plain.videoTrack = [plain.videoTrack[0]]
            plain.videoTrack[0].centerStage = true
            plain.videoTrack[0].wide = true
            plain.videoTrack[0].framingPlan = nil
            plain.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        }
        let path: [CameraPathKeyframe] = route == "stored"
            ? [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
               .init(t: 1.4, x: 0.2, y: 0.2, w: 0.5, h: 0.5),
               .init(t: 1.59, x: 0.2, y: 0.2, w: 0.5, h: 0.5),
               .init(t: 1.6, x: 0.25, y: 0.25, w: 0.45, h: 0.45),
               .init(t: 2, x: 0.25, y: 0.25, w: 0.4, h: 0.4)]
            : [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
               .init(t: 2, x: 0.25, y: 0.25, w: 0.4, h: 0.4)]
        if route == "stored" {
            for index in plain.videoTrack.indices { plain.videoTrack[index].cameraPath = path }
        }
        let pieces = try #require(StrikeFreezeRules.sharedPieces(WizardSharedPauses.tracks(plain),
            pauses: [.init(time: 1, duration: 0.8)]))
        var paused = plain
        paused.videoTrack = pieces.flatMap { $0 }
        if drawnHold, let index = paused.videoTrack.firstIndex(where: { $0.hold == true && $0.track == 0 }) {
            paused.videoTrack[index].telestration = Telestration(time: 1, figures: [.init(kind: .line,
                points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.3)],
                color: .yellow, width: 0.01, linger: 0)], stay: 0.3, drawSpeed: 0.2, fade: 0.1)
        }
        if route == "region" {
            for index in paused.videoTrack.indices { paused.videoTrack[index].areaRegion = FreeCropRect() }
        }
        let renderer = StayRenderFixture.renderer(folder)
        let reference: MultitrackRenderer.RenderResult
        if route == "stored" {
            reference = try await renderer.render(document: plain, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        } else {
            reference = try await CenterStageService.$trackingPathOverride.withValue({ _, _, _ in path }) {
                try await renderer.render(document: plain, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
            }
        }
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let candidate = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            #expect(route != "stored")
            return FeedCameraPath(keyframes: path, samples: [], trackedShare: 1,
                sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
        }) {
            try await renderer.render(document: paused, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: candidate.url) }
        let areas = route == "full" ? 1 : 2
        let expected = try await markerMoments(reference.url, at: 0, rows: areas * 360, folder: folder, frames: 60)
        let actual = try await markerMoments(candidate.url, at: 0, rows: areas * 360, folder: folder, frames: 84)
        // Every frame, including the entire hold.
        var drift = [Double](repeating: 0, count: areas)
        var absoluteDrift = [Double](repeating: 0, count: areas)
        for output in 0..<84 {
            for area in 0..<areas {
                let b = actual[output * areas + area]
                let source = try #require(b.frame)
                let match = try #require((0..<60).first { expected[$0 * areas + area].frame == source })
                let a = expected[match * areas + area]
                #expect(abs(a.x - b.x) <= 1)
                #expect(abs(a.y - b.y) <= 1)
                // The reference's own size departs from its smooth zoom by up to
                // 0.7% from one frame to the next (measured 2026-11-22; the
                // candidate's is smooth), so a single frame is held to 1% and
                // the size over the whole clip to 0.5%.
                #expect(abs(b.scale / a.scale - 1) <= 0.01, "source frame \(source), output frame \(output)")
                drift[area] += (b.scale / a.scale - 1) / 84
                absoluteDrift[area] += abs(b.scale / a.scale - 1) / 84
            }
        }
        for area in 0..<areas {
            #expect(abs(drift[area]) <= 0.005, "mean size error, area \(area)")
            #expect(absoluteDrift[area] <= 0.005, "mean absolute size error, area \(area)")
        }
    }

    @Test("An implicit saved zoom keeps cut pacing and continuous pause boundaries")
    func implicitSavedZoomMatchesOrdinaryCut() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("implicit-saved.mp4")
        try await source(input)
        var plain = CenterStageContinuityTests.document()
        plain.videoTrack = [plain.videoTrack[0]]
        plain.videoTrack[0].videoFile = input.path
        plain.videoTrack[0].duration = 4
        plain.videoTrack[0].sourceEnd = (plain.videoTrack[0].sourceStart ?? 0) + 4
        plain.videoTrack[0].cameraPath = [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                                        .init(t: 4, x: 0.2, y: 0.2, w: 0.4, h: 0.4)]
        let inserted = try #require(TimelinePauseRules.insert([
            .init(time: 2, duration: 0.8, owner: plain.videoTrack[0].uid)
        ], into: plain, resolve: { $0 }))
        let group = try #require(inserted.document.videoTrack.first(where: { $0.hold == true })?.pauseGroup)
        let cut = try #require(TimelinePauseRules.removed(group: group, in: inserted.document))
        #expect(cut.videoTrack.count == 2)
        let renderer = StayRenderFixture.renderer(folder)
        let calls = Mutex(0)
        let results = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            calls.withLock { $0 += 1 }
            return Self.path()
        }) {
            let reference = try await renderer.render(document: cut, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            let paused = try await renderer.render(document: inserted.document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            return (reference, paused)
        }
        defer {
            try? FileManager.default.removeItem(at: results.0.url)
            try? FileManager.default.removeItem(at: results.1.url)
        }
        #expect(calls.withLock { $0 } == 0)
        let expected = try await markerMoments(results.0.url, at: 0, rows: 360, folder: folder, frames: 120)
        let actual = try await markerMoments(results.1.url, at: 0, rows: 360, folder: folder, frames: 144)
        var drift = 0.0, absoluteDrift = 0.0
        for output in Array(0..<60) + Array(84..<144) {
            let source = try #require(actual[output].frame)
            let reference = try #require(expected.first { $0.frame == source })
            #expect(abs(reference.x - actual[output].x) <= 1)
            #expect(abs(reference.y - actual[output].y) <= 1)
            let error = actual[output].scale / reference.scale - 1
            #expect(abs(error) <= 0.01, "source frame \(source), output frame \(output)")
            drift += error / 120
            absoluteDrift += abs(error) / 120
        }
        #expect(abs(drift) <= 0.005)
        #expect(absoluteDrift <= 0.005)
        for output in 60..<84 {
            #expect(actual[output].frame == actual[84].frame)
            for boundary in [59, 84] {
                #expect(abs(actual[output].x - actual[boundary].x) <= 1)
                #expect(abs(actual[output].y - actual[boundary].y) <= 1)
                #expect(abs(actual[output].scale / actual[boundary].scale - 1) <= 0.005)
            }
        }
    }

    @Test("Empty highlights keep a preview in the export's tracked run and grid")
    func emptyHighlightsWindowMatchesExport() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("empty-highlights.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for index in doc.videoTrack.indices {
            doc.videoTrack[index].videoFile = input.path
            doc.videoTrack[index].strikeHighlights = true
        }
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 1.9, to: 2.6)
        let calls = Mutex<[(Double, Double)]>([])
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: true)
        var moments: [[(x: Double, y: Double, scale: Double, frame: Int?)]] = []
        try await CenterStageContinuity.$trackingOverride.withValue({ _, start, duration in
            calls.withLock { $0.append((start, duration)) }
            return Self.path()
        }) {
            for preview in [false, true] {
                let graphs = Mutex<[String]>([])
                let result = try await FFmpeg.$commandCompleted.withValue({ arguments in
                    guard let index = arguments.firstIndex(of: "-/filter_complex"), index + 1 < arguments.count,
                          let graph = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) else { return }
                    graphs.withLock { $0.append(graph) }
                }) {
                    try await renderer.render(document: preview ? window.document : doc, scenes: [], profile: Fixtures.brand(),
                        database: temp.database, preview: true, strikeHighlightTracks: [input.path: []],
                        continuity: preview ? window.continuity : [], emit: { _ in })
                }
                defer { try? FileManager.default.removeItem(at: result.url) }
                let affine = graphs.withLock { $0.filter { $0.contains("exact=1") } }
                #expect(!affine.isEmpty)
                #expect(affine.allSatisfy { $0.contains("max(1280,round(1280*") })
                moments.append(try await markerMoments(result.url, at: preview ? 0 : 1.9,
                    rows: 360, folder: folder, frames: 21))
            }
        }
        #expect(calls.withLock { $0.count } == 1)
        #expect(calls.withLock { $0.allSatisfy { abs($0.0) < 1e-9 && abs($0.1 - 2) < 1e-9 } })
        for index in 0..<21 {
            let a = moments[0][index], b = moments[1][index]
            #expect(try #require(a.frame) == #require(b.frame))
            #expect(abs(a.x - b.x) <= 1)
            #expect(abs(a.y - b.y) <= 1)
            #expect(abs(b.scale / a.scale - 1) <= 0.005)
        }
    }

    @Test("A saved tail cannot lower the tracked head's grid in the full render or a window")
    func mixedRunWindowUsesTrackedGrid() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("mixed-grid.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for index in doc.videoTrack.indices { doc.videoTrack[index].videoFile = input.path }
        doc.videoTrack[2].cameraPath = [.init(t: 0, x: 0.4, y: 0.4, w: 0.01, h: 0.01),
                                      .init(t: 1, x: 0.4, y: 0.4, w: 0.01, h: 0.01)]
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 0.75, to: 0.95)
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
        let requests = Mutex<[(Double, Double)]>([])
        try await CenterStageContinuity.$trackingOverride.withValue({ _, start, duration in
            requests.withLock { $0.append((start, duration)) }
            return FeedCameraPath(keyframes: [.init(t: 0, x: 0.1, y: 0.1, w: 0.1, h: 0.1),
                                             .init(t: 1, x: 0.2, y: 0.2, w: 0.4, h: 0.4)],
                samples: [], trackedShare: 1, sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
        }) {
            for preview in [false, true] {
                let graphs = Mutex<[String]>([])
                let result = try await FFmpeg.$commandCompleted.withValue({ arguments in
                    guard let index = arguments.firstIndex(of: "-/filter_complex"), index + 1 < arguments.count,
                          let graph = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) else { return }
                    graphs.withLock { $0.append(graph) }
                }) {
                    try await renderer.render(document: preview ? window.document : doc, scenes: [], profile: Fixtures.brand(),
                        database: temp.database, preview: true, continuity: preview ? window.continuity : [], emit: { _ in })
                }
                defer { try? FileManager.default.removeItem(at: result.url) }
                let trackedGraphs = graphs.withLock { $0.filter { $0.contains("exact=1") } }
                #expect(!trackedGraphs.isEmpty)
                for graph in trackedGraphs {
                    #expect(graph.contains("max(640,round(640*"))
                    #expect(!graph.contains("max(1280,round(1280*"))
                }
                if !preview {
                    let savedGraph = graphs.withLock { $0.contains { $0.contains("crop@area") } }
                    #expect(savedGraph)
                }
            }
        }
        let calls = requests.withLock { $0 }
        #expect(calls.count == 2)
        for call in calls {
            #expect(abs(call.0) < 1e-9)
            #expect(abs(call.1 - 1) < 1e-9)
        }
    }

    @concurrent
    private func markerMoments(_ url: URL, at time: Double, rows: Int, folder: URL, frames: Int = 1)
        async throws -> [(x: Double, y: Double, scale: Double, frame: Int?)] {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        defer { try? FileManager.default.removeItem(at: output) }
        try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", time), "-i", url.path,
            "-frames:v", String(frames), "-pix_fmt", "rgb24", "-f", "rawvideo", output.path], timeout: 60)
        let bytes = [UInt8](try Data(contentsOf: output))
        let frameSize = 640 * rows * 3
        guard bytes.count == frameSize * frames else { throw CocoaError(.fileReadCorruptFile) }
        let areas = rows / 360
        return (0..<(frames * areas)).map { item in
            let area = item % areas, offset = (item / areas) * frameSize
            var mass = 0.0, xSum = 0.0, ySum = 0.0
            // Locate the solid red marker, then weigh every pixel in a small
            // margin around it linearly: edge pixels count by their coverage,
            // so position and size resolve below a pixel. The margin keeps out
            // the faint reddish 4:2:0 fringes of a yellow drawing elsewhere.
            var left = 640, right = -1, top = (area + 1) * 360, bottom = -1
            func redness(_ x: Int, _ y: Int) -> Double {
                let index = offset + (y * 640 + x) * 3
                return Double(bytes[index]) - Double(max(bytes[index + 1], bytes[index + 2]))
            }
            for y in (area * 360)..<((area + 1) * 360) {
                for x in 0..<640 where redness(x, y) > 120 {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
            var level = 0.0
            if right >= left {
                // The marker's inner half is untouched by edge blur.
                var inner = 0.0, count = 0.0
                for y in (top + (bottom - top) / 4)...(bottom - (bottom - top) / 4) {
                    for x in (left + (right - left) / 4)...(right - (right - left) / 4) {
                        inner += redness(x, y); count += 1
                    }
                }
                level = inner / max(1, count)
                for y in max(area * 360, top - 4)...min((area + 1) * 360 - 1, bottom + 4) {
                    for x in max(0, left - 4)...min(639, right + 4) {
                        let weight = max(0, redness(x, y))
                        mass += weight
                        xSum += Double(x) * weight
                        ySum += Double(y) * weight
                    }
                }
            }
            #expect(mass > 0)
            let x = xSum / max(1, mass)
            // Size from the marker's summed coverage over its solid level: blur
            // from 4:2:0 chroma and the encoder moves the edge profile (and so
            // the variance) but keeps the sum; the level cancels colour
            // differences between the two renderers.
            return (x, ySum / max(1, mass), sqrt(mass / max(1, level)),
                Self.frameNumber(bytes, offset: offset, area: area))
        }
    }

    private nonisolated static func frameNumber(_ bytes: [UInt8], offset: Int, area: Int) -> Int? {
        var best: (y: Int, left: Int, right: Int)?
        for y in (area * 360)..<((area + 1) * 360) {
            var left = 640, right = -1
            for x in 0..<640 {
                let i = offset + (y * 640 + x) * 3
                if bytes[i + 2] > 170 && Int(bytes[i + 2]) - Int(bytes[i]) > 120 {
                    left = min(left, x); right = max(right, x)
                }
            }
            if right - left > (best.map { $0.right - $0.left } ?? 0) { best = (y, left, right) }
        }
        guard let best, best.right - best.left >= 16 else { return nil }
        return (0..<8).reduce(0) { value, bit in
            let x = best.left + Int((Double(bit) + 0.5) * Double(best.right - best.left + 1) / 8)
            let index = offset + (best.y * 640 + x) * 3
            return value | (bytes[index + 1] > 128 ? 1 << bit : 0)
        }
    }

    @Test(arguments: [false, true], ["area", "full"])
    func framingVersionReplacesLegacyMovies(outside: Bool, route: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("cache-picture.mp4")
        try await source(input)
        var doc = Self.twoAreas(input: input)
        if route == "full" {
            doc.videoTrack = [doc.videoTrack[0]]
            doc.videoTrack[0].framingPlan = nil
            doc.videoTrack[0].centerStage = true
            doc.videoTrack[0].wide = true
            doc.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        }
        // Neither route has a content window: both used to restore old movies
        // before any bounds proof. The framing version must invalidate both.
        let cache = RenderSegmentCache(directory: folder.appendingPathComponent("cache"))
        let keys = try RenderContext.$settings.withValue(doc.renderSettings) {
            try MultitrackRenderer.resolveClips(document: doc, scenes: []).map { resolved in
                try MultitrackRenderer.prepassKey(resolved, area: CenterStageContinuity.prepassArea(resolved),
                    tuning: resolved.framingPlan?.camera ?? "balanced", version: "multitrack-framing-v10-motion")
            }
        }
        // A legacy movie has no evidence that its crop respected the picture.
        for key in keys { await cache.store(key: key, from: input) }
        let calls = Mutex(0)
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache,
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: true)
        try await CenterStageService.$trackingPathOverride.withValue({ _, _, duration in
            calls.withLock { $0 += 1 }
            return [0, duration].map { .init(t: $0, x: outside ? -0.1 : 0.2, y: 0.1, w: 0.5, h: 0.5) }
        }) {
            for _ in 0..<2 {
                let result = try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
                defer { try? FileManager.default.removeItem(at: result.url) }
                if route == "area" {
                    let bytes = try await areaPixels(result.url, start: 0, frames: 1, folder: folder)
                    Self.expectFilledEdges(bytes, frames: 1)
                }
            }
        }
        #expect(calls.withLock { $0 } == (route == "area" ? 2 : 1))
        #expect(MultitrackRenderer.framingVersion == "multitrack-framing-v13-vip-paths")
    }

    @Test(arguments: [false, true])
    func sharedAreaPauseUsesBothPicturesPaths(unionFails: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("two-area-marker.mp4")
        try await source(input)
        var doc = Self.twoAreas(input: input)
        let unsplit = doc
        let pieces = try #require(StrikeFreezeRules.sharedPieces(WizardSharedPauses.tracks(doc),
            pauses: [.init(time: 1, duration: 0.8)]))
        doc.videoTrack = pieces.flatMap { $0 }
        let calls = Mutex<[Double]>([])
        let logs = Mutex<[String]>([])
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, duration in
            calls.withLock { $0.append(duration) }
            if unionFails && duration > 1.5 { throw CocoaError(.fileReadUnknown) }
            var path = Self.path()
            if unionFails {
                path.keyframes = [0, duration].map { .init(t: $0, x: 0.2, y: 0.1, w: 0.5, h: 0.5) }
            }
            return path
        }) {
            try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in logs.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let reference = try await CenterStageService.$trackingPathOverride.withValue({ _, _, duration in
            unionFails ? [0, duration].map { .init(t: $0, x: 0.2, y: 0.1, w: 0.5, h: 0.5) }
                : Self.path().keyframes
        }) {
            try await renderer.render(document: unsplit, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: reference.url) }
        var centers: [[Double]] = []
        // The preceding frame and the editor's held frame have different
        // source times, even where this fixture's camera is nearly flat.
        for (movie, time) in [(result.url, 29.0 / 30), (result.url, 1.2), (result.url, 1.8),
                              (reference.url, 29.0 / 30), (reference.url, 1.0)] {
            let bytes = try await areaPixels(movie, start: time, frames: 1, folder: folder)
            Self.expectFilledEdges(bytes, frames: 1)
            var areas: [Double] = []
            for area in 0..<2 {
                var sum = 0, count = 0
                for y in (area * 360)..<((area + 1) * 360) {
                    for x in 0..<640 {
                        let i = (y * 640 + x) * 3
                        if bytes[i] > 170 && bytes[i + 1] < 70 && bytes[i + 2] < 70 { sum += x; count += 1 }
                    }
                }
                #expect(count > 0)
                areas.append(Double(sum) / Double(max(1, count)))
            }
            centers.append(areas)
        }
        for area in 0..<2 {
            #expect(abs(centers[0][area] - centers[3][area]) <= 1)
            #expect(abs(centers[1][area] - centers[4][area]) <= 1)
            #expect(abs(centers[2][area] - centers[4][area]) <= 1)
        }
        #expect(calls.withLock { $0.count } == (unionFails ? 6 : 2))
        #expect(calls.withLock { $0.allSatisfy { $0 >= 1 } })
        #expect(logs.withLock { $0.filter { $0.contains("pieces framed separately") }.count } == (unionFails ? 1 : 0))
    }

    /// Baked bars are deliberately part of the decoded source, as in live4a.
    @Test(arguments: [false, true], ["graph", "movie", "fresh"])
    func openingAreaWindowsDoNotExposeBars(bakedBars: Bool, route: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("barred.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=1024x576:r=30:d=2",
            "-vf", bakedBars ? "pad=1280:720:128:72:color=black" : "scale=1280:720",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path], timeout: 60)
        var doc = Self.twoAreas(input: input)
        let path: [CameraPathKeyframe] = [
            .init(t: 0, x: -0.1, y: -0.1, w: 0.5, h: 0.5),
            .init(t: 0.2, x: -0.05, y: -0.05, w: 0.5, h: 0.5),
            .init(t: 2, x: 0.3, y: 0.3, w: 0.5, h: 0.5)]
        for index in doc.videoTrack.indices {
            if bakedBars {
                doc.videoTrack[index].contentWindow = .init(xFrac: 0.1, yFrac: 0.1, wFrac: 0.8, hFrac: 0.8)
            }
            doc.videoTrack[index].cameraPath = route == "fresh" ? nil : path
        }
        let renderer = MultitrackRenderer(render: RenderEngine(),
            segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: false)
        let result = try await ExpressRenderTesting.$exportAreaPaths.withValue(route == "movie") {
            try await CenterStageService.$trackingPathOverride.withValue({ _, _, _ in path }) {
                try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
                    database: temp.database, preview: true, emit: { _ in })
            }
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let bytes = try await areaPixels(result.url, start: 0, frames: 10, folder: folder)
        Self.expectFilledEdges(bytes, frames: 10)
    }

    static func twoAreas(input: URL) -> TimelineDocument {
        let layout = ScreenCropLayout(name: "Continuity areas", areas: [
            .init(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)]),
            .init(name: "Bottom", points: [.init(x: 0, y: 0.5), .init(x: 1, y: 0.5), .init(x: 1, y: 1), .init(x: 0, y: 1)])])
        let clips = (0..<2).map { track in
            var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2, track: track)
            clip.videoFile = input.path
            clip.sourceEnd = 2
            clip.wide = false
            clip.centerStage = false
            clip.captions = "none"
            clip.precision = .speech
            clip.framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            return clip
        }
        var doc = Fixtures.timelineDocument(clips: clips)
        doc.trackCount = 2
        doc.trackSequential[1] = false
        doc.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 720)
        return doc
    }

    @concurrent
    private func areaPixels(_ source: URL, start: Double, frames: Int, folder: URL) async throws -> [UInt8] {
        let output = folder.appendingPathComponent(UUID().uuidString + ".rgb")
        try await FFmpeg.run(["-y", "-ss", String(start), "-i", source.path,
            "-frames:v", String(frames), "-f", "rawvideo", "-pix_fmt", "rgb24", output.path], timeout: 60)
        return Array(try Data(contentsOf: output))
    }

    private nonisolated static func expectFilledEdges(_ bytes: [UInt8], frames: Int) {
        #expect(bytes.count == frames * 640 * 720 * 3)
        guard bytes.count == frames * 640 * 720 * 3 else { return }
        var darkest: UInt8 = 255
        for frame in 0..<frames {
            for area in 0..<2 {
                for y in (area * 360)..<((area + 1) * 360) {
                    for x in [0, 1, 638, 639] {
                        darkest = min(darkest, bytes[((frame * 720 + y) * 640 + x) * 3])
                    }
                }
                for y in [area * 360, area * 360 + 1, area * 360 + 358, area * 360 + 359] {
                    for x in 0..<640 { darkest = min(darkest, bytes[((frame * 720 + y) * 640 + x) * 3]) }
                }
            }
        }
        #expect(darkest > 70)
    }

    @concurrent
    private func source(_ url: URL) async throws {
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=gray:s=1280x720:r=30:d=4",
            "-vf", "drawbox=x=500:y=300:w=80:h=100:color=red:t=fill,format=gbrp,"
                + "geq=r='if(between(X,500,579)*between(Y,410,425),0,r(X,Y))':"
                + "g='if(between(X,500,579)*between(Y,410,425),255*mod(floor(N/pow(2,floor((X-500)/10))),2),g(X,Y))':"
                + "b='if(between(X,500,579)*between(Y,410,425),255,b(X,Y))'",
            "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", url.path], timeout: 60)
    }

    private nonisolated static func path() -> FeedCameraPath {
        FeedCameraPath(keyframes: [
            .init(t: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 0.95, x: 0.2, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 1.05, x: 0.2, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 2, x: 0.3, y: 0.1, w: 0.5, h: 0.5)],
            samples: [], trackedShare: 1, sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
    }

    @concurrent
    private func redCenter(_ url: URL, time: Double, folder: URL) async throws -> Double {
        let pixels = try await StayRenderFixture.pixels(url, time: time, folder: folder)
        #expect(pixels.count == 640 * 360 * 3)
        var sum = 0, count = 0
        for y in 0..<360 {
            for x in 0..<640 {
                let i = (y * 640 + x) * 3
                if pixels[i] > 170 && pixels[i + 1] < 70 && pixels[i + 2] < 70 {
                    sum += x
                    count += 1
                }
            }
        }
        #expect(count > 0)
        return Double(sum) / Double(max(1, count))
    }

    @Test func pausePreviewAndCacheUseOneUnion() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for i in doc.videoTrack.indices { doc.videoTrack[i].videoFile = input.path }
        let calls = Mutex<[(Double, Double)]>([])
        let cache = RenderSegmentCache(directory: folder.appendingPathComponent("cache"))
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: cache,
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: true)
        var unsplit = doc
        unsplit.videoTrack = [doc.videoTrack[0]]
        unsplit.videoTrack[0].duration = 2
        let reference = try await CenterStageService.$trackingPathOverride.withValue({ _, _, _ in Self.path().keyframes }) {
            try await renderer.render(document: unsplit, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let expectedBefore = try await redCenter(reference.url, time: 29.0 / 30, folder: folder)
        let expectedPause = try await redCenter(reference.url, time: 1, folder: folder)
        try await CenterStageContinuity.$trackingOverride.withValue({ _, start, duration in
            calls.withLock { $0.append((start, duration)) }
            return Self.path()
        }) {
            let result = try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: result.url) }
            let before = try await redCenter(result.url, time: 29.0 / 30, folder: folder)
            let held = try await redCenter(result.url, time: 1.2, folder: folder)
            let after = try await redCenter(result.url, time: 1.8, folder: folder)
            #expect(abs(before - expectedBefore) <= 1)
            #expect(abs(held - expectedPause) <= 1)
            #expect(abs(after - expectedPause) <= 1)
            #expect(calls.withLock { $0.count } == 1)
            #expect(calls.withLock { abs($0[0].0) < 1e-9 && abs($0[0].1 - 2) < 1e-9 })
            let window = MultitrackRenderer.windowed(doc, scenes: [], from: 1.9, to: 2.6)
            let preview = try await renderer.render(document: window.document, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, continuity: window.continuity, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: preview.url) }
            let fullPosition = try await redCenter(result.url, time: 2.2, folder: folder)
            let previewPosition = try await redCenter(preview.url, time: 0.3, folder: folder)
            #expect(abs(fullPosition - previewPosition) <= 1)
            doc.videoTrack[1].duration += 0.5
            doc.videoTrack[2].startTime += 0.5
            let longer = try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
            defer { try? FileManager.default.removeItem(at: longer.url) }
            #expect(calls.withLock { $0.count } == 1)
        }
    }

    @Test func singleClipKeepsPerPieceTrackingAndKey() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        doc.videoTrack = [doc.videoTrack[0]]
        doc.videoTrack[0].videoFile = input.path
        let clip = try #require(MultitrackRenderer.resolveClips(document: doc, scenes: []).first)
        var previous = clip
        previous.continuityClipID = nil
        previous.continuityLayout = nil
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced")
            == MultitrackRenderer.prepassKey(previous, area: nil, tuning: "balanced"))
        let calls = Mutex(0)
        let logs = Mutex<[String]>([])
        let result = try await CenterStageService.$trackingInputObserver.withValue({ _, _, _ in
            calls.withLock { $0 += 1 }
        }) {
            try await StayRenderFixture.renderer(temp.directory.url).render(document: doc, scenes: [],
                profile: Fixtures.brand(), database: temp.database, preview: true,
                emit: { line in logs.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(calls.withLock { $0 } == 1)
        #expect(!logs.withLock { $0 }.contains { $0.contains("continuous") || $0.contains("pieces framed separately") })
    }

    @Test func unsupportedTuningDoesNotTrackUnion() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for i in doc.videoTrack.indices { doc.videoTrack[i].videoFile = input.path }
        let clips = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        let run = try #require(CenterStageContinuity.runs(clips).first)
        let logs = Mutex<[String]>([])
        let calls = Mutex(0)
        let path = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            calls.withLock { $0 += 1 }
            return Self.path()
        }) {
            try await CenterStageContinuity.prepare(run, defaultCamera: "steady", service: CenterStageService(),
                cache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")),
                cacheEnabled: false, database: temp.database, emit: { line in logs.withLock { $0.append(line) } })
        }
        #expect(path == nil)
        #expect(calls.withLock { $0 } == 0)
        #expect(logs.withLock { $0 }.contains { $0.contains("Center Stage: pieces framed separately") })
    }

    @Test(arguments: ["moving", "mixedSpeed", "screenStay"])
    func movingPathAcrossPause(kind: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for i in doc.videoTrack.indices { doc.videoTrack[i].videoFile = input.path }
        if kind == "mixedSpeed" {
            doc.videoTrack[0].speed = 0.5
            doc.videoTrack[0].duration = 2
            doc.videoTrack[1].startTime = 2
            doc.videoTrack[2].startTime = 2.8
            doc.videoTrack[2].speed = 2
            doc.videoTrack[2].duration = 0.5
        }
        if kind == "screenStay" {
            let drawing = Telestration(time: 1, figures: [.init(kind: .line,
                points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.3)],
                color: .yellow, width: 0.016, linger: 1.2)], stay: 0.5, drawSpeed: 0.5, fade: 0.2)
            doc.videoTrack[1].telestration = drawing
            doc.videoTrack[1].duration = drawing.duration
            doc.videoTrack[2].startTime = 1 + drawing.duration
        }
        // A nonzero slope throughout the join, including the preceding
        // source frame. This is deliberately not the flat-boundary fixture.
        let path = FeedCameraPath(keyframes: [
            .init(t: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 2, x: 0.13, y: 0.1, w: 0.5, h: 0.5)],
            samples: [], trackedShare: 1, sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
        let calls = Mutex(0)
        let logs = Mutex<[String]>([])
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            calls.withLock { $0 += 1 }
            return path
        }) {
            try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in logs.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(calls.withLock { $0 } == 1)
        let holdStart = doc.videoTrack[1].startTime
        let tailStart = doc.videoTrack[2].startTime
        let beforeTime = Double(Int((holdStart * 30).rounded()) - 1) / 30
        let before = try await redCenter(result.url, time: beforeTime - 0.000001, folder: folder)
        let held = try await redCenter(result.url, time: holdStart + 0.2, folder: folder)
        let firstTailTime = Double(Int((tailStart * 30).rounded())) / 30
        let after = try await redCenter(result.url, time: firstTailTime - 0.000001, folder: folder)
        var unsplit = doc
        unsplit.videoTrack = [doc.videoTrack[0]]
        unsplit.videoTrack[0].speed = 1
        unsplit.videoTrack[0].duration = 2
        let reference = try await CenterStageService.$trackingPathOverride.withValue({ _, _, _ in path.keyframes }) {
            try await StayRenderFixture.renderer(folder).render(document: unsplit, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let beforeFrames = try await markerMoments(result.url, at: beforeTime - 0.000001, rows: 360, folder: folder)
        let heldFrames = try await markerMoments(result.url, at: holdStart + 0.2, rows: 360, folder: folder)
        let tailFrames = try await markerMoments(result.url, at: firstTailTime - 0.000001, rows: 360, folder: folder)
        let beforeID = try #require(beforeFrames.first?.frame)
        let heldID = try #require(heldFrames.first?.frame)
        let tailID = try #require(tailFrames.first?.frame)
        let expectedBefore = try await redCenter(reference.url, time: max(0, Double(beforeID) / 30 - 0.000001), folder: folder)
        let expectedHold = try await redCenter(reference.url, time: max(0, Double(heldID) / 30 - 0.000001), folder: folder)
        let expectedTail = try await redCenter(reference.url, time: max(0, Double(tailID) / 30 - 0.000001), folder: folder)
        // Camera motion between two different source frames is not an error.
        // Compare each boundary with its own unsplit source frame instead.
        let afterLimit = kind == "mixedSpeed" ? 2.5 : 1.0
        #expect(abs(before - expectedBefore) <= 1)
        #expect(abs(held - expectedHold) <= 1)
        #expect(abs(after - expectedTail) <= afterLimit, "\(kind): expected \(expectedTail), after \(after)")
        let laterTime = min(0.5, doc.videoTrack[2].duration - 1.0 / 30)
        let later = try await redCenter(result.url, time: tailStart + laterTime, folder: folder)
        #expect(after - later > 7)
        if kind == "screenStay" {
            let holdPixels = try await StayRenderFixture.pixels(result.url, time: tailStart - 1.0 / 30, folder: folder)
            let laterPixels = try await StayRenderFixture.pixels(result.url, time: tailStart + 0.5, folder: folder)
            let heldBox = try #require(Self.yellowBounds(holdPixels))
            let laterBox = try #require(Self.yellowBounds(laterPixels))
            #expect(abs(heldBox.minX - laterBox.minX) <= 1 && abs(heldBox.maxX - laterBox.maxX) <= 1)
            #expect(abs(heldBox.minY - laterBox.minY) <= 1 && abs(heldBox.maxY - laterBox.maxY) <= 1)
            #expect(!logs.withLock { $0 }.contains { $0.contains("source-fixed") || $0.contains("pieces framed separately") })
        }
    }

    private nonisolated static func yellowBounds(_ bytes: [UInt8]) -> CGRect? {
        guard bytes.count == 640 * 360 * 3 else { return nil }
        var left = 640, right = -1, top = 360, bottom = -1
        for y in 0..<360 {
            for x in 0..<640 {
                let i = (y * 640 + x) * 3
                if bytes[i] > 190 && bytes[i + 1] > 190 && bytes[i + 2] < 80 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        return right >= left ? CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1) : nil
    }

    @Test(arguments: [false, true])
    func rejectedStoredPathsTrackOneUnion(contentWindow: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for i in doc.videoTrack.indices {
            doc.videoTrack[i].videoFile = input.path
            doc.videoTrack[i].cameraPath = [.init(t: 0, x: 0, y: 0, w: contentWindow ? 1 : 0.5, h: 1),
                                           .init(t: 2, x: 0, y: 0, w: contentWindow ? 1 : 0.5, h: 1)]
            if contentWindow { doc.videoTrack[i].contentWindow = .init(wFrac: 0.6) }
        }
        doc.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2.8)]
        let calls = Mutex(0)
        // No scene metadata: the real source size must settle applicability.
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            calls.withLock { $0 += 1 }
            return Self.path()
        }) {
            try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func unusableUnionIsCachedWithSameFallbackLog() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("marker.mp4")
        try await source(input)
        var doc = CenterStageContinuityTests.document()
        for i in doc.videoTrack.indices { doc.videoTrack[i].videoFile = input.path }
        let run = try #require(CenterStageContinuity.runs(MultitrackRenderer.resolveClips(document: doc, scenes: [])).first)
        let calls = Mutex(0)
        let logs = Mutex<[String]>([])
        try await RenderContext.$settings.withValue(doc.renderSettings) {
            try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
                calls.withLock { $0 += 1 }
                var path = Self.path()
                path.trackedShare = 0
                path.usedFallback = true
                return path
            }) {
                // One cache for the launch: the failure is remembered between
                // renders, not only while a task is in flight.
                let cache = RenderSegmentCache(directory: folder.appendingPathComponent("cache"))
                for _ in 0..<2 {
                    let result = try await CenterStageContinuity.prepare(run, defaultCamera: "balanced",
                        service: CenterStageService(), cache: cache,
                        cacheEnabled: true, database: temp.database, emit: { line in logs.withLock { $0.append(line) } })
                    #expect(result == nil)
                }
                #expect(calls.withLock { $0 } == 1)
                // A new launch tries again: a quiet tracker failure cannot be
                // told from "nobody to follow", so it is never kept on disk.
                let relaunched = try await CenterStageContinuity.prepare(run, defaultCamera: "balanced",
                    service: CenterStageService(), cache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
                    cacheEnabled: true, database: temp.database, emit: { line in logs.withLock { $0.append(line) } })
                #expect(relaunched == nil)
            }
        }
        #expect(calls.withLock { $0 } == 2)
        let failures = logs.withLock { $0.filter { $0.contains("Center Stage: pieces framed separately") } }
        #expect(failures.count == 3 && failures[0] == failures[1])
    }

    @Test func concurrentPreviewAndFullRenderShareUnion() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("marker.mp4")
        try await source(input)
        var document = CenterStageContinuityTests.document()
        for i in document.videoTrack.indices { document.videoTrack[i].videoFile = input.path }
        let doc = document
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 1.9, to: 2.6)
        let renderer = MultitrackRenderer(render: RenderEngine(), segmentCache: RenderSegmentCache(directory: folder.appendingPathComponent("cache")),
            finishingCacheEnabled: false, assemblyCacheEnabled: false, framingCacheEnabled: true)
        let calls = Mutex(0)
        let profile = Fixtures.brand()
        let database = temp.database
        let release = AsyncStream<Void>.makeStream()
        let requests = Mutex(0)
        defer { release.continuation.finish() }
        try await CenterStageContinuity.$unionRequestObserver.withValue({
            let count = requests.withLock { $0 += 1; return $0 }
            if count == 2 { release.continuation.finish() }
        }) {
            try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
                calls.withLock { $0 += 1 }
                for await _ in release.stream { break }
                return Self.path()
            }) {
                async let full = renderer.render(document: doc, scenes: [], profile: profile, database: database,
                    preview: true, emit: { _ in })
                async let preview = renderer.render(document: window.document, scenes: [], profile: profile, database: database,
                    preview: true, continuity: window.continuity, emit: { _ in })
                let (a, b) = try await (full, preview)
                defer { try? FileManager.default.removeItem(at: a.url); try? FileManager.default.removeItem(at: b.url) }
                let fullPosition = try await redCenter(a.url, time: 2.2, folder: folder)
                let previewPosition = try await redCenter(b.url, time: 0.3, folder: folder)
                #expect(abs(fullPosition - previewPosition) <= 1)
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

}
