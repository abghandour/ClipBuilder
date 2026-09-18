import CoreVideo
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Visual speech activity")
struct VisualSpeechActivityTests {
    private func frame(width: Int, height: Int, draw: (UnsafeMutablePointer<UInt8>, Int) -> Void) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * rowBytes + x * 4
            p[0] = 40; p[1] = 40; p[2] = 40; p[3] = 255   // dark gray
        } }
        draw(base, rowBytes)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    @Test("a green border inside one cell scores that cell on several edges and not its neighbor")
    func borderScoresItsCell() throws {
        let width = 320, height = 180
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        let buffer = try frame(width: width, height: height) { base, rowBytes in
            // A 2 px green rectangle from (8,8) to (152,172): inside cell 0's
            // 20% edge bands, whose right band spans x 128…160.
            func paint(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
                let p = base + y * rowBytes + x * 4; p[0] = b; p[1] = g; p[2] = r
            }
            for x in 8...152 { for y in [8, 9, 171, 172] { paint(x, y, 30, 220, 40) } }
            for y in 8...172 { for x in [8, 9, 151, 152] { paint(x, y, 30, 220, 40) } }
            // A green shirt in cell 1: a thick block, not a line.
            for x in 200...300 { for y in 60...170 { paint(x, y, 30, 200, 40) } }
        }
        let lit = VisualSpeechActivity.ringHues(buffer, tile: tiles[0])
        let neighbor = VisualSpeechActivity.ringHues(buffer, tile: tiles[1])
        #expect(lit[4] > 0.5 && lit[VisualSpeechActivity.hueBuckets + 4] > 0.5, "\(lit)")
        #expect(neighbor[4] == 0 && neighbor[VisualSpeechActivity.hueBuckets + 4] == 0, "\(neighbor)")
        #expect(lit.indices.filter { $0 != 4 && $0 != VisualSpeechActivity.hueBuckets + 4 }.allSatisfy { lit[$0] == 0 })
    }

    @Test("the highlight hue is the one that lights one moving slot at a time; a constant color is ignored")
    func highlightLearning() {
        let slots = 2, bins = 20, buckets = VisualSpeechActivity.hueBuckets
        var rings = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: buckets * 2), count: bins), count: slots)
        for b in 0..<bins {
            let lit = b < 10 ? 0 : 1
            rings[lit][b][4] = 0.8; rings[lit][b][buckets + 4] = 0.8
            // Slot 0 always carries an orange line (a poster edge).
            rings[0][b][1] = 0.9; rings[0][b][buckets + 1] = 0.9
        }
        let frames = [[Int]](repeating: [Int](repeating: 1, count: bins), count: slots)
        let highlight = VisualSpeechActivity.highlightShares(rings: rings, frames: frames)
        #expect(highlight.count == 2)
        #expect(highlight[0].prefix(10).allSatisfy { $0 == 1 } && highlight[0].suffix(10).allSatisfy { $0 == 0 })
        #expect(highlight[1].prefix(10).allSatisfy { $0 == 0 } && highlight[1].suffix(10).allSatisfy { $0 == 1 })
        #expect(VisualSpeechActivity.lastHighlightHue == 4)
        // Nothing moving: no highlight.
        var still = rings
        for b in 0..<bins { still[0][b][4] = 0.8; still[0][b][buckets + 4] = 0.8; still[1][b][4] = 0; still[1][b][buckets + 4] = 0 }
        #expect(VisualSpeechActivity.highlightShares(rings: still, frames: frames).isEmpty)
    }
}

@Suite("Speaker tracker")
struct SpeakerTrackerTests {
    @Test("turns follow the highlighted slot and a one-bin flicker does not switch the speaker")
    func followsHighlight() {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "guest")]
        let bins = 40
        var highlight = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2)
        for b in 0..<bins { highlight[b < 20 ? 0 : 1][b] = 1 }
        highlight[0][10] = 0; highlight[1][10] = 1   // a flicker
        let activity = VisualSpeechActivity.Activity(binSeconds: 0.25,
            motion: [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2), highlight: highlight)
        let outcome = SpeakerTracker.track(.init(audioWindows: [], activity: activity, speech: [0...10],
                                                 tiles: tiles, duration: 10), videoID: 7)
        #expect(outcome.turns.count == 2, "\(outcome.turns.map { ($0.start, $0.end, $0.tile) })")
        #expect(outcome.turns.first?.tile == 0 && outcome.turns.first?.personKey == "host" && outcome.turns.first?.start == 0)
        #expect(outcome.turns.last?.tile == 1 && outcome.turns.last?.personKey == "guest")
        #expect(abs((outcome.turns.first?.end ?? 0) - 5) < 0.3)
        #expect(outcome.turns.allSatisfy { $0.videoID == 7 && $0.confidence > 0.9 })
    }

    @Test("mouth motion decides without a highlight and silence splits turns")
    func mouthsAndSilence() {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        let bins = 40
        var motion = [[Double]](repeating: [Double](repeating: 0.2, count: bins), count: 2)
        for b in 0..<bins { motion[b < 20 ? 0 : 1][b] = 3 }
        let activity = VisualSpeechActivity.Activity(binSeconds: 0.25, motion: motion)
        let outcome = SpeakerTracker.track(.init(audioWindows: [], activity: activity, speech: [0...4, 6...10],
                                                 tiles: tiles, duration: 10), videoID: 1)
        #expect(outcome.turns.map(\.tile) == [0, 1])
        #expect(outcome.turns.map { $0.start } == [0, 6])
    }

    @Test("the smoothed path pays to switch")
    func viterbi() {
        let path = SpeakerTracker.viterbi(scores: [[1, 0], [0.9, 1.0], [1, 0]], active: [true, true, true])
        #expect(path == [0, 0, 0])
        let real = SpeakerTracker.viterbi(scores: [[1, 0], [0, 1], [0, 1], [0, 1]], active: [true, true, true, true])
        #expect(real == [0, 1, 1, 1])
        #expect(SpeakerTracker.viterbi(scores: [[1, 0], [1, 0]], active: [true, false]) == [0, -1])
    }

    @Test("long lit stretches teach each tile its voice; a well-separated profile is trusted, a muddled one is not")
    func enrollmentFromBorder() {
        // Two tiles; 0.25 s bins over 20 s. Tile 0 lit alone for 0–8 s, tile 1 for 10–18 s.
        let binSeconds = 0.25
        let bins = 80
        let highlight: [[Double]] = [(0..<bins).map { $0 < 32 ? 1.0 : 0.0 }, (0..<bins).map { $0 >= 40 && $0 < 72 ? 1.0 : 0.0 }]
        let speech = [Bool](repeating: true, count: bins)
        // Voice windows of 1 s: tile 0's voice near +1, tile 1's near -1.
        func window(_ start: Double, _ value: Double) -> SpeakerFeatures.Window {
            SpeakerFeatures.Window(start: start, end: start + 1, vector: [value, value * 0.5, -value])
        }
        var windows: [SpeakerFeatures.Window] = []
        for i in 0..<8 { windows.append(window(Double(i), 1.0 + Double(i % 3) * 0.05)) }
        for i in 10..<18 { windows.append(window(Double(i), -1.0 - Double(i % 3) * 0.05)) }
        let vectors = SpeakerClustering.standardize(windows.map(\.vector))
        let enrollment = try! #require(SpeakerTracker.enroll(windows: windows, vectors: vectors, highlight: highlight,
                                                              speech: speech, binSeconds: binSeconds, slots: 2))
        #expect(enrollment.slotCount == 2)
        #expect(enrollment.windowsPerSlot == [0: 8, 1: 8])
        #expect(enrollment.separation > 1.8 && enrollment.trust == 1)
        // A window that sounds like tile 0 is placed on tile 0.
        let voice = SpeakerTracker.slotPosterior(vectors[0], enrollment: enrollment, slots: 2)
        #expect(voice[0] > 0.9 && voice[1] < 0.1)

        // Muddled voices: both tiles sound alike → low separation, no trust.
        var alike: [SpeakerFeatures.Window] = []
        for i in 0..<8 { alike.append(window(Double(i), Double(i % 4) * 0.5 - 0.75)) }
        for i in 10..<18 { alike.append(window(Double(i), Double(i % 4) * 0.5 - 0.75)) }
        let muddled = try! #require(SpeakerTracker.enroll(windows: alike, vectors: SpeakerClustering.standardize(alike.map(\.vector)),
                                                          highlight: highlight, speech: speech, binSeconds: binSeconds, slots: 2))
        #expect(muddled.separation < 0.8 && muddled.trust == 0)

        // A stretch shorter than four seconds teaches nothing.
        let brief: [[Double]] = [(0..<bins).map { $0 < 12 ? 1.0 : 0.0 }, (0..<bins).map { $0 >= 40 && $0 < 72 ? 1.0 : 0.0 }]
        #expect(SpeakerTracker.enroll(windows: windows, vectors: vectors, highlight: brief, speech: speech,
                                      binSeconds: binSeconds, slots: 2) == nil)
    }

    /// Two tiles over 0.25 s bins: tile 0 lit alone for 0–8 s and 18–26 s,
    /// tile 1 for 10–18 s; a two-second border hop to tile 1 at 20–22 s.
    /// One-second voice windows: tile 0's voice near +1, tile 1's near −1.
    private func hopFixture(hopVoice: Double) -> SpeakerTracker.Input {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "host"),
                     PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1, personKey: "guest")]
        let bins = 104
        var highlight = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2)
        for b in 0..<bins {
            let seconds = Double(b) * 0.25
            let hop = seconds >= 20 && seconds < 22
            if seconds < 8 || (seconds >= 18 && !hop) { highlight[0][b] = 1 }
            if (seconds >= 10 && seconds < 18) || hop { highlight[1][b] = 1 }
        }
        func window(_ start: Double, _ value: Double) -> SpeakerFeatures.Window {
            SpeakerFeatures.Window(start: start, end: start + 1, vector: [value, value * 0.5, -value])
        }
        var windows: [SpeakerFeatures.Window] = []
        for i in 0..<8 { windows.append(window(Double(i), 1.0 + Double(i % 3) * 0.05)) }
        for i in 10..<18 { windows.append(window(Double(i), -1.0 - Double(i % 3) * 0.05)) }
        for i in 18..<26 {
            let hop = i >= 20 && i < 22
            windows.append(window(Double(i), (hop ? hopVoice : 1.0) + Double(i % 3) * 0.05))
        }
        let activity = VisualSpeechActivity.Activity(binSeconds: 0.25,
            motion: [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2), highlight: highlight)
        return .init(audioWindows: windows, activity: activity, speech: [0...26], tiles: tiles, duration: 26)
    }

    @Test("a trusted voice holds the speaker through a border hop to another tile; a real handover still switches")
    func trustedVoiceHoldsThroughBorderHop() {
        let reaction = SpeakerTracker.track(hopFixture(hopVoice: 1.0), videoID: 1)
        #expect(reaction.enrollment?.trust == 1)
        #expect(reaction.turns.map(\.tile) == [0, 1, 0], "\(reaction.turns.map { ($0.start, $0.end, $0.tile) })")
        #expect(reaction.disagreement.bins == 8 && reaction.disagreement.followedAudio == 8)
        #expect(reaction.turns.last?.end == 26)
        // With the voice trusted, confidence is the voice's support for the chosen tile.
        // (The middle turn spans the unvoiced 8–10 s gap, so its support is lower.)
        #expect(reaction.turns.allSatisfy { $0.confidence > 0.7 }, "\(reaction.turns.map(\.confidence))")

        let handover = SpeakerTracker.track(hopFixture(hopVoice: -1.0), videoID: 1)
        #expect(handover.turns.map(\.tile) == [0, 1, 0, 1, 0], "\(handover.turns.map { ($0.start, $0.end, $0.tile) })")
        #expect(handover.disagreement.bins == 0)
    }

    @Test("rows attributed by hand teach the tiles their voices without any border")
    func correctionsTeachVoices() {
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1), PodcastTile(index: 1, x: 0.5, y: 0, w: 0.5, h: 1)]
        let bins = 72
        func window(_ start: Double, _ value: Double) -> SpeakerFeatures.Window {
            SpeakerFeatures.Window(start: start, end: start + 1, vector: [value, value * 0.5, -value])
        }
        var windows: [SpeakerFeatures.Window] = []
        for i in 0..<8 { windows.append(window(Double(i), 1.0 + Double(i % 3) * 0.05)) }
        for i in 10..<18 { windows.append(window(Double(i), -1.0 - Double(i % 3) * 0.05)) }
        let activity = VisualSpeechActivity.Activity(binSeconds: 0.25,
            motion: [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2))
        var input = SpeakerTracker.Input(audioWindows: windows, activity: activity, speech: [0...18], tiles: tiles, duration: 18)
        #expect(SpeakerTracker.track(input, videoID: 1).enrollment == nil)
        input.corrections = [.init(range: 0...8, slot: 0), .init(range: 10...18, slot: 1)]
        let outcome = SpeakerTracker.track(input, videoID: 1)
        let enrollment = try! #require(outcome.enrollment)
        #expect(enrollment.slotCount == 2 && enrollment.trust == 1)
        #expect(enrollment.correctionWindows == 16)
        #expect(outcome.turns.map(\.tile) == [0, 1], "\(outcome.turns.map { ($0.start, $0.end, $0.tile) })")
    }
}
