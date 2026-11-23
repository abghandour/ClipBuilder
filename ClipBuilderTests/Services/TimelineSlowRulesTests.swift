import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder whole-timeline slow motion")
struct TimelineSlowRulesTests {
    private func document() -> TimelineDocument {
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        first.transIn = "fade"
        first.transOut = "cut"
        var other = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, track: 1, speed: 2)
        other.muted = true
        var document = Fixtures.timelineDocument(clips: [first, other])
        document.trackCount = 2
        document.trackSequential[1] = false
        return document
    }

    private func insert(_ document: TimelineDocument, contacts: [Double] = [2]) throws -> TimelineSlowRules.Result {
        let owner = try #require(document.videoTrack.first).uid
        return try #require(TimelineSlowRules.insert(contacts, owner: owner, strength: .medium, into: document))
    }

    @Test func duplicateClipIDsRejectSlowInsertionAndRemoval() throws {
        var input = document()
        input.videoTrack[1].uid = input.videoTrack[0].uid
        #expect(TimelineSlowRules.insert([2], owner: input.videoTrack[0].uid,
            strength: .medium, into: input) == nil)

        let slowed = try insert(document())
        var invalid = slowed.document
        invalid.videoTrack.append(invalid.videoTrack[0])
        #expect(TimelineSlowRules.removed(group: slowed.groups[0], in: invalid) == nil)
    }

    @Test func unrelatedClipOnlyMovesInTime() throws {
        var input = document()
        let later = Fixtures.timelineClip(sceneID: nil, sourceStart: 20, duration: 2, startTime: 8)
        input.videoTrack.append(later)
        let slowed = try insert(input)
        let shifted = try #require(slowed.document.videoTrack.first { $0.uid == later.uid })
        var expected = later
        expected.startTime += 0.75
        #expect(shifted == expected)
        let restored = try #require(TimelineSlowRules.removed(group: slowed.groups[0], in: slowed.document))
        #expect(restored.videoTrack.first { $0.uid == later.uid } == later)
    }

    @Test(arguments: ["camera", "cameraSource", "drawing", "strike", "volume", "captions"])
    func removalKeepsEditsOnGroupPiecesAndOtherClips(field: String) throws {
        var input = document()
        let later = Fixtures.timelineClip(sceneID: nil, sourceStart: 20, duration: 2, startTime: 8)
        input.videoTrack.append(later)
        let slowed = try insert(input, contacts: [2, 4])
        var edited = slowed.document
        let member = try #require(edited.videoTrack.firstIndex { $0.slowGroup == slowed.groups[0] })
        let other = try #require(edited.videoTrack.firstIndex { $0.uid == later.uid })
        let ids = [edited.videoTrack[member].uid, later.uid]
        for index in [member, other] {
            switch field {
            case "camera":
                edited.videoTrack[index].cameraPath = [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                    .init(t: 0.2, x: 0.2, y: 0.2, w: 0.6, h: 0.6)]
            case "cameraSource": edited.videoTrack[index].cameraPathSource = "inspector-edit"
            case "drawing": edited.videoTrack[index].telestration = .init(time: 1.8, figures: [.init(linger: 1)])
            case "strike":
                edited.videoTrack[index].strikeHighlights = true
                edited.videoTrack[index].strikeHighlightStyle = "solid"
            case "volume": edited.videoTrack[index].volume = 1
            default: edited.videoTrack[index].captions = "top"
            }
        }
        let expected = edited.videoTrack.filter { ids.contains($0.uid) }
        for group in slowed.groups {
            edited = try #require(TimelineSlowRules.removed(group: group, in: edited))
            for before in expected {
                let after = try #require(edited.videoTrack.first { $0.uid == before.uid })
                #expect(after.cameraPath == before.cameraPath)
                #expect(after.cameraPathSource == before.cameraPathSource)
                #expect(after.telestration == before.telestration)
                #expect(after.strikeHighlights == before.strikeHighlights)
                #expect(after.strikeHighlightStyle == before.strikeHighlightStyle)
                #expect(after.volume == before.volume && after.captions == before.captions)
            }
        }
        let shifted = try #require(edited.videoTrack.first { $0.uid == later.uid })
        #expect(abs(shifted.startTime - later.startTime) < 1e-9)
    }

    @Test(arguments: [false, true])
    func imageKeysAfterPauseMatchPauseAloneAfterRemovingSlow(nested: Bool) throws {
        var input = document()
        var image = ImageOverlayItem(path: "/tmp/late-keys.png")
        image.startTime = 0; image.endTime = 6
        image.track = [.init(time: 3, xFrac: 0.2, yFrac: 0.3, wFrac: 0.1),
                       .init(time: 5, xFrac: 0.7, yFrac: 0.6, wFrac: 0.2)]
        if nested {
            var block = OverlayBlockItem()
            block.startTime = 0.25; block.duration = 6
            block.composition.images = [image]
            input.overlayBlocks = [block]
        } else { input.imageOverlays = [image] }
        let owner = input.videoTrack[0].uid
        let reference = try #require(TimelinePauseRules.insert([
            .init(time: 0.5, duration: 0.8, owner: owner)
        ], into: input, resolve: { $0 }))
        let slowed = try insert(input)
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: 0.5, duration: 0.8, owner: owner)
        ], into: slowed.document, resolve: { $0 }))
        let restored = try #require(TimelineSlowRules.removed(group: slowed.groups[0], in: paused.document))
        let actualImage = nested ? restored.overlayBlocks[0].composition.images[0] : restored.imageOverlays[0]
        let referenceImage = nested ? reference.document.overlayBlocks[0].composition.images[0]
            : reference.document.imageOverlays[0]
        let actual = try #require(actualImage.track)
        let expected = try #require(referenceImage.track)
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(abs(a.time - b.time) < 1e-9)
            #expect(a.xFrac == b.xFrac && a.yFrac == b.yFrac && a.wFrac == b.wFrac)
        }
        #expect(abs(actual[0].time - 3.8) < 1e-9)
        #expect(abs(actualImage.endTime - referenceImage.endTime) < 1e-9)
    }

    @Test func soundAndMusicKeepNormalPlayback() throws {
        var document = document()
        document.soundTrack = [SoundItem(name: "music", startTime: 0, duration: 6, sourceOffset: 2),
                               SoundItem(name: "cue", startTime: 1.6, duration: 0.3)]
        let result = try insert(document)
        #expect(abs(result.document.soundTrack[0].duration - 6.75) < 1e-9)
        #expect(abs(result.document.soundTrack[0].sourceOffset - 2) < 1e-9)
        #expect(abs(result.document.soundTrack[1].startTime - 1.75) < 1e-9)
        #expect(abs(result.document.soundTrack[1].duration - 0.75) < 1e-9)
        #expect(result.document.soundTrack.map(\.volume) == document.soundTrack.map(\.volume))
    }

    @Test func textWindows() throws {
        var document = document()
        document.textOverlays = [.init(text: "Contact", startTime: 1.6, endTime: 1.9)]
        let text = try insert(document).document.textOverlays[0]
        #expect(abs(text.startTime - 1.75) < 1e-9)
        #expect(abs(text.endTime - 2.5) < 1e-9)
    }

    @Test func imageKeysFollowChangesOfRate() throws {
        var document = document()
        var image = ImageOverlayItem(path: "/tmp/overlay.png")
        image.startTime = 0; image.endTime = 6
        image.track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1),
                       .init(time: 4, xFrac: 0.8, yFrac: 0, wFrac: 0.1)]
        document.imageOverlays = [image]
        let output = try insert(document).document.imageOverlays[0]
        #expect(abs(output.endTime - 6.75) < 1e-9)
        let keys = try #require(output.track)
        #expect(keys.count == 4)
        #expect(abs(try #require(ImageTrackKey.interpolate(keys, at: 2.5)).xFrac - 0.38) < 1e-9)
    }

    @Test func overlayBlockLocalClocksAndOpenEnds() throws {
        var document = document()
        var block = OverlayBlockItem()
        block.startTime = 1; block.duration = 3
        block.composition.texts = [.init(text: "Local", startTime: 0.6, endTime: 0.9)]
        var image = ImageOverlayItem(path: "/tmp/local.png")
        image.startTime = 0.6; image.endTime = 0.9
        image.track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1),
                       .init(time: 2, xFrac: 0.4, yFrac: 0, wFrac: 0.1)]
        block.composition.images = [image]
        document.overlayBlocks = [block]
        let mapped = try insert(document).document.overlayBlocks[0]
        #expect(abs(mapped.duration - 3.75) < 1e-9)
        #expect(abs(mapped.composition.texts[0].startTime - 0.75) < 1e-9)
        #expect(abs(mapped.composition.images[0].endTime - 1.5) < 1e-9)
        let keys = try #require(mapped.composition.images[0].track)
        #expect(abs(try #require(ImageTrackKey.interpolate(keys, at: 1.5)).xFrac - 0.18) < 1e-9)
    }

    @Test func cropWindows() throws {
        var document = document()
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2),
                               .init(layout: .fullScreen, startTime: 2, duration: 4)]
        let blocks = try insert(document).document.cropBlocks
        #expect(abs(blocks[0].duration - 2.75) < 1e-9)
        #expect(abs(blocks[1].startTime - 2.75) < 1e-9)
        #expect(abs(blocks[1].duration - 4) < 1e-9)
    }

    @Test func pausesDrawingsHighlightsAndBumpers() throws {
        var document = document()
        document.videoTrack[0].strikeHighlights = true
        let owner = document.videoTrack[0].uid
        let drawing = Telestration(time: 2, figures: [.init(linger: 1)])
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: 2, duration: 0.8, drawing: drawing, owner: owner)
        ], into: document, resolve: { $0 }))
        var input = paused.document
        var bumper = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 7)
        bumper.bumper = true
        input.videoTrack.append(bumper)
        let result = try insert(input)
        let holds = result.document.videoTrack.filter { $0.hold == true }
        #expect(holds.map(\.pauseGroup) == input.videoTrack.filter { $0.hold == true }.map(\.pauseGroup))
        #expect(holds.allSatisfy { abs($0.startTime - 2.75) < 1e-9 })
        #expect(holds.first?.telestration == drawing)
        #expect(result.document.videoTrack.filter { $0.track == 0 && !$0.bumper }.allSatisfy { $0.strikeHighlights == true })
        #expect(abs(try #require(result.document.videoTrack.first { $0.bumper }).startTime - 7.75) < 1e-9)
    }

    @Test(arguments: [false, true])
    func removeEachContactRestoresExactDocument(reverse: Bool) throws {
        var input = document()
        input.textOverlays = [.init(text: "Fractional", startTime: 1.61, endTime: 4.93)]
        input.soundTrack = [.init(name: "music", startTime: 0.13, duration: 5.71)]
        var image = ImageOverlayItem(path: "/tmp/a.png")
        image.track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1), .init(time: 6, xFrac: 0.8, yFrac: 0, wFrac: 0.1)]
        input.imageOverlays = [image]
        let result = try insert(input, contacts: [2, 4])
        #expect(result.count == 2)
        var restored = result.document
        for group in reverse ? result.groups.reversed().map({ $0 }) : result.groups {
            restored = try #require(TimelineSlowRules.removed(group: group, in: restored))
        }
        #expect(restored == input)
    }

    @Test func slowGroupCodingAndSavedRemoval() throws {
        var input = document()
        input.soundTrack = [.init(name: "music", startTime: 0.13, duration: 5.71)]
        var image = ImageOverlayItem(path: "/tmp/saved.png")
        image.track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1), .init(time: 6, xFrac: 0.8, yFrac: 0, wFrac: 0.1)]
        input.imageOverlays = [image]
        let encoder = JSONEncoder()
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(input.videoTrack[0])) as? [String: Any])
        #expect(plain["slow_group"] == nil)
        let result = try insert(input)
        let slowed = try #require(result.document.videoTrack.first { $0.slowGroup != nil })
        let decodedClip = try JSONDecoder().decode(TimelineClip.self, from: encoder.encode(slowed))
        #expect(decodedClip.slowGroup == slowed.slowGroup && decodedClip.uid == slowed.uid)
        var different = slowed; different.slowGroup = nil
        #expect(different != slowed)
        let reopened = try JSONDecoder().decode(TimelineDocument.self, from: encoder.encode(result.document))
        let removed = try #require(TimelineSlowRules.removed(group: result.groups[0], in: reopened))
        #expect(removed.videoTrack.count == input.videoTrack.count)
        #expect(removed.videoTrack.map(\.uid) == input.videoTrack.map(\.uid))
        #expect(removed.videoTrack.allSatisfy { $0.slowGroup == nil })
        #expect(removed == input)
    }


    @Test func subsequentEditsSurviveRemovingSeveralContacts() throws {
        var input = document()
        input.textOverlays = [.init(text: "Before", startTime: 1.6, endTime: 5)]
        let result = try insert(input, contacts: [2, 4])
        var edited = result.document
        edited.textOverlays[0].text = "Keep this edit"
        edited.videoTrack[0].volume = 1
        for group in result.groups {
            edited = try #require(TimelineSlowRules.removed(group: group, in: edited))
        }
        #expect(edited.textOverlays[0].text == "Keep this edit")
        #expect(edited.videoTrack[0].volume == 1)
        #expect(abs(edited.textOverlays[0].startTime - 1.6) < 1e-9)
    }

    @Test func voiceOverKeepsSourceAnchorAndNormalVoiceSpeed() throws {
        let input = document()
        let output = try insert(input).document
        let cuts = output.videoTrack.filter { $0.track == 0 }.map { clip in
            VoiceOverPlacement.Cut(videoID: 1, sourceStart: clip.sourceStart ?? 0,
                sourceEnd: (clip.sourceStart ?? 0) + clip.sourceSpan, speed: clip.effectiveSpeed,
                reelStart: clip.startTime, reelDuration: clip.duration)
        }
        let take = VoiceTake(id: "voice", projectID: 1, videoID: 1, sourceTime: 1.9,
            reelTime: 1.9, duration: 1.2, file: "voice.m4a")
        let placed = try #require(VoiceOverPlacement.place([take], in: cuts).first)
        #expect(abs(placed.start - 2.5) < 1e-9)
        #expect(abs(placed.end - placed.start - 1.2) < 1e-9)
        #expect(placed.take == take)
    }

    @Test func dubLinesMoveWithStretchAndSpeechIsNotCut() throws {
        var input = document()
        let owner = input.videoTrack[0].uid
        input.dubLines = [DubLine(clipUID: owner, speakerKey: "host", voice: "v", text: "Across",
            sourceStart: 1.5, sourceEnd: 2.5, start: 1.5, duration: 1),
            DubLine(clipUID: owner, speakerKey: "host", voice: "v", text: "Next",
            sourceStart: 3, sourceEnd: 4, start: 3, duration: 1),
            DubLine(clipUID: owner, speakerKey: "host", voice: "v", text: "Inside",
            sourceStart: 1.75, sourceEnd: 2.75, start: 1.75, duration: 1)]
        let output = try insert(input).document
        let stored = try #require(output.dubLines)
        #expect(abs(stored[0].start - 1.5) < 1e-9)
        #expect(abs(stored[1].start - 3.75) < 1e-9)
        let clock = DubRenderWindow.clock(document: output, window: output, scenes: [], camera: "balanced", lower: 0)
        let lines = try #require(DubRenderWindow.lines(output, clock: clock, lower: 0, upper: output.contentEnd))
        #expect(lines.count == 3)
        #expect(abs(stored[2].start - 2.125) < 1e-9)
        #expect(stored.map(\.duration) == input.dubLines?.map(\.duration))
        #expect(abs(lines[0].duration - 1) < 1e-9 && abs(lines[1].duration - 1) < 1e-9)
        #expect(abs(lines[1].start - 3.75) < 1e-9)
        let group = try #require(output.slowMotion?.groups?.first?.id)
        let restored = try #require(TimelineSlowRules.removed(group: group, in: output))
        #expect(restored.dubLines == input.dubLines)
    }
    @Test func userCutInsideSlowGroupSurvivesRemoval() throws {
        let input = document()
        let result = try insert(input)
        var cut = result.document
        let member = try #require(cut.videoTrack.first { $0.slowGroup == result.groups[0] })
        let split = try #require(TimelineSplit.split(in: &cut, uid: member.uid, at: 2, precision: .speech))
        let restored = try #require(TimelineSlowRules.removed(group: result.groups[0], in: cut))
        for id in [split.head, split.tail] {
            let piece = try #require(restored.videoTrack.first { $0.uid == id })
            #expect(piece.slowGroup == nil && abs(piece.effectiveSpeed - 1) < 1e-9)
        }
        #expect(abs(try #require(restored.videoTrack.first { $0.uid == split.tail }).startTime - 1.7) < 1e-9)
        #expect(abs(restored.contentEnd - input.contentEnd) < 1e-9)
    }

    @Test(arguments: [0.5, 2.0], [false, true])
    func removalUsesCurrentPiecesAroundPause(time: Double, removePauseFirst: Bool) throws {
        let input = document()
        let result = try insert(input)
        let owner = try #require(result.document.videoTrack.first {
            $0.track == 0 && $0.startTime < time && time < $0.startTime + $0.duration
        })
        let paused = try #require(TimelinePauseRules.insert([.init(time: time, duration: 0.8, owner: owner.uid)],
            into: result.document, resolve: { $0 }))
        var changed = paused.document
        if removePauseFirst { changed = try #require(TimelinePauseRules.removed(group: paused.holds[0], in: changed)) }
        let restored = try #require(TimelineSlowRules.removed(group: result.groups[0], in: changed))
        #expect(restored.videoTrack.filter { $0.hold != true }.allSatisfy { $0.slowGroup == nil })
        #expect(abs(restored.contentEnd - input.contentEnd - (removePauseFirst ? 0 : 0.8)) < 1e-9)
        if !removePauseFirst {
            let holds = restored.videoTrack.filter { $0.hold == true }
            #expect(holds.count == 2 && holds.allSatisfy { abs($0.duration - 0.8) < 1e-9 })
            #expect(holds.allSatisfy { abs($0.startTime - (time < 1.5 ? time : 1.7)) < 1e-9 })
        }
    }

    @Test func slowThenFreezeMatchesFreezeThenSlowOnEveryTrack() throws {
        let input = document()
        let owner = input.videoTrack[0].uid
        let paused = try #require(TimelinePauseRules.insert([.init(time: 2, duration: 0.8, owner: owner)],
            into: input, resolve: { $0 }))
        let reference = try insert(paused.document).document.videoTrack
        let slowed = try insert(input)
        let slowOwner = try #require(slowed.document.videoTrack.first { $0.track == 0 && $0.slowGroup != nil })
        let actual = try #require(TimelinePauseRules.insert([.init(time: 2.75, duration: 0.8, owner: slowOwner.uid)],
            into: slowed.document, resolve: { $0 })).document.videoTrack
        #expect(actual.count == reference.count)
        for (a, b) in zip(actual, reference) {
            #expect(a.track == b.track && a.hold == b.hold)
            #expect(abs(a.startTime - b.startTime) < 1e-9 && abs(a.duration - b.duration) < 1e-9)
            #expect(abs((a.sourceStart ?? -1) - (b.sourceStart ?? -1)) < 1e-9)
            #expect(abs(a.effectiveSpeed - b.effectiveSpeed) < 1e-9)
            #expect(a.strikeImpactsFrozen == b.strikeImpactsFrozen)
        }
    }

}
