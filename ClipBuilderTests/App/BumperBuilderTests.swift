import Foundation
import Testing
@testable import Clip_Builder

/// Bumpers live on the cropping row and are the timeline's top priority:
/// nothing moves for them, and nothing under them is shown or heard.
@MainActor
@Suite("Builder bumpers", .serialized)
struct BumperBuilderTests {
    @Test("adding a bumper moves nothing; it covers the footage under it and leaves the tracks")
    func addCoversInsteadOfPushing() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)]))
        model.playhead = 4
        model.addBumper(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2))
        let bumper = try #require(model.document.videoTrack.first(where: { $0.bumper }))
        #expect(bumper.startTime == 4 && bumper.duration == 2)

        let footage = try #require(model.document.videoTrack.first(where: { !$0.bumper }))
        #expect(footage.startTime == 0 && footage.duration == 10, "the clip stays put and keeps its length")
        #expect(model.document.bumperSpans == [4..<6])
        #expect(model.document.bumperCoverage(of: footage) == [4..<6])
        #expect(model.document.isCoveredByBumper(footage))

        let layout = model.timelineLayout()
        #expect(layout.bumpers.map(\.uid) == [bumper.uid])
        #expect(layout.videoTracks[0].clips.map(\.uid) == [footage.uid], "bumpers are not track clips")
        #expect(model.clips(inTrack: 0).map(\.uid) == [footage.uid])
    }

    @Test("moving a bumper only changes its time, and removing it reveals the footage")
    func moveAndRemove() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)]))
        model.addBumper(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2), at: 4)
        let bumper = try #require(model.document.videoTrack.first(where: { $0.bumper }))

        model.placeClip(bumper.uid, startTime: 1, track: 3)
        let moved = try #require(model.clip(bumper.uid))
        #expect(moved.startTime == 1 && moved.track == 0, "a bumper never lands on a track")
        #expect(model.document.videoTrack.first(where: { !$0.bumper })?.startTime == 0)

        model.placeClip(bumper.uid, startTime: -3, track: 0)
        #expect(model.clip(bumper.uid)?.startTime == 0)

        model.updateClip(bumper.uid) {
            $0.wide = true
            $0.centerStage = true
            $0.captions = "top"
            $0.cropXFrac = 0.2
            $0.track = 2
        }
        let edited = try #require(model.clip(bumper.uid))
        #expect(!edited.wide && !edited.centerStage && edited.captions == "none" && edited.cropXFrac == nil)
        #expect(edited.track == 0)

        model.removeClip(bumper.uid)
        #expect(model.document.bumperSpans.isEmpty)
        let footage = try #require(model.document.videoTrack.first)
        #expect(!model.document.isCoveredByBumper(footage))
    }

    @Test("sequential packing ignores bumpers entirely")
    func sequentialPackingIgnoresBumpers() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 3))
        model.loadDocument(Fixtures.timelineDocument(clips: [
            Fixtures.timelineClip(duration: 4), bumper, Fixtures.timelineClip(duration: 4),
        ]))
        model.resolveLayout(track: 0)
        let starts = model.document.videoTrack.filter { !$0.bumper }.map(\.startTime).sorted()
        #expect(starts == [0, 4], "clips pack end to end as if the bumper were not there")
        #expect(model.clip(bumper.uid)?.startTime == 3)
    }

    @Test("music goes silent under bumpers in the fast preview")
    func previewMutesMusicUnderBumpers() throws {
        let scope = try DataFolderOverride()
        _ = scope
        // An explicit lookup keeps this test off the shared music catalog,
        // which other suites reset under a different data folder.
        let model = BuilderTimelineModel()
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10), bumper])
        document.soundTrack = [SoundItem(name: "Bed", volume: 3, startTime: 1, duration: 8)]
        model.loadDocument(document)

        let plan = model.previewPlan(musicLookup: ["Bed": URL(fileURLWithPath: "/music/Bed.mp3")])
        #expect(plan.music.map { $0.timelineStart..<($0.timelineStart + $0.duration) } == [1..<4, 6..<9])
        let top = try #require(plan.segments.first(where: { $0.bumper }))
        #expect(top.timelineStart == 4 && top.duration == 2, "the bumper wins the picture")
    }

    @Test("coverage is empty for clips entirely before or after a bumper")
    func coverageOutsideBumper() throws {
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        let before = Fixtures.timelineClip(duration: 3)
        var after = Fixtures.timelineClip(duration: 3)
        after.startTime = 8
        var touching = Fixtures.timelineClip(duration: 4)
        touching.startTime = 0
        var overlapping = Fixtures.timelineClip(duration: 4)
        overlapping.startTime = 5
        let document = Fixtures.timelineDocument(clips: [bumper, before, after, touching, overlapping])
        #expect(document.bumperCoverage(of: before).isEmpty)
        #expect(document.bumperCoverage(of: after).isEmpty)
        #expect(document.bumperCoverage(of: touching).isEmpty, "ending exactly where the bumper starts is not covered")
        #expect(document.bumperCoverage(of: overlapping) == [5..<6])
        #expect(!document.isCoveredByBumper(after) && document.isCoveredByBumper(overlapping))
    }

    @Test("coverage never forms an inverted range for zero- or negative-duration clips under a bumper")
    func coverageDegenerateClips() throws {
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        var empty = Fixtures.timelineClip(duration: 0)
        empty.startTime = 5
        var negative = Fixtures.timelineClip(duration: -3)
        negative.startTime = 5
        var negativeAcross = Fixtures.timelineClip(duration: -10)
        negativeAcross.startTime = 20
        let document = Fixtures.timelineDocument(clips: [bumper, empty, negative, negativeAcross])
        #expect(document.bumperCoverage(of: empty).isEmpty)
        #expect(document.bumperCoverage(of: negative).isEmpty, "a clip that ends before it starts is not covered")
        #expect(document.bumperCoverage(of: negativeAcross).isEmpty)
        #expect(!document.isCoveredByBumper(negative))
    }

    @Test("time-span subtraction cuts, splits, and drops slivers")
    func spanSubtraction() {
        #expect(TimelineDocument.subtracting([4..<6], from: 0..<10) == [0..<4, 6..<10])
        #expect(TimelineDocument.subtracting([0..<3], from: 0..<10) == [3..<10])
        #expect(TimelineDocument.subtracting([2..<12], from: 0..<10) == [0..<2])
        #expect(TimelineDocument.subtracting([0..<10], from: 0..<10).isEmpty)
        #expect(TimelineDocument.subtracting([20..<30], from: 0..<10) == [0..<10])
        #expect(TimelineDocument.subtracting([1..<2, 3..<4], from: 0..<5) == [0..<1, 2..<3, 4..<5])
        #expect(TimelineDocument.subtracting([0.005..<10], from: 0..<10).isEmpty, "a 5 ms sliver is dropped")
    }

    @Test("pause mode opens a gap on add, closes it on delete, and follows the bumper when moved")
    func pauseMode() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)])
        document.soundTrack = [SoundItem(name: "Bed", volume: 3, startTime: 0, duration: 10)]
        model.loadDocument(document)
        model.addBumper(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2), at: 4, mode: .pause)
        let bumper = try #require(model.document.videoTrack.first(where: { $0.bumper }))
        #expect(bumper.bumperMode == .pause && bumper.startTime == 4)

        func footage() -> [(Double, Double)] {
            model.document.videoTrack.filter { !$0.bumper }
                .sorted { $0.startTime < $1.startTime }.map { ($0.startTime, $0.duration) }
        }
        #expect(footage().map(\.0) == [0, 6] && footage().map(\.1) == [4, 6], "the clip is split around the gap")
        #expect(model.document.soundTrack.first?.duration == 12, "a playing sound continues across the gap")
        #expect(model.document.isCoveredByBumper(model.document.videoTrack.first(where: { !$0.bumper })!) == false)

        // Move later: the gap closes at 4 and reopens where it lands (drop
        // point 9 on the gapped timeline = 7 on the closed one).
        model.placeClip(bumper.uid, startTime: 9, track: 0)
        #expect(model.clip(bumper.uid)?.startTime == 7)
        // The old gap closed (tail back to 4..10), then the tail was split
        // again at 7: [0,4) [4,7) gap [9,12).
        #expect(footage().map(\.0) == [0, 4, 9] && footage().map(\.1) == [4, 3, 3])
        #expect(model.document.soundTrack.first?.duration == 12)

        // Back to overlap: the gap closes, nothing is covered by a move.
        model.setBumperMode(bumper.uid, mode: .overlap)
        #expect(model.clip(bumper.uid)?.bumperMode == .overlap)
        #expect(model.document.videoTrack.filter { !$0.bumper }.map(\.startTime).sorted() == [0, 4, 7])
        #expect(model.document.soundTrack.first?.duration == 10)
        #expect(model.document.isCoveredByBumper(model.document.videoTrack.first(where: { $0.startTime == 7 && !$0.bumper })!))

        // And to pause again, then delete: the gap opens and closes.
        model.setBumperMode(bumper.uid, mode: .pause)
        #expect(model.document.videoTrack.filter { !$0.bumper }.map(\.startTime).sorted() == [0, 4, 9])
        model.removeClip(bumper.uid)
        #expect(model.document.videoTrack.filter(\.bumper).isEmpty)
        #expect(model.document.videoTrack.map(\.startTime).sorted() == [0, 4, 7])
        #expect(model.document.soundTrack.first?.duration == 10)
    }

    @Test("two bumpers never overlap: adding, moving, duplicating, and trimming all keep them apart")
    func noOverlap() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 20)]))
        let asset = BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2)
        model.addBumper(asset, at: 4)
        model.addBumper(asset, at: 5)
        var bumpers = model.document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        #expect(bumpers.map(\.startTime) == [4, 6], "the second slides to just after the first")

        model.placeClip(bumpers[1].uid, startTime: 3, track: 0)
        bumpers = model.document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        #expect(bumpers.map(\.startTime) == [4, 6], "a move onto the first bumper slides after it")

        model.placeClip(bumpers[1].uid, startTime: 10, track: 0)
        // Pretend the bumper file is long enough to trim out to.
        model.updateClip(bumpers[0].uid) { $0.sourceEnd = 12 }
        model.trimClip(bumpers[0].uid, duration: 9)
        #expect(model.clip(bumpers[0].uid)?.duration == 6, "an overlapping bumper stops at the next bumper")

        model.duplicateClip(bumpers[0].uid)
        let all = model.document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        #expect(all.map(\.startTime) == [4, 10, 12], "the duplicate lands after the bumper at 10")

        // Switching the first to pause opens its 6 s gap: later bumpers
        // move with everything else. Trimming it longer pushes them again.
        model.setBumperMode(all[0].uid, mode: .pause)
        #expect(model.document.videoTrack.filter(\.bumper).map(\.startTime).sorted() == [4, 16, 18])
        model.trimClip(all[0].uid, duration: 8)
        let pushed = model.document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        #expect(pushed.map(\.startTime) == [4, 18, 20] && pushed[0].duration == 8)

        // A bumper never grows past its own file.
        model.trimClip(all[0].uid, duration: 30)
        #expect(model.clip(all[0].uid)?.duration == 12)
    }

    @Test("review fixes: off-grid lengths terminate, packing splits around a pause, nudges advance, tiny files cap")
    func reviewFindings() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 20)]))

        // 1: a 2.1 s bumper ends at 6.1; the next one lands at 6.5, not in a hang.
        let odd = BumperAsset(path: "/odd.mp4", displayName: "Odd", duration: 2.1)
        model.addBumper(odd, at: 4)
        model.addBumper(odd, at: 4)
        #expect(model.document.videoTrack.filter(\.bumper).map(\.startTime).sorted() == [4, 6.5])
        for bumper in model.document.videoTrack.filter(\.bumper) { model.removeClip(bumper.uid) }

        // 2: trimming the head piece shorter must not slide the tail under a pausing bumper.
        model.addBumper(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2), at: 4, mode: .pause)
        let head = try #require(model.document.videoTrack.first { !$0.bumper && $0.startTime == 0 })
        model.trimClip(head.uid, duration: 3)
        let pieces = model.document.videoTrack.filter { !$0.bumper }.sorted { $0.startTime < $1.startTime }
        #expect(pieces.map(\.startTime) == [0, 3, 6] && pieces.map(\.duration) == [3, 1, 15])
        for piece in pieces { #expect(!model.document.isCoveredByBumper(piece)) }

        // 6: a relative nudge advances a pausing bumper and its gap.
        let pause = try #require(model.document.videoTrack.first { $0.bumper })
        model.nudgeBumper(pause.uid, by: 0.5)
        #expect(model.clip(pause.uid)?.startTime == 4.5)
        let nudged = model.document.videoTrack.filter { !$0.bumper }.sorted { $0.startTime < $1.startTime }
        #expect(nudged.allSatisfy { !model.document.isCoveredByBumper($0) })
        #expect(nudged.map(\.startTime).contains(6.5))
        model.nudgeBumper(pause.uid, by: -0.5)
        #expect(model.clip(pause.uid)?.startTime == 4)

        // 8: a 0.2 s file cannot be trimmed out to the half-second minimum.
        model.addBumper(BumperAsset(path: "/tiny.mp4", displayName: "Tiny", duration: 0.2), at: 15)
        let tiny = try #require(model.document.videoTrack.first { $0.bumper && $0.bumperName == "Tiny" })
        model.trimClip(tiny.uid, duration: 1)
        #expect(abs((model.clip(tiny.uid)?.duration ?? 0) - 0.2) < 0.001)
    }

    @Test("music pieces after a bumper keep their place in the song; bad durations are skipped")
    func musicOffsets() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10), bumper])
        document.soundTrack = [SoundItem(name: "Bed", volume: 3, startTime: 1, duration: 8),
                               SoundItem(name: "Bed", volume: 3, startTime: 4, duration: -1)]
        model.loadDocument(document)
        let plan = model.previewPlan(musicLookup: ["Bed": URL(fileURLWithPath: "/music/Bed.mp3")])
        #expect(plan.music.map(\.timelineStart) == [1, 6])
        #expect(plan.music.map(\.sourceOffset) == [0, 5], "the second piece resumes at song second 5")
    }

    @Test("loading normalizes overlapping bumpers even without scenes, moving a pause gap along")
    func loadNormalization() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        var cover = try #require(BumperAsset(path: "/a.mp4", displayName: "A", duration: 4).clip(at: 3))
        cover.bumperMode = .overlap
        var pause = try #require(BumperAsset(path: "/b.mp4", displayName: "B", duration: 2).clip(at: 4))
        pause.bumperMode = .pause
        // Footage already split around the pause gap at 4..6.
        var headPiece = Fixtures.timelineClip(sceneID: nil, duration: 4)
        headPiece.videoFile = "/footage.mp4"
        var tailPiece = Fixtures.timelineClip(sceneID: nil, duration: 6)
        tailPiece.videoFile = "/footage.mp4"
        tailPiece.startTime = 6
        model.loadDocument(Fixtures.timelineDocument(clips: [cover, pause, headPiece, tailPiece]))

        let bumpers = model.document.videoTrack.filter(\.bumper).sorted { $0.startTime < $1.startTime }
        #expect(bumpers.map(\.startTime) == [3, 7], "the pause bumper slides after the covering one")
        let footage = model.document.videoTrack.filter { !$0.bumper }.sorted { $0.startTime < $1.startTime }
        #expect(footage.map(\.startTime) == [0, 4, 9] && footage.map(\.duration) == [4, 3, 3],
                "its gap closed at 4 and reopened at 7")
    }

    @Test("a crop block that would be split into a sliver stretches across the gap and restores exactly")
    func cropSliverSurvivesGap() throws {
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)])
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 5)]
        BumperPlanner.insertGap(in: &document, at: 4.8, duration: 1.2)
        #expect(document.cropBlocks.count == 1)
        #expect(document.cropBlocks.first?.startTime == 0 && abs((document.cropBlocks.first?.duration ?? 0) - 6.2) < 0.001)
        BumperPlanner.removeGap(in: &document, at: 4.8, duration: 1.2)
        let restored = try #require(document.cropBlocks.first { !$0.layout.isFullScreen })
        #expect(restored.startTime == 0 && abs(restored.duration - 5) < 0.001)
    }

    @Test("the bumper mode round-trips through JSON and defaults to overlap")
    func modeCoding() throws {
        var bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        bumper.bumperMode = .pause
        var document = Fixtures.timelineDocument(clips: [bumper])
        let data = try JSONEncoder().encode(document)
        #expect(String(decoding: data, as: UTF8.self).contains("\"bumper_mode\":\"pause\""))
        document = try JSONDecoder().decode(TimelineDocument.self, from: data)
        #expect(document.videoTrack.first?.bumperMode == .pause)

        // A document written before the mode existed has no key at all.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var clips = try #require(object["video_track"] as? [[String: Any]] ?? object["videoTrack"] as? [[String: Any]])
        clips[0].removeValue(forKey: "bumper_mode")
        object[object["video_track"] != nil ? "video_track" : "videoTrack"] = clips
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: legacy)
        #expect(decoded.videoTrack.first?.bumperMode == .overlap)
    }

    @Test("gap removal is the inverse of gap insertion on every lane")
    func removeGapInverts() throws {
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 10)])
        document.soundTrack = [SoundItem(name: "Bed", volume: 3, startTime: 1, duration: 6)]
        document.textOverlays = [TextOverlayItem(text: "Hi", startTime: 2, endTime: 8)]
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 10)]
        let original = document
        BumperPlanner.insertGap(in: &document, at: 4, duration: 2)
        #expect(document.soundTrack.first?.duration == 8)
        #expect(document.textOverlays.first?.endTime == 10)
        BumperPlanner.removeGap(in: &document, at: 4, duration: 2)
        #expect(document.videoTrack.map(\.startTime).sorted() == [0, 4], "split pieces stay, adjacent")
        #expect(document.videoTrack.map(\.duration).sorted() == [4, 6])
        #expect(document.soundTrack.first?.startTime == 1 && document.soundTrack.first?.duration == 6)
        #expect(document.textOverlays.first?.startTime == 2 && document.textOverlays.first?.endTime == 8)
        #expect(document.cropBlocks.map(\.layout.isFullScreen) == [true])
        #expect(original.videoTrack.map(\.duration).reduce(0, +) == document.videoTrack.map(\.duration).reduce(0, +))
    }

    @Test("fast preview chooses bumper above other tracks and maps speed")
    func fastPreview() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        var bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        bumper.speed = 0.5
        bumper.duration = 4
        model.loadDocument(Fixtures.timelineDocument(clips: [bumper,
            Fixtures.timelineClip(duration: 10, track: 1)]))
        let plan = model.previewPlan()
        let middle = try #require(plan.segments.first(where: { $0.bumper }))
        #expect(middle.url.path == "/bumper.mp4" && middle.timelineStart == 4)
        #expect(middle.duration == 4 && middle.speed == 0.5 && middle.sourceStart == 0)
    }
}
