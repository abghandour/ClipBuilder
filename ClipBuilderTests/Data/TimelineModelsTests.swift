import Foundation
import Testing
@testable import Clip_Builder

/// B-roll lives in the timeline document as a clip role. These cover the
/// wire format (the custom coder ignores stored defaults), the invariants
/// `enforceCutawayRules` keeps, and the persisted origin identity the
/// renderer and preview order by.
@Suite("Timeline models: B-roll")
struct TimelineModelsTests {
    private func cutaway(coverAll: Bool = false, audio: CutawayAudio = .muted) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 3, duration: 4, track: 1)
        clip.role = .cutaway
        clip.coverAllAreas = coverAll
        clip.cutawayAudio = audio
        clip.enforceCutawayRules()
        return clip
    }

    private func clips(in data: Data) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["video_track"] as? [[String: Any]])
    }

    @Test("role, cover-all and cutaway audio survive the round trip")
    func rolesRoundTrip() throws {
        let clip = cutaway(coverAll: true, audio: .mixed)
        let data = try JSONEncoder().encode(Fixtures.timelineDocument(clips: [clip]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"role\":\"cutaway\""))
        #expect(json.contains("\"cover_all\":true"))
        #expect(json.contains("\"cutaway_audio\":\"mixed\""))

        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        let restored = try #require(decoded.videoTrack.first)
        #expect(restored.role == .cutaway)
        #expect(restored.coverAllAreas)
        #expect(restored.cutawayAudio == .mixed)
        #expect(restored.originKey == clip.originKey)
        #expect(!restored.muted, "a mixed-in cutaway is not muted")
    }

    @Test("a main clip writes no B-roll keys and absent keys decode to a main clip")
    func absentKeysDecodeToMain() throws {
        let main = Fixtures.timelineClip(sceneID: nil, duration: 4)
        let data = try JSONEncoder().encode(Fixtures.timelineDocument(clips: [main]))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var track = try clips(in: data)
        #expect(track[0]["role"] == nil && track[0]["cover_all"] == nil && track[0]["cutaway_audio"] == nil)

        // A document written before B-roll existed carries no keys at all.
        track[0].removeValue(forKey: "origin")
        object["video_track"] = track
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: legacy)
        let clip = try #require(decoded.videoTrack.first)
        #expect(clip.role == .main && !clip.coverAllAreas && clip.cutawayAudio == .muted)
        #expect(!clip.isCutaway)
        #expect(!clip.originKey.isEmpty, "a missing origin is generated on load")
    }

    @Test("equality sees the role, cover-all, audio and origin")
    func equalityIncludesTheNewFields() {
        let base = cutaway()
        var role = base; role.role = .main
        var cover = base; cover.coverAllAreas = true
        var audio = base; audio.cutawayAudio = .mixed
        var origin = base; origin.originKey = UUID().uuidString
        #expect(base != role && base != cover && base != audio && base != origin)
        #expect(base == base)
    }

    @Test("a bumper is never a cutaway")
    func bumperWinsOverRole() throws {
        var clip = try #require(BumperAsset(path: "/bumper.mp4", displayName: "CTA", duration: 2).clip(at: 4))
        clip.role = .cutaway
        clip.coverAllAreas = true
        clip.cutawayAudio = .mixed
        clip.enforceCutawayRules()
        #expect(clip.role == .main && !clip.isCutaway)
        #expect(!clip.coverAllAreas && clip.cutawayAudio == .muted)
    }

    @Test("cutaway rules drop captions, Center Stage and free crops and follow the audio choice")
    func cutawayRules() {
        var clip = Fixtures.timelineClip(track: 1)
        clip.role = .cutaway
        clip.captions = "bottom"
        clip.centerStage = true
        clip.wide = true
        clip.freeCrops = [FreeCrop(src: FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 1, hFrac: 1),
                                   dst: FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 1, hFrac: 1))]
        clip.screenCrop = "50-50 Horizontal/Top"
        clip.enforceCutawayRules()
        #expect(clip.captions == "none" && !clip.centerStage && clip.freeCrops == nil)
        #expect(clip.muted, "B-roll is silent by default")
        #expect(clip.screenCrop == "50-50 Horizontal/Top", "an area cutaway keeps its area")
        #expect(clip.wide, "an area cutaway may still be a wide clip")

        clip.cutawayAudio = .mixed
        clip.enforceCutawayRules()
        #expect(!clip.muted)

        clip.coverAllAreas = true
        clip.areaWindow = FreeCropRect(xFrac: 0, yFrac: 0, wFrac: 0.5, hFrac: 0.5)
        clip.position = "top"
        clip.enforceCutawayRules()
        #expect(clip.screenCrop == nil && clip.areaWindow == nil && !clip.wide && clip.position == nil)

        // Back to a main clip: cover-all is a cutaway-only idea.
        clip.role = .main
        clip.enforceCutawayRules()
        #expect(!clip.coverAllAreas)
    }

    @Test("a cover-all cutaway is never orphaned; an area cutaway still can be")
    func orphanedCoverAll() {
        var document = Fixtures.timelineDocument(clips: [])
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 10)]
        var area = cutaway()
        area.startTime = 1
        var cover = cutaway(coverAll: true)
        cover.startTime = 1
        #expect(document.isOrphaned(area), "track 1 has no area under Full Screen")
        #expect(!document.isOrphaned(cover))
    }

    @Test("the document separates main clips from cutaways per track")
    func trackHelpers() {
        var first = Fixtures.timelineClip(duration: 4, startTime: 0, track: 1)
        first.enforceCutawayRules()
        var second = Fixtures.timelineClip(duration: 4, startTime: 4, track: 1)
        second.enforceCutawayRules()
        var broll = cutaway()
        broll.startTime = 2
        let other = Fixtures.timelineClip(duration: 4, track: 0)
        let document = Fixtures.timelineDocument(clips: [second, broll, first, other])
        #expect(document.mainClips(inTrack: 1).map(\.startTime) == [0, 4])
        #expect(document.cutaways(inTrack: 1).map(\.uid) == [broll.uid])
        #expect(document.cutaways(inTrack: 0).isEmpty)
    }

    @Test("dissolves round-trip, stay inside the clip, and only exist on B-roll")
    func fadesRoundTrip() throws {
        var clip = cutaway()
        clip.fadeIn = 0.5
        clip.fadeOut = 0.75
        clip.enforceCutawayRules()
        let data = try JSONEncoder().encode(Fixtures.timelineDocument(clips: [clip]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"fade_in\":0.5") && json.contains("\"fade_out\":0.75"))
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        let restored = try #require(decoded.videoTrack.first)
        #expect(restored.fadeIn == 0.5 && restored.fadeOut == 0.75)

        // Never longer than half the clip, and never on a main clip.
        var long = cutaway()
        long.duration = 2
        long.fadeIn = 5
        long.enforceCutawayRules()
        #expect(long.fadeIn == 1)
        var main = long
        main.role = .main
        main.enforceCutawayRules()
        #expect(main.fadeIn == 0 && main.fadeOut == 0)

        var other = clip
        other.fadeIn = 0.25
        #expect(other != clip, "equality sees the dissolve")
    }

    @Test("origin identity: fresh per clip, saved, and shared by a gap split's tail")
    func originIdentity() throws {
        #expect(TimelineClip().originKey != TimelineClip().originKey)

        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: nil, duration: 10)])
        let head = try #require(document.videoTrack.first)
        BumperPlanner.insertGap(in: &document, at: 4, duration: 2)
        #expect(document.videoTrack.count == 2)
        #expect(document.videoTrack.allSatisfy { $0.originKey == head.originKey },
                "both halves of a split clip stay one clip for ordering")
        #expect(Set(document.videoTrack.map(\.uid)).count == 2)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        #expect(decoded.videoTrack.allSatisfy { $0.originKey == head.originKey })
    }
}
