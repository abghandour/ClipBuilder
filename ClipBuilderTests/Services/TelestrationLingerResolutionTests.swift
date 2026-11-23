import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration stay resolution")
struct TelestrationLingerResolutionTests {
    @Test func movingDrawingAttachesOnlyToItsPieceThenCarriesTheStay() throws {
        let source = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8)
        let drawing = Telestration(time: 2, figures: [.init(linger: 1)], stay: 1, drawSpeed: 0.5, fade: 0.5, motion: 0.5)
        let split = TelestrationMotionRules.moving([source], drawings: [drawing])
        let document = Fixtures.timelineDocument(clips: split.pieces)
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.count == 3 && resolved.allSatisfy { $0.telestration == nil && $0.lingeringHold == nil })
        #expect(resolved[0].lingering == nil && resolved[1].lingering == drawing)
        #expect(resolved[2].lingering?.offset == drawing.duration)
        let window = MultitrackRenderer.windowed(document, scenes: [], from: 2.5, to: 5.5)
        #expect(window.lingering[split.pieces[1].uid]?.offset == 0.5)
        let clips = MultitrackRenderer.resolveClips(document: window.document, scenes: [], lingering: window.lingering)
        #expect(clips.first?.lingering?.offset == 0.5)
        let next = MultitrackRenderer.windowed(window.document, scenes: [], lingering: window.lingering, from: 0.25, to: 1)
        #expect(next.lingering[split.pieces[1].uid]?.offset == 0.75)
        var crops = document
        crops.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2.5),
                           .init(layout: .fullScreen, startTime: 2.5, duration: 6.5)]
        let cropped = MultitrackRenderer.resolveClips(document: crops, scenes: [])
        let late = try #require(cropped.first { $0.startTime == 2.5 })
        #expect(TelestrationLingerResolution.drawingForPiece(late)?.offset == 0.5)
        var noStay = drawing
        noStay.figures[0].linger = nil
        let plain = Fixtures.timelineDocument(clips: TelestrationMotionRules.moving([source], drawings: [noStay]).pieces)
        let onlyDraw = MultitrackRenderer.resolveClips(document: plain, scenes: [])
        #expect(onlyDraw[1].lingering == noStay && onlyDraw[2].lingering == nil)
        for kind in ["hold", "bumper", "cutaway"] {
            var unsupported = split.pieces[1]
            if kind == "hold" { unsupported.hold = true }
            if kind == "bumper" { unsupported.bumper = true }
            if kind == "cutaway" { unsupported.role = .cutaway }
            let excluded = MultitrackRenderer.resolveClips(document: Fixtures.timelineDocument(clips: [unsupported]), scenes: [])
            #expect(excluded.allSatisfy { $0.lingering == nil && $0.telestration?.motion == nil })
        }
        // The prepass key fingerprints the source file, so it must exist.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prepass-key-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var carried = resolved[1]
        carried.sourcePath = file.path
        var changed = carried
        changed.lingering?.drawSpeed += 0.1
        #expect(try RenderSegmentCache.key(TelestrationLingerResolution.cacheEvidence([carried]))
            != RenderSegmentCache.key(TelestrationLingerResolution.cacheEvidence([changed])))
        #expect(try MultitrackRenderer.prepassKey(carried, area: nil, tuning: "balanced")
            != MultitrackRenderer.prepassKey(changed, area: nil, tuning: "balanced"))
    }

    private func document() -> TimelineDocument {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 1, startTime: 1)
        hold.hold = true
        hold.telestration = Telestration(time: 1, figures: [.init(linger: 1.5)])
        var moving = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 2, startTime: 2)
        moving.wide = false
        return Fixtures.timelineDocument(clips: [hold, moving])
    }

    @Test func attachesOnlyToContiguousMovingSourceOnSameTrack() throws {
        let original = document()
        let resolved = MultitrackRenderer.resolveClips(document: original, scenes: [])
        #expect(resolved.count == 2)
        #expect(resolved[0].lingering == nil)
        #expect(resolved[1].lingering == original.videoTrack[0].telestration)
        for invalid in 0..<8 {
            var document = original
            switch invalid {
            case 0: document.videoTrack[1].track = 1
            case 1: document.videoTrack[1].videoFile = "/tmp/another-source.mp4"
            case 2: document.videoTrack[1].startTime += 0.02
            case 3: document.videoTrack[1].hold = true
            case 4: document.videoTrack[1].bumper = true
            case 5: document.videoTrack[1].role = .cutaway
            case 6: document.videoTrack[0].telestration = nil
            default: document.videoTrack[0].telestration?.figures[0].linger = 0
            }
            #expect(MultitrackRenderer.resolveClips(document: document, scenes: []).allSatisfy { $0.lingering == nil })
        }
        var close = original
        close.videoTrack[1].startTime += 1.0 / 120
        #expect(try #require(MultitrackRenderer.resolveClips(document: close, scenes: []).last).lingering != nil)
        // Array order is not timeline order; another track between them is irrelevant.
        var otherTrack = original.videoTrack[1]
        otherTrack.uid = UUID()
        otherTrack.track = 1
        var shuffled = original
        shuffled.videoTrack = [original.videoTrack[1], otherTrack, original.videoTrack[0]]
        let attached = MultitrackRenderer.resolveClips(document: shuffled, scenes: []).filter { $0.lingering != nil }
        #expect(attached.count == 1 && attached.first?.documentIndex == 0)        // B-roll laid over the pause on the same track sits between the two in
        // time: the stay still goes to the piece that continues the hold.
        var broll = Fixtures.timelineClip(sceneID: nil, sourceStart: 5, duration: 0.5, startTime: 1.2)
        broll.role = .cutaway
        broll.videoFile = "/tmp/broll.mp4"
        var covered = original
        covered.videoTrack.append(broll)
        let withBroll = MultitrackRenderer.resolveClips(document: covered, scenes: []).filter { $0.lingering != nil }
        #expect(withBroll.count == 1 && withBroll.first?.documentIndex == 1)
    }

    @Test func shortFollowingClipEndsStayAndPlainHoldDoesNotPassItOn() throws {
        var document = document()
        document.videoTrack[1].duration = 0.2
        var third = document.videoTrack[1]
        third.uid = UUID()
        third.startTime = 2.2
        third.sourceStart = 1.2
        third.duration = 1
        document.videoTrack.append(third)
        let clips = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(clips.count == 3)
        #expect(clips[1].lingering != nil && clips[2].lingering == nil)
        let frames = TelestrationBurn.lingerFrameTimes(try #require(clips[1].lingering), offset: 0, duration: clips[1].duration, speed: 1)
        #expect(frames.count == 6)
        document.videoTrack[1].hold = true
        #expect(MultitrackRenderer.resolveClips(document: document, scenes: []).allSatisfy { $0.lingering == nil })
    }

    @Test func subsequentContactSuspendsStayAndWindowKeepsItsClock() throws {
        var doc = document()
        var moving = doc.videoTrack[1]
        moving.duration = 0.25
        moving.sourceEnd = 1.25
        var contact = moving
        contact.uid = UUID()
        contact.startTime = 2.25
        contact.sourceStart = 1.25
        contact.hold = true
        contact.duration = 1
        var tail = moving
        tail.uid = UUID()
        tail.startTime = 3.25
        tail.sourceStart = 1.25
        tail.duration = 2
        tail.sourceEnd = 3.25
        doc.videoTrack = [doc.videoTrack[0], moving, contact, tail]
        let resolved = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        for index in [2, 3] {
            let drawing = try #require(resolved[index].lingering)
            #expect(abs((drawing.offset ?? 0) - 0.25) < 1e-9)
            #expect(resolved[index].lingeringHold?.first?.stayHoldID == doc.videoTrack[0].uid)
        }
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 2.75, to: 4)
        let held = try #require(window.lingering[contact.uid])
        let resumed = try #require(window.lingering[tail.uid])
        #expect(abs((held.offset ?? 0) - 0.25) < 1e-9)
        #expect(abs((resumed.offset ?? 0) - 0.25) < 1e-9)
        let frames = TelestrationBurn.lingerFrameTimes(held, offset: 0.25, duration: 1, speed: 1, paused: true)
        #expect(frames.count == 30)
        #expect(frames.allSatisfy { abs($0.elapsed - 0.25) < 1e-9 && abs($0.sourceOffset) < 1e-9 })
        doc.videoTrack[2].telestration = Telestration(figures: [.init()])
        let replaced = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        #expect(replaced[2].lingering == nil && replaced[3].lingering == nil)
    }

    @Test func windowAndCropSplitCarryScreenClockWithoutSavingIt() throws {
        var original = document()
        original.videoTrack[1].speed = 2
        let window = MultitrackRenderer.windowed(original, scenes: [], from: 2.4, to: 3.8)
        let item = try #require(window.document.videoTrack.first)
        #expect(window.document.videoTrack.count == 1 && item.telestration == nil)
        #expect(abs((item.sourceStart ?? -1) - 1.8) < 1e-9)
        let resolved = MultitrackRenderer.resolveClips(document: window.document, scenes: [], lingering: window.lingering)
        #expect(abs((resolved.first?.lingering?.offset ?? -1) - 0.4) < 1e-9)
        let again = MultitrackRenderer.windowed(window.document, scenes: [], lingering: window.lingering, from: 0.2, to: 1)
        #expect(abs((again.lingering[item.uid]?.offset ?? -1) - 0.6) < 1e-9)
        #expect(MultitrackRenderer.windowed(original, scenes: [], from: 3.6, to: 4).lingering.isEmpty)
        original.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 2.5),
                               .init(layout: .fullScreen, startTime: 2.5, duration: 1.5)]
        let split = MultitrackRenderer.resolveClips(document: original, scenes: [])
        let late = try #require(split.first { abs($0.startTime - 2.5) < 1e-9 })
        #expect(abs((TelestrationLingerResolution.drawingForPiece(late)?.offset ?? -1) - 0.5) < 1e-9)
        let segment = try #require(MultitrackRenderer.buildLayeredSegments(split).first { abs($0.start - 2.5) < 1e-9 })
        let placement = try #require(MultitrackRenderer.placements(for: segment).first)
        #expect(abs(placement.holdOffset(at: segment.start) - 0.5) < 1e-9)
        let encoder = JSONEncoder()
        #expect(!String(decoding: try encoder.encode(window.document), as: UTF8.self).contains("lingering"))
        #expect(!String(decoding: try encoder.encode(resolved), as: UTF8.self).contains("lingering"))
        let decoded = try JSONDecoder().decode([MultitrackRenderer.ResolvedClip].self, from: encoder.encode(resolved))
        #expect(decoded.allSatisfy { $0.lingering == nil })
    }

    @Test func segmentAndPreviewEvidenceChangeWithStayAndRemainAbsentWithoutIt() throws {
        let original = document()
        var clip = try #require(MultitrackRenderer.resolveClips(document: original, scenes: []).last)
        clip.framingIdentity = "test-source"
        var input = RenderSegmentKey(start: 0, duration: 2, clips: [clip], captions: [], overlays: [], masks: [:],
            fontFingerprints: [], captionStyle: CaptionStyle(), settings: RenderSettings(), encoder: [],
            lingering: TelestrationLingerResolution.cacheEvidence([clip]))
        let key = try RenderSegmentCache.key(input)
        var changed = clip
        changed.lingering?.figures[0].linger = 2
        input.lingering = TelestrationLingerResolution.cacheEvidence([changed])
        #expect(try RenderSegmentCache.key(input) != key)
        changed.lingering = nil
        input.clips = [changed]
        input.lingering = TelestrationLingerResolution.cacheEvidence([changed])
        #expect(input.lingering == nil)
        #expect(!String(decoding: try JSONEncoder().encode(input), as: UTF8.self).contains("lingering"))
        let oldDrawing = Telestration(figures: [.init()])
        var zero = oldDrawing
        zero.figures[0].linger = 0
        #expect(try RenderSegmentCache.key(TelestrationLingerResolution.cacheDrawing(zero))
            == RenderSegmentCache.key(oldDrawing))
        let first = AppStore.builderPreviewKey(document: original, scenes: [], profile: Fixtures.brand(),
            camera: "balanced", window: 2.4...3)
        var edited = original
        edited.videoTrack[0].telestration?.figures[0].linger = 2
        let second = AppStore.builderPreviewKey(document: edited, scenes: [], profile: Fixtures.brand(),
            camera: "balanced", window: 2.4...3)
        #expect(first != nil && second != nil && first != second)
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced")
            != MultitrackRenderer.prepassKey(changed, area: nil, tuning: "balanced"))
        var faster = clip
        faster.speed = 2
        faster.duration /= 2 // Same source span, different screen clock.
        #expect(try MultitrackRenderer.prepassKey(clip, area: nil, tuning: "balanced")
            != MultitrackRenderer.prepassKey(faster, area: nil, tuning: "balanced"))
    }
    @Test(arguments: ["slow", "flash"])
    func automaticMovingSplitsCarryStayButUserCutsEndIt(kind: String) throws {
        var doc = document()
        let moving = doc.videoTrack[1]
        let pieces = kind == "slow"
            ? StrikeImpactRules.slowed([moving], contacts: [2], strength: .medium)
            : StrikeImpactRules.flashed([moving], contacts: [1.5])
        doc.videoTrack = [doc.videoTrack[0]] + pieces
        let resolved = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        let next = try #require(resolved.first { $0.startTime > moving.startTime })
        let stay = try #require(next.lingering)
        #expect(abs((stay.offset ?? 0) - (next.startTime - moving.startTime)) < 1e-9)
        #expect(next.lingeringHold?.first?.stayHoldID == doc.videoTrack[0].uid)
        let member = try #require(doc.videoTrack.first { $0.startTime == next.startTime })
        let split = try #require(TimelineSplit.split(in: &doc, uid: member.uid,
            at: member.startTime + 0.25, precision: .speech))
        let afterCut = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        #expect(try #require(afterCut.first { $0.continuityClipID == split.tail }).lingering == nil)
        let saved = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(doc))
        let reopened = MultitrackRenderer.resolveClips(document: saved, scenes: [])
        #expect(try #require(reopened.first { $0.continuityClipID == split.tail }).lingering == nil)
    }

    @Test func removingSlowKeepsAutomaticBoundariesDistinctFromUserCut() throws {
        let input = document()
        let slowed = try #require(TimelineSlowRules.insert([3], owner: input.videoTrack[1].uid,
            strength: .medium, into: input))
        var edited = slowed.document
        let piece = try #require(edited.videoTrack.first { $0.slowGroup != nil })
        let cut = try #require(TimelineSplit.split(in: &edited, uid: piece.uid, at: 2.75, precision: .speech))
        let removed = try #require(TimelineSlowRules.removed(group: slowed.groups[0], in: edited))
        let resolved = MultitrackRenderer.resolveClips(document: removed, scenes: [])
        #expect(try #require(resolved.first { $0.continuityClipID == cut.head }).lingering != nil)
        #expect(try #require(resolved.first { $0.continuityClipID == cut.tail }).lingering == nil)
    }

    @Test func legacyUnmarkedCutInsideSlowGroupEndsStayConservatively() throws {
        let input = document()
        let slowed = try #require(TimelineSlowRules.insert([3], owner: input.videoTrack[1].uid,
            strength: .medium, into: input))
        var edited = slowed.document
        let piece = try #require(edited.videoTrack.first { $0.slowGroup != nil })
        let cut = try #require(TimelineSplit.split(in: &edited, uid: piece.uid, at: 2.75, precision: .speech))
        let tail = try #require(edited.videoTrack.firstIndex { $0.uid == cut.tail })
        edited.videoTrack[tail].stayCut = nil // Saved before cut provenance was introduced.
        let resolved = MultitrackRenderer.resolveClips(document: edited, scenes: [])
        #expect(try #require(resolved.first { $0.continuityClipID == cut.tail }).lingering == nil)
    }

}
