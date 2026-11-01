import Foundation
import Testing
@testable import Clip_Builder

struct HookVariantBuilderTests {
    /// Three back-to-back clips: scenes 1 (4 s from source 10), 2 (3 s from
    /// source 20), 3 (5 s from source 30), starting at 0.
    private func base(overlays: [TextOverlayItem] = []) -> TimelineDocument {
        var document = Fixtures.timelineDocument(clips: [
            Fixtures.timelineClip(sceneID: 1, sourceStart: 10, duration: 4, startTime: 0),
            Fixtures.timelineClip(sceneID: 2, sourceStart: 20, duration: 3, startTime: 4),
            Fixtures.timelineClip(sceneID: 3, sourceStart: 30, duration: 5, startTime: 7),
        ])
        document.textOverlays = overlays
        return document
    }

    private func overlay(_ text: String, start: Double, end: Double) -> TextOverlayItem {
        var item = TextOverlayItem()
        item.text = text
        item.startTime = start
        item.endTime = end
        return item
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

    @Test func firstClipIsAColdOpenFromTheScenesFootage() throws {
        let original = base()
        let alternative = HookAlternative(label: "Knockdown first", mode: .firstClip, sceneID: 3)
        let variant = try #require(HookVariantBuilder.variants(base: original, alternatives: [alternative]).first)
        #expect(variant.label == "Knockdown first")
        let clips = HookVariantBuilder.openingTrack(variant.document)
        // A new 3 s clip of scene 3's footage replaces the opener; the body is untouched.
        #expect(clips.map(\.sceneID) == [3, 2, 3])
        let opener = try #require(clips.first)
        let source = HookVariantBuilder.openingTrack(original)[2]
        #expect(opener.uid != source.uid)
        #expect(opener.originKey != source.originKey)
        #expect(opener.videoFile == source.videoFile)
        #expect(opener.sourceStart == 30)
        #expect(opener.duration == HookVariantBuilder.maxColdOpenDuration)
        #expect(opener.sourceEnd.map { close($0, 33) } == true)
        #expect(clips.map(\.startTime) == [0, 3, 6])
    }

    @Test func bodyIsEqualAcrossVariantsApartFromAConstantShift() {
        let original = base(overlays: [overlay("Old hook", start: 0, end: 2), overlay("Body text", start: 8, end: 9)])
        let alternatives = [
            HookAlternative(label: "Scene 2 first", mode: .firstClip, sceneID: 2),
            HookAlternative(label: "Scene 3 first", mode: .firstClip, sceneID: 3),
            HookAlternative(label: "New text", mode: .openingText, overlayText: "Watch this"),
        ]
        let variants = HookVariantBuilder.variants(base: original, alternatives: alternatives)
        #expect(variants.count == 3)
        let baseBody = Array(HookVariantBuilder.openingTrack(original).dropFirst())
        for variant in variants {
            let body = Array(HookVariantBuilder.openingTrack(variant.document).dropFirst())
            #expect(body.count == baseBody.count)
            #expect(body.map(\.sceneID) == baseBody.map(\.sceneID))
            #expect(body.map(\.sourceStart) == baseBody.map(\.sourceStart))
            #expect(body.map(\.sourceEnd) == baseBody.map(\.sourceEnd))
            #expect(body.map(\.duration) == baseBody.map(\.duration))
            #expect(body.map(\.uid) == baseBody.map(\.uid))
            guard let first = body.first, let baseFirst = baseBody.first else { continue }
            let shift = first.startTime - baseFirst.startTime
            #expect(zip(body, baseBody).allSatisfy { close($0.startTime - $1.startTime, shift) })
            // Body text moves with the body.
            let bodyText = variant.document.textOverlays.first { $0.text == "Body text" }
            #expect(bodyText.map { close($0.startTime, 8 + shift) } == true)
        }
        // The text variant keeps the footage untouched.
        #expect(variants[2].document.videoTrack == original.videoTrack)
    }

    @Test func coldOpenShiftsMusicWithTheBody() throws {
        var original = base()
        original.soundTrack = [SoundItem(name: "bed", startTime: 0, duration: 12)]
        let document = try #require(HookVariantBuilder.coldOpen(sceneID: 3, in: original))
        let music = try #require(document.soundTrack.first)
        // Opener 4 s -> 3 s: one second of music is trimmed from the head so
        // the song under the body plays where it did.
        #expect(close(music.startTime, 0))
        #expect(close(music.sourceOffset, 1))
        #expect(close(music.duration, 11))
    }

    @Test func documentWithAnotherTrackGetsNoColdOpen() {
        var original = base()
        original.videoTrack.append(Fixtures.timelineClip(sceneID: 4, sourceStart: 40, duration: 4, startTime: 0, track: 1))
        let alternatives = [
            HookAlternative(label: "Scene 3 first", mode: .firstClip, sceneID: 3),
            HookAlternative(label: "New text", mode: .openingText, overlayText: "Watch this"),
        ]
        #expect(!HookVariantBuilder.allowsClipAlternatives(original))
        let variants = HookVariantBuilder.variants(base: original, alternatives: alternatives)
        #expect(variants.map(\.label) == ["New text"])
        let prompt = HookVariantBuilder.prompt(document: original, scenes: [],
                                               allowClipAlternatives: false)
        #expect(prompt.contains("do not propose \"first_clip\""))
        let parsed = HookVariantBuilder.parseAlternatives(
            #"{"alternatives":[{"label":"Cold","mode":"first_clip","scene_id":3}]}"#, document: original)
        #expect(parsed.isEmpty)
    }

    @Test func alternativesThatChangeNothingAreDropped() {
        let alternatives = [
            HookAlternative(label: "Already first", mode: .firstClip, sceneID: 1),
            HookAlternative(label: "Unknown scene", mode: .firstClip, sceneID: 99),
            HookAlternative(label: "Blank", mode: .openingText, overlayText: "  "),
            HookAlternative(label: "Same text", mode: .openingText, overlayText: "Old hook"),
            HookAlternative(label: "Scene 2", mode: .firstClip, sceneID: 2),
            HookAlternative(label: "Scene 2 again", mode: .firstClip, sceneID: 2),
        ]
        let variants = HookVariantBuilder.variants(base: base(overlays: [overlay("Old hook", start: 0.5, end: 2)]),
                                                   alternatives: alternatives)
        #expect(variants.map(\.label) == ["Scene 2"])
    }

    @Test func openingTextReplacesTheEarliestOverlayInTheWindow() throws {
        let original = base(overlays: [overlay("Later", start: 5, end: 7),
                                       overlay("Second", start: 1.5, end: 3),
                                       overlay("First", start: 0.2, end: 2)])
        let document = try #require(HookVariantBuilder.replacingOpeningText("Big moment", in: original))
        #expect(document.textOverlays.map(\.text) == ["Later", "Second", "Big moment"])
        #expect(document.textOverlays[2].startTime == 0.2)
        #expect(document.textOverlays[2].endTime == 2)
    }

    @Test func openingTextSplitsAnOverlayThatOutlastsTheWindow() throws {
        let original = base(overlays: [overlay("Long line", start: 1, end: 6)])
        let document = try #require(HookVariantBuilder.replacingOpeningText("Big moment", in: original, openingWindow: 3))
        #expect(document.textOverlays.map(\.text) == ["Big moment", "Long line"])
        #expect(document.textOverlays[0].startTime == 1)
        #expect(document.textOverlays[0].endTime == 3)
        #expect(document.textOverlays[1].startTime == 3)
        #expect(document.textOverlays[1].endTime == 6)
        #expect(document.textOverlays[0].uid != document.textOverlays[1].uid)
    }

    @Test func openingTextLeavesNameTagsAlone() throws {
        var tag = overlay("Coach Ana", start: 0, end: 2)
        tag.design = "tag"
        var styled = overlay("Fighter", start: 0.5, end: 2)
        styled.tagStyle = TagStyle()
        let original = base(overlays: [tag, styled])
        let document = try #require(HookVariantBuilder.replacingOpeningText("Big moment", in: original))
        #expect(Array(document.textOverlays.dropFirst()) == original.textOverlays)
        #expect(document.textOverlays.first?.text == "Big moment")
        #expect(document.textOverlays.first?.startTime == 0)
    }

    @Test func openingTextInsertsAnOverlayWhenNoneOpens() throws {
        let original = base(overlays: [overlay("Later", start: 5, end: 7)])
        let document = try #require(HookVariantBuilder.replacingOpeningText("Big moment", in: original))
        #expect(document.textOverlays.count == 2)
        let inserted = try #require(document.textOverlays.first)
        #expect(inserted.text == "Big moment")
        #expect(inserted.startTime == 0)
        #expect(inserted.endTime == HookVariantBuilder.insertedTextDuration)
        #expect(document.videoTrack == original.videoTrack)
    }

    @Test func promptListsClipsAndOpeningText() {
        let prompt = HookVariantBuilder.prompt(document: base(overlays: [overlay("Old hook", start: 0, end: 2)]),
                                               scenes: [Fixtures.scene(id: 2)], allowClipAlternatives: true)
        #expect(prompt.contains("1. scene_id 2"))
        #expect(prompt.contains("\"Old hook\""))
        #expect(prompt.contains("\"alternatives\""))
    }

    @Test func parsesASampleResponse() throws {
        let raw = """
            Here you go:
            ```json
            {"alternatives":[
              {"label":"Knockdown first","mode":"first_clip","scene_id":3,"reason":"Biggest moment"},
              {"label":"Question","mode":"opening_text","overlay_text":"Did he see it coming?","reason":"Curiosity"},
              {"label":"Original","mode":"first_clip","scene_id":"2"},
              {"label":"Opener","mode":"first_clip","scene_id":1},
              {"label":"Bad","mode":"zoom"},
              {"label":"Fourth","mode":"opening_text","overlay_text":"Too many"}
            ]}
            ```
            """
        let parsed = HookVariantBuilder.parseAlternatives(raw, document: base())
        #expect(parsed.count == 3)
        #expect(parsed[0] == HookAlternative(label: "Knockdown first", mode: .firstClip, sceneID: 3,
                                             overlayText: nil, reason: "Biggest moment"))
        #expect(parsed[1] == HookAlternative(label: "Question", mode: .openingText, sceneID: nil,
                                             overlayText: "Did he see it coming?", reason: "Curiosity"))
        // "Original" is reserved, a string scene id parses, and scene 1 already opens.
        #expect(parsed[2].label == "Original 2")
        #expect(parsed[2].sceneID == 2)
        // Round trip through Codable (the job result carries these).
        let decoded = try JSONDecoder().decode([HookAlternative].self, from: JSONEncoder().encode(parsed))
        #expect(decoded == parsed)
        let variants = HookVariantBuilder.variants(base: base(), alternatives: parsed)
        #expect(variants.map(\.label) == ["Knockdown first", "Question", "Original 2"])
    }

    @Test func unparseableResponseGivesNoAlternatives() {
        #expect(HookVariantBuilder.parseAlternatives("no json here", document: base()).isEmpty)
        #expect(HookVariantBuilder.parseAlternatives(#"{"other":[]}"#, document: base()).isEmpty)
    }

    @Test func labelledPreferencesRenderAsHookPicks() {
        let hook = PreferenceRecord(id: 1, chosenRationale: "", rejectedRationale: "", createdAt: nil,
                                    chosenLabel: "Question", rejectedLabel: "Original")
        #expect(HookVariantBuilder.preferenceLine(hook) == #"- CHOSE "Question" OVER "Original" hook"#)
        let plain = PreferenceRecord(id: 2, chosenRationale: "fast cuts", rejectedRationale: "slow", createdAt: nil)
        #expect(HookVariantBuilder.preferenceLine(plain) == #"- CHOSE "fast cuts" OVER "slow""#)
    }

    @Test func readoutPutsOriginalFirstAndCountsPicks() {
        var original = Fixtures.generatedVideo(id: 10, batchID: "g")
        original.variantGroupID = "g"
        original.hookLabel = "Original"
        var question = Fixtures.generatedVideo(id: 11, batchID: "g")
        question.variantGroupID = "g"
        question.hookLabel = "Question"
        question.instagramMediaID = "m1"
        question.instagramStats = IGStats(views: 1200, likes: 40)
        let rows = HookVariantBuilder.readout(videos: [question, original],
                                              preferences: [(chosenID: 11, rejectedID: 10), (chosenID: 11, rejectedID: 99)])
        #expect(rows.map(\.label) == ["Original", "Question"])
        #expect(rows.map(\.picks) == [0, 1])
        #expect(rows[0].published == false)
        #expect(rows[1].stats?.views == 1200)
    }
}
