import Foundation
import Testing
@testable import Clip_Builder

/// The fast preview shows one picture at a time, so B-roll replaces the
/// picture — but the dialogue underneath must keep playing, on an audio
/// source of its own.
@MainActor
@Suite("Fast preview: B-roll", .serialized)
struct TimelinePreviewCutawayTests {
    private func main(file: String, start: Double, duration: Double,
                      track: Int = 0, volume: Int = 5) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: duration,
                                         startTime: start, track: track)
        clip.videoFile = file
        clip.volume = volume
        return clip
    }

    private func cutaway(file: String, start: Double, duration: Double, track: Int = 0,
                         coverAll: Bool = false, audio: CutawayAudio = .muted,
                         volume: Int = 5) -> TimelineClip {
        var clip = main(file: file, start: start, duration: duration, track: track, volume: volume)
        clip.role = .cutaway
        clip.coverAllAreas = coverAll
        clip.cutawayAudio = audio
        clip.enforceCutawayRules()
        return clip
    }

    private func model(_ clips: [TimelineClip]) throws -> BuilderTimelineModel {
        let model = BuilderTimelineModel()
        var document = Fixtures.timelineDocument(clips: clips)
        document.trackCount = 2
        model.loadDocument(document)
        return model
    }

    private func segment(_ plan: [PreviewSegment], at time: Double) throws -> PreviewSegment {
        try #require(plan.first {
            $0.timelineStart <= time + 0.001 && time < $0.timelineStart + $0.duration - 0.001
        })
    }

    @Test("ranking: bumper, then cover-all B-roll, then a track's B-roll, then the higher track")
    func rankingKey() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let bumper = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 1).clip(at: 6))
        let model = try model([
            main(file: "/tmp/low.mp4", start: 0, duration: 8, track: 0),
            main(file: "/tmp/high.mp4", start: 0, duration: 8, track: 1),
            cutaway(file: "/tmp/broll0.mp4", start: 1, duration: 1, track: 0),
            cutaway(file: "/tmp/broll1.mp4", start: 2, duration: 1, track: 1),
            cutaway(file: "/tmp/cover.mp4", start: 3, duration: 4, track: 0, coverAll: true),
            bumper,
        ])
        let plan = model.previewPlan(musicLookup: [:]).segments
        #expect(try segment(plan, at: 0.5).url.lastPathComponent == "high.mp4",
                "no B-roll: the higher track wins, as before")
        #expect(try segment(plan, at: 1.5).url.lastPathComponent == "high.mp4",
                "a track's B-roll does not beat a higher track's main clip")
        #expect(try segment(plan, at: 2.5).url.lastPathComponent == "broll1.mp4",
                "B-roll beats the main clip of its own track")
        #expect(try segment(plan, at: 4).url.lastPathComponent == "cover.mp4",
                "cover-all B-roll beats every non-bumper")
        #expect(try segment(plan, at: 6.5).url.lastPathComponent == "bumper.mp4",
                "a bumper still owns the picture")
    }

    @Test("the dialogue under a muted cutaway keeps playing on its own audio source")
    func dialogueUnderMutedCutaway() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model([
            main(file: "/tmp/talking.mp4", start: 0, duration: 8, volume: 4),
            cutaway(file: "/tmp/broll.mp4", start: 2, duration: 3),
        ])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = try segment(plan, at: 3)
        #expect(covered.url.lastPathComponent == "broll.mp4")
        #expect(covered.volume == 0, "the B-roll itself is silent")
        let dialogue = try #require(covered.audio)
        #expect(dialogue.url.lastPathComponent == "talking.mp4")
        #expect(dialogue.volume == 4.0 / 5.0)
        #expect(dialogue.sourceStart == 2, "the dialogue continues from its own source time")
        #expect(dialogue.speed == 1)
        #expect(covered.cutawayAudio == nil)

        let after = try segment(plan, at: 6)
        #expect(after.url.lastPathComponent == "talking.mp4" && after.audio == nil)
    }

    @Test("a mixed cutaway keeps the dialogue and adds its own sound on a second source")
    func mixedCutawayAddsItsOwnSound() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model([
            main(file: "/tmp/talking.mp4", start: 0, duration: 8),
            cutaway(file: "/tmp/broll.mp4", start: 2, duration: 3, audio: .mixed, volume: 3),
        ])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = try segment(plan, at: 3)
        #expect(covered.volume == 0, "the picture track never carries a cutaway's own sound")
        #expect(covered.audio?.url.lastPathComponent == "talking.mp4")
        let own = try #require(covered.cutawayAudio)
        #expect(own.url.lastPathComponent == "broll.mp4")
        #expect(own.volume == 3.0 / 5.0)
        #expect(own.sourceStart == 0, "its own trim, from the start of the B-roll")
    }

    @Test("a cut in the dialogue under one continuous cutaway is never merged away")
    func dialogueCutSplitsTheSegment() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model([
            main(file: "/tmp/first.mp4", start: 0, duration: 4),
            main(file: "/tmp/second.mp4", start: 4, duration: 4),
            cutaway(file: "/tmp/broll.mp4", start: 1, duration: 6),
        ])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = plan.filter { $0.url.lastPathComponent == "broll.mp4" }
        #expect(covered.count == 2, "one picture, two dialogue sources")
        #expect(covered.map { $0.audio?.url.lastPathComponent } == ["first.mp4", "second.mp4"])
        #expect(covered.map(\.timelineStart) == [1, 4])
        #expect(covered.map(\.duration) == [3, 3])
        #expect(covered[0].sourceStart == 0 && covered[1].sourceStart == 3,
                "the B-roll's own picture runs on without a break")
    }

    @Test("the last tie-break matches the renderer: later in the document draws on top")
    func documentOrderTieBreakMatchesExport() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var lower = cutaway(file: "/tmp/first.mp4", start: 0, duration: 4)
        var upper = cutaway(file: "/tmp/second.mp4", start: 0, duration: 4)
        // Same layer, same start, same origin: only the document order is
        // left to decide, and the later entry must win in both places.
        lower.originKey = "same"
        upper.originKey = "same"
        let model = try model([main(file: "/tmp/under.mp4", start: 0, duration: 4), lower, upper])
        #expect(try segment(model.previewPlan(musicLookup: [:]).segments, at: 2)
                .url.lastPathComponent == "second.mp4")

        let resolved = MultitrackRenderer.resolveClips(document: model.document, scenes: [])
        let renderSegment = try #require(MultitrackRenderer.buildLayeredSegments(resolved).first)
        let placements = MultitrackRenderer.placements(for: renderSegment)
        #expect(placements.last?.sourcePath == "/tmp/second.mp4", "the renderer agrees")
    }

    @Test("a cutaway with no source at all does not take the dialogue with it")
    func missingPictureFallsBackToTheClipBelow() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDirectory()
        let present = temp.url.appendingPathComponent("talking.mp4")
        try Data("video".utf8).write(to: present)

        var broken = cutaway(file: present.path, start: 1, duration: 2)
        broken.videoFile = nil
        broken.sceneID = nil
        let model = try model([main(file: present.path, start: 0, duration: 6), broken])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = try segment(plan, at: 2)
        #expect(covered.url == present, "the clip underneath keeps the picture and its own sound")
        #expect(covered.volume > 0)
    }

    @Test("a cutaway whose file has been deleted hands the picture back down")
    func missingFileFallsBackToTheClipBelow() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDirectory()
        // The clip underneath is on disk; the B-roll's file is not.
        let present = temp.url.appendingPathComponent("talking.mp4")
        try Data("video".utf8).write(to: present)
        let gone = temp.url.appendingPathComponent("deleted.mp4")

        var broll = cutaway(file: gone.path, start: 1, duration: 2)
        broll.sceneID = nil
        let model = try model([main(file: present.path, start: 0, duration: 6), broll])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = try segment(plan, at: 2)
        #expect(covered.url == present, "the missing picture falls back to the clip below")
        #expect(covered.volume > 0 && covered.audio == nil,
                "and that clip's own sound is what plays")
    }

    @Test("a bumper with a missing file still owns its span")
    func missingBumperKeepsItsBlackSpan() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDirectory()
        let present = temp.url.appendingPathComponent("talking.mp4")
        try Data("video".utf8).write(to: present)
        let bumper = try #require(BumperAsset(path: temp.url.appendingPathComponent("gone.mp4").path,
                                              displayName: "CTA", duration: 2).clip(at: 2))
        let model = try model([main(file: present.path, start: 0, duration: 6), bumper])
        let plan = model.previewPlan(musicLookup: [:]).segments
        let covered = try segment(plan, at: 3)
        #expect(covered.bumper, "the bumper keeps the span even with no file")
        #expect(covered.url.lastPathComponent == "gone.mp4")
        #expect(try segment(plan, at: 1).url == present, "and the footage resumes after it")
    }

    @Test("Drive footage that is not local yet keeps its picture")
    func driveBackedFootageIsNotTreatedAsMissing() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let temp = try TempDirectory()
        let present = temp.url.appendingPathComponent("talking.mp4")
        try Data("video".utf8).write(to: present)
        // Not on disk, but the Library knows it is fetched on demand.
        let remote = temp.url.appendingPathComponent("drive-broll.mp4")

        var broll = cutaway(file: remote.path, start: 1, duration: 2)
        broll.sceneID = nil
        let model = try model([main(file: present.path, start: 0, duration: 6), broll])
        #expect(try segment(model.previewPlan(musicLookup: [:]).segments, at: 2).url == present,
                "with nothing known about it, a missing file falls back")

        model.updateDriveBackedPaths([remote.path])
        let covered = try segment(model.previewPlan(musicLookup: [:]).segments, at: 2)
        #expect(covered.url == remote, "a Drive-backed source keeps the picture")
        #expect(covered.audio?.url == present, "and the dialogue underneath still plays")
    }

    @Test("a muted track under a cutaway contributes no dialogue")
    func mutedTrackHasNoDialogue() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model([
            main(file: "/tmp/talking.mp4", start: 0, duration: 8),
            cutaway(file: "/tmp/broll.mp4", start: 2, duration: 3),
        ])
        model.document.trackSettings[0].muted = true
        let plan = model.previewPlan(musicLookup: [:]).segments
        #expect(try segment(plan, at: 3).audio == nil)
    }
}
