import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder whole-timeline pause rules")
struct TimelinePauseRulesTests {
    @Test func duplicateClipIDsRejectPauseActionsButLaneMappingIsSafe() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let input = Fixtures.timelineDocument(clips: [clip])
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: 2, duration: 0.8, owner: clip.uid)
        ], into: input, resolve: { $0 }))
        var invalid = paused.document
        invalid.videoTrack.append(invalid.videoTrack[0])
        #expect(TimelinePauseRules.insert([.init(time: 1, duration: 0.8, owner: clip.uid)],
            into: invalid, resolve: { $0 }) == nil)
        #expect(TimelinePauseRules.removed(group: paused.holds[0], in: invalid) == nil)
        #expect(TimelinePauseRules.resized(group: paused.holds[0], in: invalid, to: 1) == nil)
        let image = ImageOverlayItem(path: "/tmp/duplicate.png", startTime: 3, endTime: 4)
        invalid.imageOverlays = [image, image]
        TimelineLaneMapping.pause(time: 2, delta: 0.8).apply(to: &invalid)
        #expect(invalid.imageOverlays.count == 2)
        #expect(invalid.imageOverlays.allSatisfy { abs($0.startTime - 3.8) < 1e-9 })
    }

    @Test func pauseRemovalPreservesCameraEdits() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let later = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 2, startTime: 8)
        let input = Fixtures.timelineDocument(clips: [clip, later])
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: 2, duration: 0.8, owner: clip.uid)
        ], into: input, resolve: { $0 }))
        var edited = paused.document
        for i in edited.videoTrack.indices where edited.videoTrack[i].hold != true {
            edited.videoTrack[i].cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.8, h: 0.8),
                                              .init(t: 1, x: 0.1, y: 0.1, w: 0.8, h: 0.8)]
            edited.videoTrack[i].cameraPathSource = "inspector-edit"
        }
        let restored = try #require(TimelinePauseRules.removed(group: paused.holds[0], in: edited))
        for before in edited.videoTrack where before.hold != true {
            let after = try #require(restored.videoTrack.first { $0.uid == before.uid })
            #expect(after.cameraPath == before.cameraPath)
            #expect(after.cameraPathSource == before.cameraPathSource)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0, 3.0, 4.0])
    func everyImageKeyMapsAcrossPause(time: Double) throws {
        let keys = [ImageTrackKey(time: 1, xFrac: 0.2, yFrac: 0.3, wFrac: 0.1),
                    ImageTrackKey(time: 3, xFrac: 0.7, yFrac: 0.6, wFrac: 0.2)]
        let mapping = TimelineLaneMapping.pause(time: time, delta: 0.8)
        let mapped = mapping.imageKeys(keys)
        for key in keys {
            let shifted = try #require(mapped.first { abs($0.time - mapping.point(key.time)) < 1e-9 })
            #expect(shifted.xFrac == key.xFrac && shifted.yFrac == key.yFrac && shifted.wFrac == key.wFrac)
        }
    }

    @Test("Saved zoom and hard-cut knots survive cuts, pauses, removal and rejoining",
          arguments: ["unpaused", "cut", "paused", "removed", "beforeCut", "recut"], [0.5, 1.0, 2.0])
    func savedCutPathRoundTrip(edit: String, speed: Double) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4 / speed, speed: speed)
        let original = [Self.savedRectangle(at: 0), Self.savedRectangle(at: 2.5),
                        Self.savedRectangle(at: 2.99), Self.savedRectangle(at: 3), Self.savedRectangle(at: 4)]
        clip.cameraPath = original
        var pieces = [clip]
        if edit == "cut" {
            let cut = try #require(TimelineSplit.pieces(clip, at: 2 / speed))
            pieces = [cut.head, cut.tail]
        } else if edit != "unpaused" {
            let time = (edit == "beforeCut" ? 2.995 : 2) / speed
            let inserted = try #require(TimelinePauseRules.insert([
                .init(time: time, duration: 0.8, owner: clip.uid)
            ], into: Fixtures.timelineDocument(clips: [clip]), resolve: { $0 }))
            pieces = inserted.document.videoTrack
            if edit == "removed" {
                let group = try #require(inserted.holds.first)
                let removed = try #require(TimelinePauseRules.removed(group: group, in: inserted.document))
                pieces = removed.videoTrack
                #expect(pieces.allSatisfy { $0.hold != true })
            } else if edit == "recut" {
                let cut = try #require(TimelineSplit.pieces(pieces[0], at: 1 / speed))
                pieces.replaceSubrange(0...0, with: [cut.head, cut.tail])
            }
        }
        var rejoined: [CameraPathKeyframe] = []
        for piece in pieces {
            let start = try #require(piece.sourceStart) - 10
            let path = try #require(piece.cameraPath)
            for (index, key) in path.enumerated() {
                var time = start + (piece.hold == true ? 0 : key.t)
                if piece.hold != true, index + 1 < path.count, abs(path[index + 1].t - key.t) < 1e-12 {
                    // A slice inside the cut gap keeps a left-limit hold at
                    // the same time as the right-continuous destination knot.
                    time = time.nextDown
                }
                Self.expectRectangle(key, Self.savedRectangle(at: time))
            }
            // Check between knots too, including the shortened hard-cut gap.
            for step in 0...200 {
                let time = piece.hold == true ? 0 : piece.duration * speed * Double(step) / 200
                let value = try #require(CenterStageService.interpolated(path, at: time))
                Self.expectRectangle(value, Self.savedRectangle(at: start + time))
            }
            if piece.hold != true {
                rejoined += path.map { key in
                    var key = key
                    key.t += start
                    return key
                }
            }
        }
        // Joining restores the same camera, allowing redundant split knots.
        let times = Array(stride(from: 0.0, through: 4.0, by: 0.004)) + [2.99, 2.995, 2.999, 3, 3.001]
        for time in times {
            let value = try #require(CenterStageService.interpolated(rejoined, at: time))
            let expected = try #require(CenterStageService.interpolated(original, at: time))
            Self.expectRectangle(value, expected)
        }
    }

    private nonisolated static func savedRectangle(at time: Double) -> CameraPathKeyframe {
        if time < 3 {
            let fraction = min(1, time / 2.5)
            return .init(t: time, x: 0.1 + 0.2 * fraction, y: 0.05 + 0.15 * fraction,
                         w: 0.8 - 0.4 * fraction, h: 0.8 - 0.4 * fraction)
        }
        let fraction = time - 3
        return .init(t: time, x: 0.2 + 0.05 * fraction, y: 0.1 + 0.05 * fraction,
                     w: 0.6 - 0.1 * fraction, h: 0.6 - 0.1 * fraction)
    }

    private nonisolated static func expectRectangle(_ actual: CameraPathKeyframe, _ expected: CameraPathKeyframe) {
        #expect(abs(actual.x - expected.x) < 1e-9)
        #expect(abs(actual.y - expected.y) < 1e-9)
        #expect(abs(actual.w - expected.w) < 1e-9)
        #expect(abs(actual.h - expected.h) < 1e-9)
    }

    @Test("Production Builder and reel pauses preserve a stored rectangle zoom",
          arguments: [0.5, 1.0, 2.0], [false, true])
    func storedZoomBoundaries(speed: Double, shared: Bool) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4 / speed, speed: speed)
        clip.cameraPath = [.init(t: 0, x: 0.1, y: 0.05, w: 0.8, h: 0.8),
                           .init(t: 4, x: 0.3, y: 0.2, w: 0.4, h: 0.4)]
        let pieces: [TimelineClip]
        if shared {
            let tracks = try #require(StrikeFreezeRules.sharedPieces([[clip]], pauses: [
                .init(time: 1 / speed, duration: 0.8), .init(time: 2 / speed, duration: 0.8)
            ]))
            pieces = tracks.flatMap { $0 }
        } else {
            let result = try #require(TimelinePauseRules.insert([
                .init(time: 1 / speed, duration: 0.8, owner: clip.uid),
                .init(time: 2 / speed, duration: 0.8, owner: clip.uid)
            ], into: Fixtures.timelineDocument(clips: [clip]), resolve: { $0 }))
            pieces = result.document.videoTrack
        }
        #expect(pieces.count == 5)
        for piece in pieces {
            let start = try #require(piece.sourceStart)
            let path = try #require(piece.cameraPath)
            for key in path {
                let time = start - 10 + (piece.hold == true ? 0 : key.t)
                let fraction = time / 4
                let width = 0.8 - fraction * 0.4
                let x = 0.1 + fraction * 0.2
                let y = 0.05 + fraction * 0.15
                #expect(abs(key.w - width) < 1e-9)
                #expect(abs(key.h - width) < 1e-9)
                #expect(abs(key.x - x) < 1e-9)
                #expect(abs(key.y - y) < 1e-9)
            }
        }
    }

    @Test("A companion's end hold samples the rectangle zoom at end minus one millisecond")
    func storedZoomEdgeHold() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, duration: 6)
        var other = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 2.1, track: 1, speed: 2)
        other.cameraPath = [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                            .init(t: 4.2, x: 0.3, y: 0.2, w: 0.4, h: 0.4)]
        let result = try inserted(Fixtures.timelineDocument(clips: [owner, other]), owner: owner.uid)
        let hold = try #require(result.document.videoTrack.first { $0.track == 1 && $0.hold == true })
        let key = try #require(hold.cameraPath?.first)
        let fraction = (4.2 - 0.001) / 4.2
        let expected = 0.8 - fraction * 0.4
        #expect(abs(key.w - expected) < 1e-9)
    }

    private func drawing() -> Telestration {
        Telestration(time: 99, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.7)])], stay: 7)
    }

    private func inserted(_ document: TimelineDocument, owner: UUID, at time: Double = 2,
                          duration: Double = 1) throws -> TimelinePauseRules.Result {
        let result = try #require(TimelinePauseRules.insert([.init(time: time, duration: duration, owner: owner)],
                                                           into: document, resolve: { $0 }))
        try #require(result.holds.count == 1)
        return result
    }

    private func near(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) < 1e-8)
    }

    @Test("Single-track pieces retain the existing speed, source and camera math", arguments: [0.5, 1.0, 2.0])
    func singleTrack(speed: Double) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, speed: speed)
        clip.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.4, h: 1),
                           .init(t: 6 * speed, x: 0.6, y: 0, w: 0.4, h: 1)]
        clip.transIn = "fade"; clip.transOut = "fadeblack"
        let expected = StrikeFreezeRules.pieces(clip, pauses: [.init(time: 10 + 2 * speed, duration: 1)])
        let result = try inserted(Fixtures.timelineDocument(clips: [clip]), owner: clip.uid)
        #expect(result.count == 1 && result.document.videoTrack.count == expected.count)
        for (actual, expected) in zip(result.document.videoTrack, expected) {
            var comparable = actual
            comparable.pauseGroup = nil
            comparable.uid = expected.uid
            #expect(comparable == expected)
            #expect(actual.cameraPath == expected.cameraPath)
            near(try #require(actual.sourceEnd), try #require(expected.sourceEnd))
        }
        let hold = try #require(result.document.videoTrack.first { $0.hold == true })
        #expect(result.holds == [hold.uid] && hold.pauseGroup == hold.uid)
    }

    @Test("Two pictures pause on their own clocks; only the owner gets the drawing", arguments: [false, true])
    func twoTracks(free: Bool) throws {
        var owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, speed: 2)
        owner.strikeImpactsFrozen = true
        var other = Fixtures.timelineClip(sceneID: nil, sourceStart: 40, duration: 6, track: 1, speed: 0.5)
        other.strikeImpactsFrozen = false
        other.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.4, h: 1),
                            .init(t: 3, x: 0.6, y: 0, w: 0.4, h: 1)]
        let later = Fixtures.timelineClip(sceneID: nil, startTime: 9, track: 1)
        var document = Fixtures.timelineDocument(clips: [owner, other, later])
        document.trackSequential[1] = !free
        let note = drawing()
        let result = try #require(TimelinePauseRules.insert([
            .init(time: 2, duration: note.duration, drawing: note, owner: owner.uid)
        ], into: document, resolve: { $0 }))
        try #require(result.holds.count == 1)
        let holds = result.document.videoTrack.filter { $0.hold == true }
        #expect(holds.count == 2 && holds.allSatisfy { $0.pauseGroup == result.holds[0] })
        let main = try #require(holds.first { $0.track == 0 })
        let companion = try #require(holds.first { $0.track == 1 })
        near(try #require(main.sourceStart), 14)
        near(try #require(companion.sourceStart), 41)
        near(try #require(companion.cameraPath?.first).x, 0.2)
        near(try #require(companion.cameraPath?.last).t, note.duration)
        #expect(main.telestration != nil && companion.telestration == nil)
        #expect(result.document.videoTrack.filter { $0.originKey == owner.originKey }.allSatisfy { $0.strikeImpactsFrozen == true })
        #expect(result.document.videoTrack.filter { $0.originKey == other.originKey }.allSatisfy { $0.strikeImpactsFrozen == false })
        for track in [0, 1] {
            let tail = try #require(result.document.videoTrack.first { $0.track == track && $0.startTime > 2 && $0.uid != later.uid })
            near(tail.startTime, 2 + note.duration)
        }
        near(try #require(result.document.videoTrack.first { $0.uid == later.uid }).startTime, 9 + note.duration)
        #expect(result.document.trackSequential == document.trackSequential)
    }

    @Test("Near-edge companions keep the moving clip whole and hold its boundary frame", arguments: [true, false])
    func edge(before: Bool) throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let other = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: before ? 3 : 2.1,
                                          startTime: before ? 1.9 : 0, track: 1, speed: 2)
        let later = Fixtures.timelineClip(sceneID: nil, startTime: other.startTime + other.duration, track: 1)
        let document = Fixtures.timelineDocument(clips: [owner, other, later])
        let result = try inserted(document, owner: owner.uid)
        let held = try #require(result.document.videoTrack.first { $0.track == 1 && $0.hold == true })
        let whole = try #require(result.document.videoTrack.first { $0.uid == other.uid })
        near(held.startTime, before ? 1.9 : 2.1)
        // The last frame shown, not the first instant after the range.
        near(try #require(held.sourceStart), before ? 10 : 14.2 - 0.001)
        near(whole.duration, other.duration)
        near(whole.startTime, other.startTime + (before ? 1 : 0))
        near(try #require(whole.sourceStart), 10)
        #expect(held.pauseGroup == result.holds[0])
        let grown = try #require(TimelinePauseRules.resized(group: result.holds[0], in: result.document, to: 2))
        near(try #require(grown.videoTrack.first { $0.uid == held.uid }).startTime, held.startTime)
        near(try #require(grown.videoTrack.first { $0.uid == later.uid }).startTime, later.startTime + 2)
        let removed = try #require(TimelinePauseRules.removed(group: result.holds[0], in: grown))
        near(try #require(removed.videoTrack.first { $0.uid == other.uid }).startTime, other.startTime)
        near(try #require(removed.videoTrack.first { $0.uid == later.uid }).startTime, later.startTime)
    }

    @Test("An older freeze on screen keeps its drawing and length; the pause's freeze follows it and resizes with the pause")
    func existingHold() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        var old = Fixtures.timelineClip(sceneID: nil, sourceStart: 30, duration: 4, track: 1)
        old.hold = true; old.sourceEnd = 30; old.telestration = drawing(); old.pauseGroup = old.uid
        let later = Fixtures.timelineClip(sceneID: nil, startTime: 4, track: 1)
        let result = try inserted(Fixtures.timelineDocument(clips: [owner, old, later]), owner: owner.uid)
        #expect(result.document.videoTrack.first { $0.uid == old.uid } == old)
        let companion = try #require(result.document.videoTrack.first { $0.track == 1 && $0.pauseGroup == result.holds[0] })
        near(companion.startTime, 4)
        near(try #require(companion.sourceStart), 30)
        #expect(companion.telestration == nil && companion.uid != old.uid)
        let resized = try #require(TimelinePauseRules.resized(group: result.holds[0], in: result.document, to: 2))
        #expect(resized.videoTrack.first { $0.uid == old.uid } == old)
        near(try #require(resized.videoTrack.first { $0.uid == later.uid }).startTime, 6)
        let removed = try #require(TimelinePauseRules.removed(group: result.holds[0], in: resized))
        #expect(removed.videoTrack.first { $0.uid == old.uid } == old)
        near(try #require(removed.videoTrack.first { $0.uid == later.uid }).startTime, 4)
        // An unrelated freeze placed later over the pause's moment is left alone.
        var extra = Fixtures.timelineClip(sceneID: nil, sourceStart: 50, duration: 2, startTime: 1, track: 2)
        extra.hold = true; extra.sourceEnd = 50
        var with = result.document
        with.videoTrack.append(extra)
        let closed = try #require(TimelinePauseRules.removed(group: result.holds[0], in: with))
        #expect(closed.videoTrack.first { $0.uid == extra.uid } == extra)
    }

    @Test("Tracking keys at the pause keep their place; growing and shrinking a pause leaves the path alone; a short bumper split is noticed")
    func keysAndShortSplit() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 8)
        var document = Fixtures.timelineDocument(clips: [owner])
        var image = ImageOverlayItem(path: "/tmp/image.png"); image.startTime = 0; image.endTime = 8
        image.track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.2), .init(time: 2, xFrac: 1, yFrac: 0, wFrac: 0.2),
                       .init(time: 6, xFrac: 0, yFrac: 0, wFrac: 0.2)]
        document.imageOverlays = [image]
        let result = try inserted(document, owner: owner.uid)
        var keys = try #require(result.document.imageOverlays.first?.track)
        #expect(keys.map(\.time) == [0, 2, 3, 7] && keys.map(\.xFrac) == [0, 1, 1, 0])
        let grown = try #require(TimelinePauseRules.resized(group: result.holds[0], in: result.document, to: 3))
        let back = try #require(TimelinePauseRules.resized(group: result.holds[0], in: grown, to: 1))
        keys = try #require(back.imageOverlays.first?.track)
        #expect(keys.first?.xFrac == 0 && keys.last?.xFrac == 0)
        #expect(keys.filter { $0.time >= 2 - 1e-9 && $0.time <= 3 + 1e-9 }.allSatisfy { $0.xFrac == 1 })
        near(try #require(keys.last).time, 7)
        // A 0.2 s freeze cut in two by a 0.1 s bumper is two pieces, not a pause to edit as one.
        let short = try inserted(Fixtures.timelineDocument(clips: [owner]), owner: owner.uid, duration: 0.2)
        var split = short.document
        BumperPlanner.insertGap(in: &split, at: 2.1, duration: 0.1)
        #expect(TimelinePauseRules.owner(group: short.holds[0], in: split) == nil)
    }

    @Test("B-roll splits, later bumpers move, and each bumper-covered request is refused alone")
    func cutawayAndBumper() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        var cutaway = Fixtures.timelineClip(sceneID: nil, sourceStart: 20, duration: 6, track: 1)
        cutaway.role = .cutaway; cutaway.coverAllAreas = true; cutaway.strikeImpactsFrozen = false
        var bumper = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 3)
        bumper.bumper = true
        let document = Fixtures.timelineDocument(clips: [owner, cutaway, bumper])
        let result = try #require(TimelinePauseRules.insert([
            .init(time: 3.5, duration: 1, owner: owner.uid),
            .init(time: 2, duration: 1, owner: owner.uid),
            .init(time: 5, duration: 0.5, owner: owner.uid)
        ], into: document, resolve: { $0 }))
        try #require(result.count == 2)
        let broll = result.document.videoTrack.filter { $0.originKey == cutaway.originKey }
        #expect(broll.count == 5 && broll.allSatisfy { $0.isCutaway && $0.coverAllAreas && $0.strikeImpactsFrozen == false })
        near(try #require(result.document.videoTrack.first { $0.uid == bumper.uid }).startTime, 4)
        let second = try #require(TimelinePauseRules.owner(group: result.holds[1], in: result.document))
        near(second.startTime, 6)
        #expect(TimelinePauseRules.insert([.init(time: 3, duration: 1, owner: owner.uid)],
                                         into: document, resolve: { $0 }) == nil)
    }

    private func lanes(owner: TimelineClip) -> TimelineDocument {
        var document = Fixtures.timelineDocument(clips: [owner])
        document.soundTrack = [.init(name: "spanning", startTime: 1, duration: 4),
                               .init(name: "later", startTime: 4, duration: 2)]
        var text = TextOverlayItem(text: "spanning"); text.startTime = 1; text.endTime = 5
        var laterText = TextOverlayItem(text: "later"); laterText.startTime = 4; laterText.endTime = 6
        document.textOverlays = [text, laterText]
        var image = ImageOverlayItem(path: "/tmp/image.png"); image.startTime = 1; image.endTime = 5
        var laterImage = image; laterImage.uid = UUID(); laterImage.startTime = 4; laterImage.endTime = 6
        document.imageOverlays = [image, laterImage]
        var block = OverlayBlockItem(); block.startTime = 1; block.duration = 4
        var laterBlock = OverlayBlockItem(); laterBlock.startTime = 4; laterBlock.duration = 2
        document.overlayBlocks = [block, laterBlock]
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 4),
                               .init(layout: .init(name: "50-50 Horizontal"), startTime: 4, duration: 4)]
        document.dubLines = [1.0, 2.0, 5.0].map {
            DubLine(clipUID: owner.uid, speakerKey: "a", voice: "v", text: "line",
                    sourceStart: $0, sourceEnd: $0 + 1, start: $0, duration: 1)
        }
        return document
    }

    private func checkLanes(_ document: TimelineDocument, added: Double) throws {
        try #require(document.soundTrack.count == 2 && document.textOverlays.count == 2
                     && document.imageOverlays.count == 2 && document.overlayBlocks.count == 2
                     && document.cropBlocks.count == 2)
        near(document.soundTrack[0].startTime, 1); near(document.soundTrack[0].duration, 4 + added)
        near(document.soundTrack[1].startTime, 4 + added); near(document.soundTrack[1].duration, 2)
        near(document.textOverlays[0].startTime, 1); near(document.textOverlays[0].endTime, 5 + added)
        near(document.textOverlays[1].startTime, 4 + added); near(document.textOverlays[1].endTime, 6 + added)
        near(document.imageOverlays[0].startTime, 1); near(document.imageOverlays[0].endTime, 5 + added)
        near(document.imageOverlays[1].startTime, 4 + added); near(document.imageOverlays[1].endTime, 6 + added)
        near(document.overlayBlocks[0].startTime, 1); near(document.overlayBlocks[0].duration, 4 + added)
        near(document.overlayBlocks[1].startTime, 4 + added); near(document.overlayBlocks[1].duration, 2)
        #expect(document.cropBlocks.count == 2)
        near(document.cropBlocks[0].duration, 4 + added); near(document.cropBlocks[1].startTime, 4 + added)
        near(document.cropBlocks[1].duration, 4)
        let lines = try #require(document.dubLines)
        try #require(lines.count == 3)
        near(lines[0].start, 1); near(lines[1].start, 2 + added); near(lines[2].start, 5 + added)
        for line in lines { near(line.duration, 1) }
    }

    @Test("Every shared lane stretches or moves, dubs keep their pieces, and resize/remove invert the times")
    func laneRoundTrip() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        let original = lanes(owner: owner)
        let result = try inserted(original, owner: owner.uid)
        try checkLanes(result.document, added: 1)
        let head = try #require(result.document.videoTrack.first { $0.hold != true && $0.startTime < 2 })
        let tail = try #require(result.document.videoTrack.first { $0.hold != true && $0.startTime > 2 })
        let lines = try #require(result.document.dubLines)
        try #require(lines.count == 3)
        #expect(lines[0].clipUID == head.uid && lines[1].clipUID == tail.uid && lines[2].clipUID == tail.uid)
        let up = try #require(TimelinePauseRules.resized(group: result.holds[0], in: result.document, to: 3))
        try checkLanes(up, added: 3)
        let down = try #require(TimelinePauseRules.resized(group: result.holds[0], in: up, to: 0.5))
        try checkLanes(down, added: 0.5)
        let removed = try #require(TimelinePauseRules.removed(group: result.holds[0], in: down))
        try checkLanes(removed, added: 0)
        #expect(removed.soundTrack == original.soundTrack && removed.textOverlays == original.textOverlays)
        #expect(removed.imageOverlays == original.imageOverlays && removed.overlayBlocks == original.overlayBlocks)
        #expect(removed.cropBlocks == original.cropBlocks)
        #expect(removed.videoTrack.count == 2 && removed.videoTrack.allSatisfy { $0.hold != true })
        near(try #require(removed.videoTrack.first { $0.uid == tail.uid }).startTime, 2)
    }

    @Test("Multiple requests accumulate shifts and skip invalid requests without losing valid neighbors")
    func multiple() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        let other = Fixtures.timelineClip(sceneID: nil, sourceStart: 30, duration: 8, track: 1)
        var document = lanes(owner: owner); document.videoTrack.append(other)
        let result = try #require(TimelinePauseRules.insert([
            .init(time: 5, duration: 0.7, owner: owner.uid),
            .init(time: 0.1, duration: 1, owner: owner.uid),
            .init(time: 2, duration: 1.2, owner: owner.uid),
            .init(time: 2.1, duration: 1, owner: owner.uid),
            .init(time: 3, duration: .nan, owner: owner.uid),
            .init(time: .nan, duration: 1, owner: owner.uid)
        ], into: document, resolve: { $0 }))
        try #require(result.count == 2)
        let first = try #require(TimelinePauseRules.owner(group: result.holds[0], in: result.document))
        let second = try #require(TimelinePauseRules.owner(group: result.holds[1], in: result.document))
        near(first.startTime, 2); near(second.startTime, 6.2)
        for track in [0, 1] {
            near(result.document.videoTrack.filter { $0.track == track }.reduce(0) { $0 + $1.duration }, 9.9)
        }
        let removedFirst = try #require(TimelinePauseRules.removed(group: first.uid, in: result.document))
        near(try #require(TimelinePauseRules.owner(group: second.uid, in: removedFirst)).startTime, 5)
        let removedBoth = try #require(TimelinePauseRules.removed(group: second.uid, in: removedFirst))
        try #require(removedBoth.soundTrack.count == document.soundTrack.count)
        try #require(removedBoth.cropBlocks.count == document.cropBlocks.count)
        for (item, original) in zip(removedBoth.soundTrack, document.soundTrack) {
            near(item.startTime, original.startTime); near(item.duration, original.duration)
        }
        for (item, original) in zip(removedBoth.cropBlocks, document.cropBlocks) {
            near(item.startTime, original.startTime); near(item.duration, original.duration)
        }
        let lines = try #require(removedBoth.dubLines)
        for (line, original) in zip(lines, try #require(document.dubLines)) { near(line.start, original.start) }
        #expect(lines.allSatisfy { line in removedBoth.videoTrack.contains { $0.uid == line.clipUID } })
    }

    @Test("Group identity survives Codable; nil has no key and missing owners are not linked")
    func persistence() throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        #expect(plain["pause_group"] == nil && plain["uid"] == nil)
        #expect(try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(clip)).pauseGroup == nil)
        var same = clip; same.pauseGroup = UUID()
        #expect(same != clip)
        clip.track = 1
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let result = try inserted(Fixtures.timelineDocument(clips: [owner, clip]), owner: owner.uid)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(result.document))
        let group = result.holds[0]
        #expect(TimelinePauseRules.owner(group: group, in: decoded)?.uid == group)
        let resized = try #require(TimelinePauseRules.resized(group: group, in: decoded, to: 2))
        for hold in resized.videoTrack.filter({ $0.pauseGroup == group }) { near(hold.duration, 2) }
        var orphaned = decoded; orphaned.videoTrack.removeAll { $0.uid == group }
        #expect(TimelinePauseRules.resized(group: group, in: orphaned, to: 2) == nil)
        #expect(TimelinePauseRules.removed(group: group, in: orphaned) == nil)
    }

    @Test("Shrinking keeps tiny positive lane remnants and tracks without companions still move")
    func shortRemainderAndEmptyTrack() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6)
        let later = Fixtures.timelineClip(sceneID: nil, startTime: 9, track: 2)
        var document = Fixtures.timelineDocument(clips: [owner, later])
        document.trackSequential[2] = false
        document.soundTrack = [.init(startTime: 1.9999, duration: 0.0002)]
        let result = try inserted(document, owner: owner.uid)
        let grown = try #require(TimelinePauseRules.resized(group: result.holds[0], in: result.document, to: 2))
        near(try #require(grown.videoTrack.first { $0.uid == later.uid }).startTime, 11)
        let removed = try #require(TimelinePauseRules.removed(group: result.holds[0], in: grown))
        near(try #require(removed.videoTrack.first { $0.uid == later.uid }).startTime, 9)
        try #require(removed.soundTrack.count == 1)
        near(removed.soundTrack[0].duration, 0.0002)
    }

    @Test("Invalid owners and requests are skipped, and the resolver supplies legacy bounds")
    func validationAndResolver() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6)
        for time in [0.0, 0.249, 5.751, 6, Double.infinity] {
            #expect(TimelinePauseRules.insert([.init(time: time, duration: 1, owner: clip.uid)],
                                             into: Fixtures.timelineDocument(clips: [clip]), resolve: { $0 }) == nil)
        }
        for duration in [-1.0, 0.049, 5.001, Double.infinity] {
            #expect(TimelinePauseRules.insert([.init(time: 2, duration: duration, owner: clip.uid)],
                                             into: Fixtures.timelineDocument(clips: [clip]), resolve: { $0 }) == nil)
        }
        var bumper = clip; bumper.bumper = true
        var cutaway = clip; cutaway.role = .cutaway
        var hold = clip; hold.hold = true; hold.sourceEnd = 10
        for invalid in [bumper, cutaway, hold] {
            #expect(TimelinePauseRules.insert([.init(time: 2, duration: 1, owner: invalid.uid)],
                                             into: Fixtures.timelineDocument(clips: [invalid]), resolve: { $0 }) == nil)
        }
        var legacy = clip; legacy.sourceStart = nil; legacy.sourceEnd = nil
        let result = try #require(TimelinePauseRules.insert([.init(time: 2, duration: 1, owner: legacy.uid)],
            into: Fixtures.timelineDocument(clips: [legacy]), resolve: { source in
                var resolved = source
                resolved.sourceStart = resolved.sourceStart ?? 10
                resolved.sourceEnd = resolved.sourceEnd ?? 16
                return resolved
            }))
        let frozen = try #require(result.document.videoTrack.first { $0.hold == true })
        near(try #require(frozen.sourceStart), 12)
    }

    @Test("A layout that begins at the pause stays on screen through it")
    func layoutBoundary() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6)
        var document = Fixtures.timelineDocument(clips: [owner])
        document.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2),
                               .init(layout: .init(name: "50-50 Horizontal"), startTime: 2, duration: 4)]
        let blocks = try inserted(document, owner: owner.uid).document.cropBlocks
        try #require(blocks.count == 2)
        near(blocks[0].duration, 2)
        near(blocks[1].startTime, 2); near(blocks[1].duration, 5)
    }

    @Test("Items inside an overlay block and image tracking keys move with the pause")
    func nestedAndTracking() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 8)
        var document = Fixtures.timelineDocument(clips: [owner])
        var title = TextOverlayItem(text: "inside"); title.startTime = 3; title.endTime = 5
        var across = TextOverlayItem(text: "across"); across.startTime = 0.5; across.endTime = 2.5
        var block = OverlayBlockItem(); block.startTime = 1; block.duration = 7
        block.composition.texts = [title, across]
        document.overlayBlocks = [block]
        var image = ImageOverlayItem(path: "/tmp/image.png"); image.startTime = 1; image.endTime = 6
        image.track = [.init(time: 1, xFrac: 0.1, yFrac: 0.1, wFrac: 0.2), .init(time: 4, xFrac: 0.5, yFrac: 0.5, wFrac: 0.2)]
        document.imageOverlays = [image]
        let result = try inserted(document, owner: owner.uid).document
        let moved = try #require(result.overlayBlocks.first)
        near(moved.duration, 8)
        // The pause is 1 s into the block: the later title moves, the one on screen stretches.
        near(moved.composition.texts[0].startTime, 4); near(moved.composition.texts[0].endTime, 6)
        near(moved.composition.texts[1].startTime, 0.5); near(moved.composition.texts[1].endTime, 3.5)
        let keys = try #require(result.imageOverlays.first?.track)
        // The image stands still through the pause: 2...3 s at the interpolated place.
        try #require(keys.count == 4)
        near(keys[0].time, 1); near(keys[1].time, 2); near(keys[2].time, 3); near(keys[3].time, 5)
        near(keys[1].xFrac, 0.1 + 0.4 / 3); near(keys[2].xFrac, keys[1].xFrac); near(keys[3].xFrac, 0.5)
        var open = TextOverlayItem(text: "open"); open.startTime = 3; open.endTime = 4; open.unbounded = true
        var second = document
        second.overlayBlocks[0].composition.texts = [open]
        near(try #require(try inserted(second, owner: owner.uid).document.overlayBlocks.first?.composition.texts.first).startTime, 4)
    }

    @Test("A pause pulled apart by other edits is no longer edited as one")
    func brokenGroup() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6)
        let other = Fixtures.timelineClip(sceneID: nil, sourceStart: 30, duration: 6, track: 1)
        let result = try inserted(Fixtures.timelineDocument(clips: [owner, other]), owner: owner.uid)
        let group = result.holds[0]
        #expect(TimelinePauseRules.owner(group: group, in: result.document) != nil)
        // A companion moved away.
        var apart = result.document
        let companion = try #require(apart.videoTrack.firstIndex { $0.track == 1 && $0.hold == true })
        apart.videoTrack[companion].startTime += 1
        #expect(TimelinePauseRules.owner(group: group, in: apart) == nil)
        #expect(TimelinePauseRules.resized(group: group, in: apart, to: 2) == nil)
        // A pausing bumper through the middle leaves two unequal pieces on each track.
        var split = result.document
        BumperPlanner.insertGap(in: &split, at: 2.4, duration: 1)
        #expect(TimelinePauseRules.owner(group: group, in: split) == nil)
        #expect(TimelinePauseRules.removed(group: group, in: split) == nil)
    }

    @Test("A clip on another track laid out past its scene's end does not make the pause impossible")
    func companionPastItsSourceEnd() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 8)
        var other = Fixtures.timelineClip(sceneID: nil, sourceStart: 83.7, duration: 2.5, startTime: 1, track: 1)
        other.sourceEnd = 86.176
        let result = try inserted(Fixtures.timelineDocument(clips: [owner, other]), owner: owner.uid)
        let pieces = result.document.videoTrack.filter { $0.track == 1 }.sorted { $0.startTime < $1.startTime }
        try #require(pieces.count == 3)
        #expect(pieces[1].hold == true && pieces[1].pauseGroup == result.holds[0])
        near(try #require(pieces[1].sourceStart), 84.7)
        near(pieces[0].duration, 1); near(pieces[2].duration, 1.5); near(pieces[2].startTime, 3)
    }
}
