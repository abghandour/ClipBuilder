import Testing

@testable import Clip_Builder

@Suite("Smart Sampling")
struct SmartSamplingTests {
    @Test("Coarse windows tile the file and a short tail joins its predecessor")
    func coarseWindows() {
        #expect(SmartSampling.coarseWindows(duration: 0).isEmpty)
        let short = SmartSampling.coarseWindows(duration: 200)
        #expect(short.count == 1 && short[0].start == 0 && short[0].end == 200)
        let hour = SmartSampling.coarseWindows(duration: 3600)
        #expect(hour.count == 12)
        #expect(hour.last?.end == 3600)
        let tail = SmartSampling.coarseWindows(duration: 620)
        #expect(tail.count == 2)
        #expect(tail[1].start == 300 && tail[1].end == 620)
        let twelveHours = SmartSampling.coarseWindows(duration: 12 * 3600)
        #expect(twelveHours.count == SmartSampling.maxCoarseWindows)
        #expect(abs((twelveHours.last?.end ?? 0) - 43200.0) < 0.001)
    }

    @Test("Coarse timestamps are 15 s apart inside the window")
    func coarseTimestamps() {
        let times = SmartSampling.coarseTimestamps(window: (300, 600))
        #expect(times.first == 300.5)
        #expect(times.count == 20)
        #expect(times.allSatisfy { $0 >= 300 && $0 < 600 })
        #expect(SmartSampling.coarseTimestamps(window: (10, 10.4)) == [10.2])
    }

    @Test("Applies only to long, untrimmed, still-frame runs without a custom interval")
    func applicability() {
        #expect(SmartSampling.appliesTo(duration: 900, customInterval: nil, trimmed: false, nativeVideo: false))
        #expect(!SmartSampling.appliesTo(duration: 120, customInterval: nil, trimmed: false, nativeVideo: false))
        #expect(!SmartSampling.appliesTo(duration: 900, customInterval: 2, trimmed: false, nativeVideo: false))
        #expect(!SmartSampling.appliesTo(duration: 900, customInterval: nil, trimmed: true, nativeVideo: false))
        #expect(!SmartSampling.appliesTo(duration: 900, customInterval: nil, trimmed: false, nativeVideo: true))
    }

    @Test("Merging drops incoming ranges an existing same-tag range already covers")
    func merge() {
        let existing: [String: [SmartSampling.Range]] = ["striking": [(10, 20)]]
        let merged = SmartSampling.merge(
            existing: existing,
            incoming: ["striking": [(12, 19), (30, 40), (18, 28)], "cage": [(0, 5)]])
        #expect(merged["striking"]?.count == 3)
        #expect(merged["striking"]?.contains { $0.start == 12 } == false)
        #expect(merged["striking"]?.contains { $0.start == 18 } == true)
        #expect(merged["cage"]?.count == 1)
    }

    @Test("Dense windows come from action tags, busy windows and cut rate, never for talk formats")
    func denseWindows() {
        let tags: [String: [SmartSampling.Range]] = [
            "striking": [(100, 130), (131, 150)], "cage": [(0, 600)], "grappling": [(400, 403)],
        ]
        let activity: [(window: SmartSampling.Range, score: Double)] = [
            ((0, 300), 2), ((300, 600), 8), ((600, 900), 1),
        ]
        let cuts = (0..<60).map { 600 + Double($0) * 5 }  // 12 cuts/min in the last window
        let windows = SmartSampling.denseWindows(tagRanges: tags, activity: activity, cuts: cuts, type: .fight)
        // 100–150 merges (gap 1 s ≤ 2 s) into one ≤60 s window; 300–600 and
        // 600–900 merge and chunk into 60 s pieces; the 3 s grapple is dropped.
        #expect(windows.first?.start == 100 && windows.first?.end == 150)
        #expect(windows.filter { $0.start >= 300 }.count == 10)
        #expect(windows.allSatisfy { $0.end - $0.start <= SmartSampling.maxDenseWindow + 0.001 })
        #expect(SmartSampling.denseWindows(tagRanges: tags, activity: activity, cuts: cuts, type: .podcast).isEmpty)
        #expect(SmartSampling.denseWindows(tagRanges: tags, activity: activity, cuts: cuts, type: .interview).isEmpty)
        let quiet = SmartSampling.denseWindows(tagRanges: ["cage": [(0, 600)]], activity: [((0, 300), 1)], cuts: [], type: nil)
        #expect(quiet.isEmpty)
        let extra = SmartSampling.denseWindows(tagRanges: ["drills": [(0, 20)]], activity: [], cuts: [], type: .training, extraTags: ["drills"])
        #expect(extra.count == 1)
    }

    @Test("Manual breakdown windows union with automatic ones instead of duplicating them")
    func manualUnion() {
        let tags: [String: [SmartSampling.Range]] = ["striking": [(100, 130)]]
        let windows = SmartSampling.denseWindows(
            tagRanges: tags, activity: [((0, 300), 9)], cuts: [], type: .fight, manual: [(0, 300)])
        // 0–300 (manual) already covers the busy window and the strike: five 60 s chunks, nothing more.
        #expect(windows.count == 5)
        #expect(windows.first?.start == 0 && windows.last?.end == 300)
        // Talk formats keep only what the user asked for.
        let talk = SmartSampling.denseWindows(
            tagRanges: tags, activity: [((0, 300), 9)], cuts: [], type: .interview, manual: [(400, 430)])
        #expect(talk.count == 1 && talk[0].start == 400)
        #expect(SmartSampling.denseWindows(tagRanges: [:], activity: [], cuts: [], type: .fight, manual: [(0, 3)]).isEmpty)
    }

    @Test("The dense pass is capped and keeps asked-for and busy footage first")
    func denseCap() {
        // 100 busy 5-minute windows → 500 chunks before the cap.
        let activity = (0..<100).map { i -> (window: SmartSampling.Range, score: Double) in
            ((Double(i) * 300, Double(i + 1) * 300), i == 50 ? 10 : 8)
        }
        let tags: [String: [SmartSampling.Range]] = ["striking": [(29_000, 29_040)]]
        let windows = SmartSampling.denseWindows(tagRanges: tags, activity: activity, cuts: [], type: .fight)
        #expect(windows.count == SmartSampling.maxDenseWindows)
        #expect(windows.contains { $0.start < 29_040 && 29_000 < $0.end }, "the tagged strike survives the cap")
        #expect(windows.contains { $0.start >= 15_000 && $0.end <= 15_300 }, "the busiest window survives the cap")
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test("Chunking splits evenly so no chunk is a sliver")
    func chunking() {
        let chunks = SmartSampling.chunk([(0, 130)], maximum: 60)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { abs(($0.end - $0.start) - 130.0 / 3) < 0.001 })
        #expect(SmartSampling.chunk([(0, 60)], maximum: 60).count == 1)
    }
}
