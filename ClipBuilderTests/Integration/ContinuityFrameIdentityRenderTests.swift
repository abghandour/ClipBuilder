import AVFoundation
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Continuity frame and audio identity", .enabled(if: FixtureVideo.integrationsAvailable))
struct ContinuityFrameIdentityRenderTests {
    private nonisolated static let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 1, h: 1),
                               CameraPathKeyframe(t: 4, x: 0, y: 0, w: 1, h: 1)]

    @concurrent
    private static func source(_ url: URL, rate: Int, variable: Bool = false) async throws {
        // Luma blocks encode video frame IDs. Each 50 ms audio cell carries
        // a 25 ms burst with an indexed frequency AND amplitude pattern.
        var filter = "geq=lum='32+192*mod(floor(N/pow(2,floor(X/80))),2)':cb=128:cr=128"
        if variable { filter += ",setpts=PTS+floor(N/7)*0.01/TB" }
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "nullsrc=s=640x360:r=\(rate):d=4",
            "-f", "lavfi", "-i", "aevalsrc=0.35*(0.4+0.6*mod(floor(t*20)*37\\,101)/100)*lt(mod(t\\,0.05)\\,0.025)*sin(2*PI*(600+80*mod(floor(t*20)*7\\,23))*t):s=44100:d=5",
            "-vf", filter, "-fps_mode", "vfr", "-c:v", "libx264", "-qp", "0",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path], timeout: 60)
    }

    private static func document(_ source: URL, origin: Double = 0.137) -> TimelineDocument {
        var doc = CenterStageContinuityTests.document()
        let template = doc.videoTrack[0]
        var clips: [TimelineClip] = []
        var clock = 0.0
        // Two fractional pauses, a 2x incoming piece, 0.5x motion, and a
        // companion-style end hold already pointing inside the last frame.
        for (start, duration, speed, hold) in [
            (origin, 0.98, 1.0, false), (origin + 0.98, 0.4, 1.0, true),
            (origin + 0.98, 0.51, 2.0, false), (origin + 2, 0.4, 1.0, true),
            (origin + 2, 1.0, 0.5, false), (origin + 2.499, 0.4, 1.0, true)
        ] {
            var clip = template
            clip.uid = UUID()
            clip.videoFile = source.path
            clip.startTime = clock
            clip.sourceStart = start
            clip.sourceEnd = start + (hold ? 0 : duration * speed)
            clip.duration = duration
            clip.speed = speed
            clip.hold = hold
            clips.append(clip)
            clock += duration
        }
        doc.videoTrack = clips
        return doc
    }

    @concurrent
    private static func numbers(_ movie: URL, folder: URL, areas: Int = 1) async throws -> [Int] {
        let raw = folder.appendingPathComponent(UUID().uuidString + ".gray")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await FFmpeg.run(["-y", "-i", movie.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-pix_fmt", "gray",
            "-f", "rawvideo", raw.path], timeout: 60)
        let bytes = [UInt8](try Data(contentsOf: raw))
        let size = 640 * 360
        guard bytes.count.isMultiple(of: size * areas) else { throw CocoaError(.fileReadCorruptFile) }
        return stride(from: 0, to: bytes.count, by: size).map { offset in
            (0..<8).reduce(0) { value, bit in
                value | (bytes[offset + 180 * 640 + bit * 80 + 40] > 128 ? 1 << bit : 0)
            }
        }
    }

    @concurrent
    private static func samples(_ movie: URL, folder: URL) async throws -> [Float] {
        let raw = folder.appendingPathComponent(UUID().uuidString + ".f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await FFmpeg.run(["-y", "-i", movie.path, "-vn", "-ac", "1", "-ar", "44100",
            "-f", "f32le", raw.path], timeout: 60)
        return try Data(contentsOf: raw).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Locate the coded burst pattern in decoded audio, reporting the measured
    /// offset in SECONDS (not a waveform RMS). AAC/atempo can change carrier
    /// phase and burst energy. Never discard the fitted offset: 15 ms is less
    /// than half an output frame, so either one-frame shift must fail.
    private nonisolated static func positionError(_ actual: [Float], at: Int,
                                                  _ reference: [Float], from: Int, count: Int) -> Double {
        guard at >= 0, from >= 0, count >= 256,
              at + count <= actual.count, from + count <= reference.count else { return .infinity }
        let radius = 2940
        let first = max(0, from - radius), last = min(reference.count, from + count + radius)
        func energy(_ samples: ArraySlice<Float>) -> [Double] {
            var result = [0.0]
            result.reserveCapacity(samples.count + 1)
            for sample in samples { result.append(result.last! + Double(sample) * Double(sample)) }
            return result
        }
        let a = energy(actual[at..<(at + count)]), b = energy(reference[first..<last])
        let cells = Array(stride(from: 0, through: count - 256, by: 256))
        let expected = cells.map { sqrt(max(0, a[$0 + 256] - a[$0]) / 256) }
        var best = Double.infinity, bestOffset = 0
        // 49 samples = 1/900 s; exactly thirty steps per output frame.
        for offset in stride(from: -radius, through: radius, by: 49) {
            let start = from + offset - first
            guard start >= 0, start + count < b.count else { continue }
            var squared = 0.0
            for (index, cell) in cells.enumerated() {
                let rms = sqrt(max(0, b[start + cell + 256] - b[start + cell]) / 256)
                let delta = expected[index] - rms
                squared += delta * delta
            }
            let score = sqrt(squared / Double(cells.count))
            if score < best - 1e-9 || (abs(score - best) < 1e-9 && abs(offset) < abs(bestOffset)) {
                best = score
                bestOffset = offset
            }
        }
        // Measured independent AAC/tempo generations vary by up to 0.054
        // in energy, while a wrong code still has to pass the position limit.
        guard best < 0.065 else { return .infinity }
        return Double(abs(bestOffset)) / 44100
    }

    private nonisolated static func number(_ image: CGImage) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: 8)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 1,
                bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 1))
        }
        return pixels.enumerated().reduce(0) { $0 | ($1.element > 128 ? 1 << $1.offset : 0) }
    }

    /// Compare the same paused timeline with tracking off. Frame identities
    /// come from decoded pixels; hold/audio ranges use the measured clock.
    @concurrent
    private static func checkPaused(_ result: URL, document: TimelineDocument, clock: RenderClock?,
                                    folder: URL, database: Database) async throws {
        var untracked = document
        for index in untracked.videoTrack.indices {
            untracked.videoTrack[index].centerStage = false
            untracked.videoTrack[index].wide = false
            untracked.videoTrack[index].cameraPath = nil
            untracked.videoTrack[index].areaRegion = nil
            if untracked.videoTrack[index].framingPlan != nil {
                untracked.videoTrack[index].areaWindow = FreeCropRect()
            }
        }
        let reference = try await StayRenderFixture.renderer(folder).render(document: untracked, scenes: [],
            profile: Fixtures.brand(), database: database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let areas = document.renderSettings.height / 360
        let actual = try await numbers(result, folder: folder, areas: areas)
        let expected = try await numbers(reference.url, folder: folder, areas: areas)
        #expect(actual == expected, "tracking must not change ANY source frame")
        let audio = try await samples(result, folder: folder)
        let referenceAudio = try await samples(reference.url, folder: folder)
        #expect(audio.count == referenceAudio.count)
        for clip in document.videoTrack {
            let first = Int(((clock?.map(clip.startTime) ?? clip.startTime) * 30).rounded())
            let clipEnd = clip.startTime + clip.duration
            let end = Int(((clock?.map(clipEnd, end: true) ?? clipEnd) * 30).rounded())
            try #require(first >= 0 && end * areas <= actual.count)
            if clip.hold == true {
                let still = try await TelestratorFrameLoader.load(url: URL(fileURLWithPath: clip.videoFile ?? ""),
                    time: clip.sourceStart ?? 0, duration: 4, lockTime: true)
                let editor = try number(still.image)
                #expect((first..<end).allSatisfy { actual[$0 * areas + clip.track] == editor }, "every hold frame matches the editor")
            } else if abs(clip.effectiveSpeed - 1) < 1e-9 {
                let range = (first * 1470)..<min(end * 1470, audio.count, referenceAudio.count)
                #expect(Array(audio[range]) == Array(referenceAudio[range]), "1x audio is sample-identical")
            } else {
                let start = first * 1470 + 1024
                let count = min(end * 1470, audio.count, referenceAudio.count) - start - 1024
                try #require(count > 256)
                let error = positionError(audio, at: start, referenceAudio, from: start, count: count)
                #expect(error < 0.015, "tempo source position: \(error)")
            }
        }
        for clip in document.videoTrack.dropFirst() {
            let center = Int(((clock?.map(clip.startTime) ?? clip.startTime) * 30).rounded()) * 1470
            let range = max(0, center - 4410)..<min(audio.count, referenceAudio.count, center + 4410)
            let error = positionError(audio, at: range.lowerBound, referenceAudio,
                from: range.lowerBound, count: range.count)
            #expect(error < 0.015, "audio join at \(clip.startTime): \(error)")
        }
    }

    @Test(arguments: [1.0, 0.5, 2.0])
    func audioPositionCheckRejectsEitherOneFrameShift(speed: Double) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("coded.mp4")
        try await Self.source(input, rate: 30)
        let output = folder.appendingPathComponent("tempo.m4a")
        let tempo = StrikeImpactRender.audioTempo(speed: speed) + "anull"
        try await FFmpeg.run(["-y", "-i", input.path, "-vn", "-af", tempo,
            "-c:a", "aac", output.path], timeout: 60)
        let reference = try await Self.samples(output, folder: folder)
        let reencoded = folder.appendingPathComponent("another-generation.m4a")
        try await FFmpeg.run(["-y", "-i", output.path, "-c:a", "aac", reencoded.path], timeout: 60)
        let actual = try await Self.samples(reencoded, folder: folder)
        let start = 4410
        let count = min(44100, reference.count - start - 1470, actual.count - start - 1470)
        let aligned = Self.positionError(actual, at: start, reference, from: start, count: count)
        #expect(aligned < 0.015)
        for shift in [-1470, 1470] {
            let shifted = Self.positionError(actual, at: start + shift, reference, from: start, count: count)
            #expect(shifted >= 0.015, "must reject a one-frame shift at \(speed)x: \(shifted)")
        }
    }

    @Test("Mixed-rate companion holds share boundaries and preserve untracked sample choices")
    func variableRateCompanionsShareHoldSegments() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let top = folder.appendingPathComponent("top60.mp4")
        let bottom = folder.appendingPathComponent("bottom30.mp4")
        try await Self.source(top, rate: 60, variable: true)
        try await Self.source(bottom, rate: 30, variable: true)
        var doc = CenterStageContinuityRenderTests.twoAreas(input: top)
        doc.videoTrack[0].sourceStart = 0.137
        doc.videoTrack[0].sourceEnd = 2.137
        doc.videoTrack[1].videoFile = bottom.path
        doc.videoTrack[1].sourceStart = 0.123
        doc.videoTrack[1].sourceEnd = 2.123
        let tracks = WizardSharedPauses.tracks(doc)
        let pieces = try #require(StrikeFreezeRules.sharedPieces(tracks,
            pauses: [.init(time: 0.8, duration: 0.4), .init(time: 1.3, duration: 0.4)]))
        doc.videoTrack = pieces.flatMap { $0 }
        let resolved = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        for segment in MultitrackRenderer.buildLayeredSegments(resolved) {
            let holdStates = Set(segment.clips.map(\.hold))
            #expect(holdStates.count == 1)
        }
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, duration in
            let path = [0, duration].map { CameraPathKeyframe(t: $0, x: 0, y: 0, w: 1, h: 1) }
            return FeedCameraPath(keyframes: path, samples: [], trackedShare: 1,
                sourceSize: CGSize(width: 640, height: 360), usedFallback: false)
        }) {
            try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { _ in })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        try await Self.checkPaused(result.url, document: doc, clock: result.clock, folder: folder, database: temp.database)
    }

    @Test(arguments: [24, 25, 30, 60], ["full", "area", "region", "stored", "companion"])
    func everyFrameAndAudioJoinMatchesTheSamePausedDocument(rate: Int, route: String) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("identity.mp4")
        try await Self.source(input, rate: rate)
        var doc = Self.document(input)
        for index in doc.videoTrack.indices {
            if route == "region" { doc.videoTrack[index].areaRegion = FreeCropRect() }
            if route == "stored" { doc.videoTrack[index].cameraPath = Self.path }
        }
        if route == "area" {
            let layout = ScreenCropLayout(name: "One picture", areas: [.init(name: "Picture", points: [
                .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])])
            for index in doc.videoTrack.indices {
                doc.videoTrack[index].centerStage = false
                doc.videoTrack[index].framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            }
        }
        if route == "companion" {
            // Independent picture on another track, using the same source.
            doc.videoTrack += doc.videoTrack.map { clip in
                var copy = clip
                copy.uid = UUID(); copy.track = 1; copy.volume = 0
                return copy
            }
            let layout = CenterStageContinuityRenderTests.twoAreas(input: input)
            let plan = layout.videoTrack[0].framingPlan
            doc.renderSettings = layout.renderSettings
            doc.trackCount = 2; doc.trackSequential[1] = false
            for index in doc.videoTrack.indices {
                doc.videoTrack[index].centerStage = false
                doc.videoTrack[index].framingPlan = plan
            }
        }
        let logs = Mutex<[String]>([])
        let result = try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            FeedCameraPath(keyframes: Self.path, samples: [], trackedShare: 1,
                sourceSize: CGSize(width: 640, height: 360), usedFallback: false)
        }) {
            try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [], profile: Fixtures.brand(),
                database: temp.database, preview: true, emit: { line in logs.withLock { $0.append(line) } })
        }
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(!logs.withLock { $0 }.contains { $0.contains("pieces framed separately") })
        try await Self.checkPaused(result.url, document: doc, clock: result.clock, folder: folder, database: temp.database)
    }

    @Test(arguments: [24, 25, 30, 60])
    func untrackedFractionalHoldMatchesEditor(rate: Int) async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("untracked.mp4")
        try await Self.source(input, rate: rate)
        var doc = Self.document(input)
        doc.videoTrack = [doc.videoTrack[1]]
        doc.videoTrack[0].startTime = 0
        doc.videoTrack[0].centerStage = false
        doc.videoTrack[0].wide = false
        let result = try await StayRenderFixture.renderer(temp.directory.url).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let actual = try await Self.numbers(result.url, folder: temp.directory.url)
        let still = try await TelestratorFrameLoader.load(url: input, time: 1.117, duration: 4, lockTime: true)
        let editor = try Self.number(still.image)
        #expect(actual.count == 12)
        #expect(actual.allSatisfy { $0 == editor })
    }

    @Test(arguments: [24, 25, 30, 60])
    func contactHoldUsesTheHighlightAndFlashFrame(rate: Int) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("contact.mp4")
        try await Self.source(input, rate: rate)
        let contact = 1.117
        var clip = Self.document(input).videoTrack[0]
        clip.duration = 3
        clip.sourceEnd = (clip.sourceStart ?? 0) + 3
        clip.centerStage = false
        clip.wide = false
        let pieces = StrikeFreezeRules.pieces(clip, contacts: [contact], hold: 0.4)
        let flashed = StrikeImpactRules.flashed(pieces, contacts: [contact])
        var hold = try #require(flashed.first { $0.hold == true })
        let time = try #require(hold.sourceStart)
        #expect(abs(time - contact) < 1e-9)
        #expect(hold.flashIn != nil)
        #expect(flashed.filter { $0.flashIn != nil }.count == 1)
        let mark = StrikeHighlightRules.Highlight(limb: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)],
            target: CGPoint(x: 0.4, y: 0.4), radius: 0.04, cost: 0,
            limbSide: .left, usesArm: true, attackerOnLeft: true)
        let track = StrikeHighlightRules.Track(keyframes: [.init(time: contact, highlight: mark)],
            contact: contact, aspect: 640.0 / 360)
        let highlightTimes = StrikeHighlightBurn.frameTimes(track, start: time, duration: 0)
        let highlightTime = try #require(highlightTimes.first)
        #expect(abs(highlightTime - time) < 1e-9)
        // Leave the flash on; decode after its fade to inspect the held pose.
        hold.startTime = 0
        var doc = Self.document(input)
        doc.videoTrack = [hold]
        let result = try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let frames = try await Self.numbers(result.url, folder: folder)
        let highlighted = try await TelestratorFrameLoader.load(url: input, time: highlightTime, duration: 4, lockTime: true)
        let expected = try Self.number(highlighted.image)
        #expect(frames.count == 12)
        #expect(frames.suffix(3).allSatisfy { $0 == expected })
    }

}
