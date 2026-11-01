import Foundation
import Testing
@testable import Clip_Builder

@Suite("Timeline: applying cleanup cuts")
struct TimelineCleanupCutsTests {
    private let videos: [String: Int64] = ["/a.mp4": 1, "/b.mp4": 2]

    private func clip(_ file: String, source: Double, duration: Double, at start: Double,
                      track: Int = 0, speed: Double? = nil) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: source, duration: duration,
                                         startTime: start, track: track, speed: speed)
        clip.videoFile = file
        return clip
    }

    private func resolve(_ clip: TimelineClip) -> TimelineDocument.CutSource? {
        guard let file = clip.videoFile, let id = videos[file], let start = clip.sourceStart else { return nil }
        return .init(videoID: id, sourceStart: start)
    }

    @Test("a cut splits the clip and later clips move up")
    func splitAndRipple() {
        let first = clip("/a.mp4", source: 10, duration: 10, at: 0)
        let second = clip("/b.mp4", source: 0, duration: 5, at: 10)
        let document = Fixtures.timelineDocument(clips: [first, second])
            .applyingCuts([12...13], videoID: 1, resolve: resolve)
        let track = document.videoTrack
        #expect(track.count == 3)
        #expect(track[0].uid == first.uid)
        #expect(track[0].sourceStart == 10 && track[0].sourceEnd == 12)
        #expect(abs(track[0].duration - 2) < 1e-9 && track[0].startTime == 0)
        #expect(track[1].sourceStart == 13 && track[1].sourceEnd == 20)
        #expect(abs(track[1].duration - 7) < 1e-9 && abs(track[1].startTime - 2) < 1e-9)
        #expect(track[1].originKey == first.originKey, "pieces keep the clip's origin")
        #expect(track[2].uid == second.uid)
        #expect(abs(track[2].startTime - 9) < 1e-9, "the next clip abuts the last piece")
        #expect(track[2].sourceStart == 0 && track[2].duration == 5)
    }

    @Test("pieces shorter than 0.1 s are dropped")
    func dropsTinyPieces() {
        let only = clip("/a.mp4", source: 10, duration: 10, at: 0)
        let track = Fixtures.timelineDocument(clips: [only])
            .applyingCuts([10.05...19], videoID: 1, resolve: resolve).videoTrack
        #expect(track.count == 1)
        #expect(track[0].sourceStart == 19 && track[0].sourceEnd == 20)
        #expect(track[0].startTime == 0 && abs(track[0].duration - 1) < 1e-9)
    }

    @Test("clips of other videos keep their source")
    func otherVideosUntouched() {
        let other = clip("/b.mp4", source: 10, duration: 10, at: 0)
        let document = Fixtures.timelineDocument(clips: [other])
        #expect(document.applyingCuts([12...13], videoID: 1, resolve: resolve) == document)
        #expect(document.cutCount([12...13], videoID: 1, resolve: resolve) == 0)
        #expect(document.cutCount([12...13], videoID: 2, resolve: resolve) == 1)
    }

    @Test("a sped-up clip shrinks by the cut over its speed")
    func speedScalesPieces() {
        let fast = clip("/a.mp4", source: 0, duration: 5, at: 0, speed: 2)
        let track = Fixtures.timelineDocument(clips: [fast])
            .applyingCuts([4...6], videoID: 1, resolve: resolve).videoTrack
        #expect(track.count == 2)
        #expect(abs(track[0].duration - 2) < 1e-9)
        #expect(abs(track[1].startTime - 2) < 1e-9 && abs(track[1].duration - 2) < 1e-9)
    }

    @Test("B-roll and other-track clips shift by the removed time before them")
    func otherClipsShift() {
        let main = clip("/a.mp4", source: 0, duration: 10, at: 0)
        var broll = clip("/b.mp4", source: 0, duration: 2, at: 8, track: 0)
        broll.role = .cutaway
        let upper = clip("/b.mp4", source: 50, duration: 3, at: 6, track: 1)
        let early = clip("/b.mp4", source: 30, duration: 1, at: 0.5, track: 1)
        let track = Fixtures.timelineDocument(clips: [main, broll, early, upper])
            .applyingCuts([2...4], videoID: 1, resolve: resolve).videoTrack
        let movedBroll = track.first { $0.uid == broll.uid }
        #expect(abs((movedBroll?.startTime ?? -1) - 6) < 1e-9)
        #expect(movedBroll?.duration == 2 && movedBroll?.sourceStart == 0)
        let movedUpper = track.first { $0.uid == upper.uid }
        #expect(abs((movedUpper?.startTime ?? -1) - 4) < 1e-9)
        #expect(movedUpper?.duration == 3 && movedUpper?.sourceStart == 50)
        #expect(track.first { $0.uid == early.uid }?.startTime == 0.5, "a clip before the cut stays")
    }

    @Test("other-track clips overlapping a cut are trimmed by the overlap")
    func otherClipsTrimmed() {
        let main = clip("/a.mp4", source: 0, duration: 10, at: 0)
        // Spans the removed 2..4 in the middle: loses 2 s from its tail.
        let spanning = clip("/b.mp4", source: 20, duration: 4, at: 1, track: 1)
        // Starts inside the removed stretch: loses its head.
        let headCut = clip("/b.mp4", source: 40, duration: 3, at: 3, track: 2)
        // Wholly inside the removed stretch: dropped.
        let inside = clip("/b.mp4", source: 60, duration: 1, at: 2.5, track: 3)
        let track = Fixtures.timelineDocument(clips: [main, spanning, headCut, inside])
            .applyingCuts([2...4], videoID: 1, resolve: resolve).videoTrack
        let a = track.first { $0.uid == spanning.uid }
        #expect(a?.startTime == 1 && abs((a?.duration ?? 0) - 2) < 1e-9)
        #expect(a?.sourceStart == 20 && abs((a?.sourceEnd ?? 0) - 22) < 1e-9)
        let b = track.first { $0.uid == headCut.uid }
        #expect(abs((b?.startTime ?? -1) - 2) < 1e-9 && abs((b?.duration ?? 0) - 2) < 1e-9)
        #expect(abs((b?.sourceStart ?? 0) - 41) < 1e-9 && abs((b?.sourceEnd ?? 0) - 43) < 1e-9)
        #expect(!track.contains { $0.uid == inside.uid })
    }

    @Test("overlays, music and crop blocks ripple with the footage")
    func overlaysRipple() {
        let main = clip("/a.mp4", source: 0, duration: 10, at: 0)
        var document = Fixtures.timelineDocument(clips: [main])
        let after = TextOverlayItem(text: "after", startTime: 5, endTime: 7)
        let spanning = TextOverlayItem(text: "spans", startTime: 1, endTime: 5)
        let inside = TextOverlayItem(text: "inside", startTime: 2.2, endTime: 3.8)
        document.textOverlays = [after, spanning, inside]
        let image = ImageOverlayItem(path: "/x.png", startTime: 3, endTime: 6)
        document.imageOverlays = [image]
        let song = SoundItem(name: "song", startTime: 3, duration: 7)
        document.soundTrack = [song]
        let crop = CropBlockItem(layout: .fullScreen, startTime: 4, duration: 6)
        document.cropBlocks = [crop]
        let cut = document.applyingCuts([2...4], videoID: 1, resolve: resolve)
        let movedAfter = cut.textOverlays.first { $0.uid == after.uid }
        #expect(movedAfter.map { abs($0.startTime - 3) < 1e-9 && abs($0.endTime - 5) < 1e-9 } == true)
        let movedSpan = cut.textOverlays.first { $0.uid == spanning.uid }
        #expect(movedSpan.map { $0.startTime == 1 && abs($0.endTime - 3) < 1e-9 } == true)
        #expect(!cut.textOverlays.contains { $0.uid == inside.uid }, "an overlay inside the cut is dropped")
        let movedImage = cut.imageOverlays.first { $0.uid == image.uid }
        #expect(movedImage.map { abs($0.startTime - 2) < 1e-9 && abs($0.endTime - 4) < 1e-9 } == true)
        let movedSong = cut.soundTrack.first
        #expect(movedSong.map { abs($0.startTime - 2) < 1e-9 && abs($0.duration - 6) < 1e-9 } == true)
        #expect(movedSong.map { abs($0.sourceOffset - 1) < 1e-9 } == true, "a front-trimmed song continues")
        let movedCrop = cut.cropBlocks.first
        #expect(movedCrop.map { abs($0.startTime - 2) < 1e-9 && abs($0.duration - 6) < 1e-9 } == true)
    }
}
