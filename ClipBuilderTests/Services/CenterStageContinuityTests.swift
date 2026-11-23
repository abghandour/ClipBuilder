import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Continuous Center Stage take rules")
struct CenterStageContinuityTests {
    static func sameFileCompanions(path: String, companions: Int, kind: String) throws -> TimelineDocument {
        let layout = ScreenCropLayout(name: "Continuity companions", areas: (0...companions).map { track in
            let top = Double(track) / Double(companions + 1)
            let bottom = Double(track + 1) / Double(companions + 1)
            return ScreenCropArea(name: "Picture \(track)", points: [.init(x: 0, y: top), .init(x: 1, y: top),
                .init(x: 1, y: bottom), .init(x: 0, y: bottom)])
        })
        var scenes: [Int64: SceneRecord] = [:]
        var planClip = Fixtures.planClip(start: 0, end: 2)
        var clips: [TimelineClip] = []
        for track in 0...companions {
            let start = Double(track * 3)
            var scene = Fixtures.scene(id: Int64(track + 1), start: start, end: start + 2)
            scene.videoPath = path
            scene.videoID = 1
            scenes[scene.id] = scene
            if track == 0 { planClip.sceneID = scene.id }
            else { planClip.areaClips.append(.init(area: "Picture \(track)", sceneID: scene.id, start: start, end: start + 2)) }
            var clip = Fixtures.timelineClip(sceneID: scene.id, sourceStart: start, duration: 2, track: track)
            clip.videoFile = path; clip.sourceEnd = start + 2
            clip.wide = false; clip.centerStage = false; clip.captions = "none"
            clip.precision = .speech
            clip.framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            clips.append(clip)
        }
        var cut = Fixtures.timelineDocument(clips: clips)
        cut.trackCount = companions + 1
        for track in 1...companions { cut.trackSequential[track] = false }
        cut.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: (companions + 1) * 360)
        var options = WizardOptions()
        options.strikeImpactFreeze = kind == "drawn" ? nil : 0.8
        options.drawnPauses = kind != "contact"
        options.useBRoll = false; options.manualBRoll = true; options.allowedTransitions = ["cut"]
        let drawing = Telestration(time: 4.3, figures: [.init(kind: .line,
            points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.3)], color: .yellow, width: 0.01)],
            stay: 0.3, drawSpeed: 0.2, fade: 0.1)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [planClip]), cuts: [0: cut],
            sceneMap: scenes, sourceTypes: [1: .fight], contacts: [path: [3.6]],
            drawings: kind == "contact" ? [:] : [path: [drawing]], options: options, xfadeDuration: 0.35)
        return try #require(result.cuts[0])
    }

    @Test(arguments: [1, 2], ["contact", "drawn", "both"])
    func sameFileCompanionRunsKeepIndependentSourceClocks(companions: Int, kind: String) throws {
        let doc = try Self.sameFileCompanions(path: "/tmp/same-file.mp4", companions: companions, kind: kind)
        let runs = CenterStageContinuity.runs(resolve(doc))
        #expect(runs.count == companions + 1)
        for run in runs {
            #expect(abs(run.start - Double(run.template.track * 3)) < 1e-9)
            #expect(abs(run.end - run.start - 2) < 1e-9)
            #expect(run.members.count == (kind == "both" ? 5 : 3))
        }
        let drawn = doc.videoTrack.filter { $0.telestration != nil }
        #expect(drawn.count == (kind == "contact" ? 0 : 1))
        #expect(drawn.allSatisfy { $0.track == 1 })
    }

    @Test func transformSlicesInterpolateTransformsIncludingTheHeldFrame() throws {
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5),
                    .init(t: 2, x: 0.3, y: 0.2, w: 0.25, h: 0.25)]
        let slice = CenterStageContinuity.transformSlice(path, from: 0.5, duration: 1)
        let held = CenterStageContinuity.transformSlice(path, from: 1, duration: 0, holdDuration: 0.8)
        let midpoint = try #require(held.first)
        #expect(abs(midpoint.w - 1.0 / 3) < 1e-12)
        for time in stride(from: 0.5, through: 1.5, by: 0.1) {
            let full = try #require(CenterStageContinuity.transformSlice(path, from: time, duration: 0).first)
            let part = try #require(CenterStageContinuity.transformSlice(slice, from: time - 0.5, duration: 0).first)
            #expect(abs(1 / full.w - 1 / part.w) < 1e-12)
            #expect(abs(full.x / full.w - part.x / part.w) < 1e-12)
            #expect(abs(full.y / full.w - part.y / part.w) < 1e-12)
        }
        #expect(held.allSatisfy { abs($0.w - midpoint.w) < 1e-12 && abs($0.x - midpoint.x) < 1e-12 })
    }

    @Test func invalidWindowsRejectTheWholePath() {
        let valid = CameraPathKeyframe(t: 0, x: 0, y: 0, w: 1, h: 1)
        #expect(TrackedPictureBounds.clamped([valid]) == [valid])
        for value in [Double.nan, .infinity, 0, -1] {
            var invalid = valid
            invalid.w = value
            #expect(TrackedPictureBounds.clamped([valid, invalid]).isEmpty)
            let crop = CGRect(x: 0, y: 0, width: value, height: 1)
            #expect(TrackedPictureBounds.clamped(crop, size: CGSize(width: 100, height: 100)) == nil)
        }
        var invalid = valid
        invalid.x = .nan
        #expect(TrackedPictureBounds.clamped([invalid]).isEmpty)
        #expect(TrackedPictureBounds.clamped([valid], to: .init(wFrac: 0)).isEmpty)
        #expect(TrackedPictureBounds.clamped([valid], to: .init(xFrac: .nan)).isEmpty)
        for dimension in [Double.nan, .infinity, 0, -1] {
            let result = TrackedPictureBounds.clamped(CGRect(x: 0, y: 0, width: 1, height: 1),
                size: CGSize(width: 100, height: dimension))
            #expect(result == nil)
        }
        #expect(TrackedPictureBounds.clamped(CGRect(x: 0, y: 0, width: 1, height: 1), size: .zero) == nil)
    }

    @Test func productionBoundsOrderingReportsCorrectionBeforeExport() {
        let calls = Mutex(0)
        let raw = [CameraPathKeyframe(t: 0, x: -0.2, y: 0, w: 0.5, h: 0.5),
                   .init(t: 1, x: 0.2, y: 0.2, w: 0.5, h: 0.5)]
        CenterStageService.$pictureCorrectionObserver.withValue({ calls.withLock { $0 += 1 } }) {
            let tracked = CenterStageService.boundedPath(raw)
            #expect(calls.withLock { $0 } == 1)
            let exported = CenterStageService.boundedPath(tracked)
            #expect(tracked == exported)
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func unionFailuresEvictTheOldestOf256Keys() async throws {
        let cache = RenderSegmentCache()
        for index in 0..<257 {
            _ = try await cache.continuousPath(key: "failure-\(index)", cacheEnabled: true) {
                .init(failure: "no subject")
            }
        }
        let recent = try await cache.continuousPath(key: "failure-1", cacheEnabled: true) {
            Issue.record("A retained failure was recomputed")
            return .init(failure: "unexpected")
        }
        #expect(recent.reused)
        let evicted = try await cache.continuousPath(key: "failure-0", cacheEnabled: true) {
            .init(failure: "retried")
        }
        #expect(!evicted.reused)
        #expect(evicted.outcome.failure == "retried")
    }

    @Test(arguments: [false, true])
    func sharedAreaRunsFromReelPauses(wizard: Bool) throws {
        let main = Fixtures.scene(start: 10, end: 14)
        var companion = Fixtures.scene(id: 2, start: 30, end: 34)
        companion.videoID = 2
        companion.videoPath = "/tmp/companion.mp4"
        var clip = Fixtures.planClip(start: 10, end: 14)
        clip.layout = "50-50 Horizontal"
        clip.screenCrop = "50-50 Horizontal/Top"
        clip.areaClips = [.init(area: "Bottom", sceneID: companion.id, start: 30, end: 34)]
        let scenes = [main.id: main, companion.id: companion]
        let plan = FramingPlan.tracked(CropRecipe(kind: .talker), region: nil, fit: .fill, feather: 0, blur: 0)
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: plan)
        // This is the live-check route: neither Center Stage nor a feed region.
        #expect(cut.videoTrack.allSatisfy { !$0.centerStage && $0.areaRegion == nil })
        #expect(CenterStageContinuity.runs(resolve(cut)).isEmpty)
        if wizard {
            var options = WizardOptions()
            options.strikeImpactFreeze = 0.8
            options.useBRoll = false
            options.manualBRoll = true
            options.allowedTransitions = ["cut"]
            let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
                sceneMap: scenes, sourceTypes: [main.videoID: .fight, companion.videoID: .fight],
                contacts: [main.videoPath: [11, 12]], options: options, xfadeDuration: 0.35)
            cut = try #require(result.cuts[0])
        } else {
            let tracks = WizardSharedPauses.tracks(cut)
            let pieces = try #require(StrikeFreezeRules.sharedPieces(tracks,
                pauses: [.init(time: 1, duration: 0.8), .init(time: 2, duration: 0.8)]))
            cut.videoTrack = pieces.flatMap { $0 }
        }
        let runs = CenterStageContinuity.runs(resolve(cut))
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.members.count == 5 && abs($0.end - $0.start - 4) < 1e-9 })
        #expect(Set(runs.map { $0.template.track }) == [0, 1])
        #expect(runs.allSatisfy { CenterStageContinuity.unsupported($0.template, tuning: "conversation") == nil })
    }

    @Test func failedUnionHoldUsesPreviousThenNextPath() throws {
        let pieces = resolve(Self.document())
        let headID = try #require(pieces[0].continuityClipID)
        let tailID = try #require(pieces[2].continuityClipID)
        let previous = FeedCameraPath(keyframes: [.init(t: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5),
            .init(t: 1, x: 0.2, y: 0.1, w: 0.5, h: 0.5)], samples: [], trackedShare: 1,
            sourceSize: CGSize(width: 1280, height: 720), usedFallback: false)
        var next = previous
        next.keyframes[0].x = 0.3
        let both = CenterStageContinuity.neighbourPath(for: 1, pieces: pieces, paths: [headID: previous, tailID: next])
        #expect(both?.keyframes.allSatisfy { $0.x == 0.2 } == true)
        let onlyNext = CenterStageContinuity.neighbourPath(for: 1, pieces: pieces, paths: [tailID: next])
        #expect(onlyNext?.keyframes.allSatisfy { $0.x == 0.3 } == true)
        var fallback = previous
        fallback.usedFallback = true
        let trackedNext = CenterStageContinuity.neighbourPath(for: 1, pieces: pieces, paths: [headID: fallback, tailID: next])
        #expect(trackedNext?.keyframes.allSatisfy { $0.x == 0.3 } == true)
        #expect(CenterStageContinuity.neighbourPath(for: 1, pieces: pieces, paths: [:]) == nil)
    }

    @Test func trackedWindowsStayInsideThePicture() {
        let picture = FreeCropRect(xFrac: 0.1, yFrac: 0.1, wFrac: 0.8, hFrac: 0.8)
        let safe = CameraPathKeyframe(t: 0, x: 0.2, y: 0.2, w: 0.5, h: 0.5)
        #expect(TrackedPictureBounds.clamped([safe], to: picture) == [safe])
        let outside = [CameraPathKeyframe(t: 0, x: -0.1, y: -0.2, w: 0.5, h: 0.5),
            .init(t: 0.3, x: 0.8, y: 0.8, w: 0.5, h: 0.5),
            .init(t: 1, x: -0.4, y: -0.4, w: 1.6, h: 1.2)]
        let corrected = TrackedPictureBounds.clamped(outside, to: picture)
        for (old, key) in zip(outside, corrected) {
            #expect(key.x >= 0.1 - 1e-9 && key.y >= 0.1 - 1e-9)
            #expect(key.x + key.w <= 0.9 + 1e-9 && key.y + key.h <= 0.9 + 1e-9)
            #expect(abs(key.w / key.h - old.w / old.h) < 1e-9)
            #expect(key.t == old.t)
        }
        #expect(corrected[0].w == outside[0].w && corrected[0].h == outside[0].h)
    }

    static func document() -> TimelineDocument {
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        head.startTime = 0
        head.wide = true
        head.centerStage = true
        head.captions = "none"
        var hold = head
        hold.uid = UUID()
        hold.hold = true
        hold.startTime = 1
        hold.sourceStart = 1
        hold.duration = 0.8
        var tail = head
        tail.uid = UUID()
        tail.startTime = 1.8
        tail.sourceStart = 1
        var doc = Fixtures.timelineDocument(clips: [head, hold, tail])
        doc.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        return doc
    }

    private func resolve(_ doc: TimelineDocument) -> [MultitrackRenderer.ResolvedClip] {
        RenderContext.$settings.withValue(doc.renderSettings) { MultitrackRenderer.resolveClips(document: doc, scenes: []) }
    }

    @Test func sourceClockMembershipSurvivesResolvedFraming() throws {
        let clips = resolve(Self.document())
        let run = try #require(CenterStageContinuity.runs(clips).first)
        var framed = try #require(clips.first)
        framed.areaRegion = FreeCropRect()
        framed.centerStage = false
        #expect(!run.contains(framed))
        #expect(run.containsSourcePiece(framed))
        framed.track += 1
        #expect(!run.containsSourcePiece(framed))
    }

    @Test func headHoldTailAndTwoPauses() throws {
        var doc = Self.document()
        let first = try #require(CenterStageContinuity.runs(resolve(doc)).first)
        #expect(first.members.count == 3)
        #expect(abs(first.start) < 1e-9 && abs(first.end - 2) < 1e-9)
        var hold = doc.videoTrack[1]
        hold.uid = UUID()
        hold.startTime = 2.8
        hold.sourceStart = 2
        var tail = doc.videoTrack[2]
        tail.uid = UUID()
        tail.startTime = 3.6
        tail.sourceStart = 2
        doc.videoTrack += [hold, tail]
        let runs = CenterStageContinuity.runs(resolve(doc))
        #expect(runs.count == 1 && runs.first?.members.count == 5)
        #expect(abs((runs.first?.end ?? 0) - 3) < 1e-9)
    }

    @Test(arguments: ["source", "gap", "region", "focus", "layout", "stored", "static", "tuning", "cutaway"])
    func boundaries(kind: String) {
        var clips = resolve(Self.document())
        switch kind {
        case "source": clips[2].sourcePath = "/tmp/different.mp4"
        case "gap": clips[2].startTime += 0.1
        case "region": clips[2].areaRegion = .init(wFrac: 0.5)
        case "focus": clips[2].areaFocus = .init(x: 0.5, y: 0.5)
        case "layout": clips[2].continuityLayout = .init(name: "Different")
        case "stored": clips[2].cameraPath = [.init(t: 0, x: 0, y: 0, w: 1, h: 1)]
        case "static": clips[2].areaWindow = .init()
        case "tuning": clips[2].framingPlan = .static(window: .init(), fit: .fill, feather: 0, blur: 0)
        default: clips[2].role = .cutaway
        }
        let runs = CenterStageContinuity.runs(clips)
        #expect(runs.count == 1 && runs.first?.members.count == 2)
        #expect(runs.first?.members.contains { $0.id == clips[2].continuityClipID } == false)
    }

    @Test func holdsOutsideCompanionRangeDoNotJoin() {
        var clips = resolve(Self.document())
        clips[1].sourceStart = -0.1
        #expect(CenterStageContinuity.runs(clips).isEmpty)
        clips[1].sourceStart = 2.1
        #expect(CenterStageContinuity.runs(clips).isEmpty)
        // Either end is valid: a hold can precede the first moving frame or
        // follow the final moving frame, but never an unrelated source frame.
        clips = resolve(Self.document())
        #expect(CenterStageContinuity.runs(Array(clips.prefix(2))).count == 1)
        #expect(CenterStageContinuity.runs(Array(clips.suffix(2))).count == 1)
        clips[1].sourceStart = 1 - 0.045
        #expect(CenterStageContinuity.runs(clips).first?.members.count == 3)
    }

    @Test func interpolationAndSpeed() throws {
        let path = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 0.5),
                    .init(t: 4, x: 0.4, y: 0.4, w: 0.5, h: 0.5)]
        var clip = try #require(resolve(Self.document()).first)
        clip.sourceStart = 1
        clip.duration = 1
        clip.speed = 2
        let moving = CenterStageContinuity.slice(path, runStart: 0, clip: clip)
        #expect(abs((moving.first?.x ?? -1) - 0.1) < 1e-9)
        #expect(abs((moving.last?.x ?? -1) - 0.3) < 1e-9)
        #expect(abs((moving.last?.t ?? -1) - 2) < 1e-9)
        clip.hold = true
        let held = CenterStageContinuity.slice(path, runStart: 0, clip: clip)
        #expect(held.count == 2)
        #expect(held.allSatisfy { abs($0.x - 0.1) < 1e-9 })
        #expect(abs((held.last?.t ?? -1) - clip.duration) < 1e-9)
    }

    @Test func previewKeepsUnionAndSingleClipKey() throws {
        let doc = Self.document()
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 2, to: 2.5)
        #expect(window.document.videoTrack.count == 1)
        let run = try #require(window.continuity.first)
        #expect(abs(run.start) < 1e-9 && abs(run.end - 2) < 1e-9)
        let nested = MultitrackRenderer.windowed(window.document, scenes: [], continuity: window.continuity, from: 0.1, to: 0.4)
        #expect(nested.continuity.first?.members.count == 3)
        #expect(abs((nested.continuity.first?.end ?? -1) - 2) < 1e-9)
        var single = doc
        single.videoTrack = [doc.videoTrack[0]]
        let clips = resolve(single)
        #expect(CenterStageContinuity.runs(clips).isEmpty)
        var old = try #require(clips.first)
        let before = try JSONEncoder().encode(old)
        old.continuityClipID = nil
        old.continuityLayout = nil
        let current = RenderSegmentKey(start: 0, duration: old.duration, clips: clips,
            captions: [], overlays: [], masks: [:], fontFingerprints: [],
            captionStyle: CaptionStyle(), settings: single.renderSettings, encoder: [])
        var previous = current
        previous.clips = [old]
        #expect(try RenderSegmentCache.key(current) == RenderSegmentCache.key(previous))
        #expect(!String(decoding: before, as: UTF8.self).contains("continuity"))
    }

    @Test(arguments: ["implicit", "layout", "region", "invalid", "off"])
    func savedPieceUsesItsUnpausedInterpolation(route: String) throws {
        let doc = Self.document()
        try RenderContext.$settings.withValue(doc.renderSettings) {
            var moving = try #require(resolve(doc).first)
            moving.cameraPath = [.init(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                                 .init(t: 1, x: 0.2, y: 0.2, w: 0.6, h: 0.6)]
            switch route {
            case "layout": moving.continuityLayout = .fullScreen
            case "region": moving.areaRegion = FreeCropRect()
            case "invalid":
                moving.cameraPath?[0].h = 0.4
                moving.cameraPath?[1].h = 0.3
            case "off": moving.centerStage = false
            default: break
            }
            let expected = route == "implicit"
            #expect(CenterStageContinuity.savedPathUsesTransform(moving) == expected)
            let paused = CenterStageContinuity.pausedSavedPath(moving)
            #expect(paused.continuityTransform == expected)
            #expect(CenterStageContinuity.prepassArea(paused) != nil)
            #expect(paused.cameraPath == moving.cameraPath)
            var hold = moving
            hold.hold = true
            hold.cameraPath = HoldClipRules.cameraPath(try #require(moving.cameraPath), at: 1, duration: hold.duration)
            #expect(CenterStageContinuity.pausedSavedPath(hold).continuityTransform == expected)
            #expect(moving.continuityTransform == nil)
        }
    }

    @Test func emptyHighlightsNormalizeBothWindowAndRun() throws {
        var doc = Self.document()
        for index in doc.videoTrack.indices { doc.videoTrack[index].strikeHighlights = true }
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 2, to: 2.5)
        let rawRun = try #require(window.continuity.first)
        let rawVisible = try #require(resolve(window.document).first)
        let visible = CenterStageContinuity.normalizingStrikeHighlights(rawVisible, tracks: [])
        #expect(rawRun.contains(visible))
        let run = CenterStageContinuity.normalizingStrikeHighlights(rawRun, tracks: [rawVisible.sourcePath: []])
        #expect(run.contains(visible))
        #expect(run.template.strikeHighlights == nil)
        #expect(run.pieces?.allSatisfy { $0.strikeHighlights == nil && $0.strikeTracks == nil } == true)
        let full = CenterStageContinuity.runs(resolve(doc).map {
            CenterStageContinuity.normalizingStrikeHighlights($0, tracks: [])
        })
        #expect(full.first?.members.map(\.id) == run.members.map(\.id))
        #expect(abs((full.first?.start ?? -1) - run.start) < 1e-9)
        #expect(abs((full.first?.end ?? -1) - run.end) < 1e-9)
    }

    @Test(arguments: [false, true])
    func insertedCompanionEdgeHoldJoins(before: Bool) throws {
        var owner = Self.document().videoTrack[0]
        owner.duration = 3
        owner.sourceEnd = 3
        var companion = owner
        companion.uid = UUID()
        companion.track = 1
        companion.sourceStart = 10
        companion.startTime = before ? 0.9 : 0
        companion.duration = before ? 2 : 1.1
        companion.sourceEnd = 10 + companion.duration
        let document = Fixtures.timelineDocument(clips: [owner, companion])
        let result = try #require(TimelinePauseRules.insert([
            .init(time: 1, duration: 0.8, owner: owner.uid)
        ], into: document, resolve: { $0 }))
        let held = try #require(result.document.videoTrack.first { $0.track == 1 && $0.hold == true })
        let heldSource = try #require(held.sourceStart)
        #expect(abs(heldSource - (before ? 10 : 11.099)) < 1e-9)
        let runs = CenterStageContinuity.runs(resolve(result.document))
        let run = try #require(runs.first { $0.template.track == 1 })
        #expect(run.members.count == 2)
        #expect(run.members.contains { $0.id == held.uid })
    }

    @Test(arguments: ["aspect", "content", "unknown", "valid"])
    func storedPathUsesPrepassApplicability(kind: String) throws {
        let doc = Self.document()
        try RenderContext.$settings.withValue(doc.renderSettings) {
            var clips = resolve(doc)
            for i in clips.indices {
                clips[i].areaRegion = FreeCropRect()
                clips[i].cameraPath = [.init(t: 0, x: 0, y: 0, w: kind == "aspect" ? 0.5 : 1, h: 1),
                                       .init(t: 2, x: 0, y: 0, w: kind == "aspect" ? 0.5 : 1, h: 1)]
                if kind == "content" { MultitrackRenderer.applyContentWindow(.init(wFrac: 0.6), to: &clips[i]) }
            }
            let size: CGSize? = kind == "unknown" ? nil : CGSize(width: 1280, height: 720)
            let accepted = Set(clips.filter { CenterStageContinuity.storedPathApplies($0, sourceSize: size) }
                .compactMap(\.continuityClipID))
            #expect(accepted.count == (kind == "valid" ? 3 : 0))
            let runs = CenterStageContinuity.runs(clips, ignoringStoredPaths: true, excluding: accepted)
            #expect(runs.count == (kind == "valid" ? 0 : 1))
            if kind != "valid" { #expect(runs.first?.members.count == 3) }
        }
    }

    private actor ContinuationGate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait(started: @Sendable () -> Void) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started()
            }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    @Test func sharedUnionSurvivesOneCancelledWaiter() async throws {
        let folder = try TempDirectory()
        let cache = RenderSegmentCache(directory: folder.url)
        let calls = Mutex(0)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let producer: @Sendable () async throws -> CenterStageContinuity.Outcome = {
            calls.withLock { $0 += 1 }
            started.continuation.yield(())
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return .init(failure: "no subject")
        }
        let joined = AsyncStream<Void>.makeStream()
        let requests = Mutex(0)
        defer { release.continuation.finish(); started.continuation.finish(); joined.continuation.finish() }
        try await CenterStageContinuity.$unionRequestObserver.withValue({
            let count = requests.withLock { $0 += 1; return $0 }
            if count == 2 { joined.continuation.yield(()) }
        }) {
            let first = Task { try await cache.continuousPath(key: "union", cacheEnabled: true, produce: producer) }
            for await _ in started.stream { break }
            let second = Task { try await cache.continuousPath(key: "union", cacheEnabled: true, produce: producer) }
            for await _ in joined.stream { break }
            first.cancel()
            release.continuation.finish()
            let result = try await second.value
            #expect(result.outcome.failure == "no subject")
            do {
                _ = try await first.value
                Issue.record("Cancelled waiter returned a successful result")
            } catch is CancellationError { }
            #expect(calls.withLock { $0 } == 1)
            let cached = try await cache.continuousPath(key: "union", cacheEnabled: true, produce: producer)
            #expect(cached.reused && cached.outcome.failure == "no subject")
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test func concurrentUncachedUnionsCoalesce() async throws {
        let folder = try TempDirectory()
        let cache = RenderSegmentCache(directory: folder.url)
        let calls = Mutex(0)
        let release = AsyncStream<Void>.makeStream()
        let requests = Mutex(0)
        defer { release.continuation.finish() }
        let results = try await CenterStageContinuity.$unionRequestObserver.withValue({
            let count = requests.withLock { $0 += 1; return $0 }
            if count == 12 { release.continuation.finish() }
        }) {
            try await withThrowingTaskGroup(of: String?.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        let result = try await cache.continuousPath(key: "same-union", cacheEnabled: false) {
                            calls.withLock { $0 += 1 }
                            for await _ in release.stream { break }
                            return .init(failure: "no reusable path")
                        }
                        return result.outcome.failure
                    }
                }
                var results: [String?] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        #expect(results.count == 12 && results.allSatisfy { $0 == "no reusable path" })
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func allWaitersCancelReplacementSurvivesOldOwnerCompletion() async throws {
        let folder = try TempDirectory()
        let cache = RenderSegmentCache(directory: folder.url)
        let oldGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let newGate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let oldStarted = AsyncStream<Void>.makeStream()
        let newStarted = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let requests = Mutex(0)
        let calls = Mutex(0)
        defer {
            oldStarted.continuation.finish(); newStarted.continuation.finish()
            joined.continuation.finish(); cancelled.continuation.finish()
        }
        let oldProducer: @Sendable () async throws -> CenterStageContinuity.Outcome = {
            calls.withLock { $0 += 1 }
            await withCheckedContinuation { continuation in
                oldGate.withLock { $0 = continuation }
                oldStarted.continuation.yield(())
            }
            // Deliberately ignores cancellation, as a late Vision result can.
            return .init(failure: "stale owner")
        }
        try await CenterStageContinuity.$unionCancellationObserver.withValue({ cancelled.continuation.yield(()) }) {
            try await CenterStageContinuity.$unionRequestObserver.withValue({
                let count = requests.withLock { $0 += 1; return $0 }
                if count == 2 || count == 4 { joined.continuation.yield(()) }
            }) {
                let first = Task { try await cache.continuousPath(key: "same", cacheEnabled: true, produce: oldProducer) }
                for await _ in oldStarted.stream { break }
                let second = Task { try await cache.continuousPath(key: "same", cacheEnabled: true, produce: oldProducer) }
                for await _ in joined.stream { break }
                first.cancel(); second.cancel()
                for await _ in cancelled.stream { break }
                let replacement = Task {
                    try await cache.continuousPath(key: "same", cacheEnabled: true) {
                        calls.withLock { $0 += 1 }
                        await withCheckedContinuation { continuation in
                            newGate.withLock { $0 = continuation }
                            newStarted.continuation.yield(())
                        }
                        return .init(failure: "replacement")
                    }
                }
                for await _ in newStarted.stream { break }
                oldGate.withLock { $0?.resume(); $0 = nil }
                for task in [first, second] {
                    do { _ = try await task.value; Issue.record("Cancelled waiter succeeded") }
                    catch is CancellationError { }
                }
                let waiter = Task { try await cache.continuousPath(key: "same", cacheEnabled: true, produce: oldProducer) }
                for await _ in joined.stream { break }
                newGate.withLock { $0?.resume(); $0 = nil }
                let result = try await replacement.value
                let shared = try await waiter.value
                #expect(result.outcome.failure == "replacement")
                #expect(shared.reused && shared.outcome.failure == "replacement")
                #expect(calls.withLock { $0 } == 2)
                let cached = try await cache.continuousPath(key: "same", cacheEnabled: true, produce: oldProducer)
                #expect(cached.reused && cached.outcome.failure == "replacement")
            }
        }
    }

    @Test func cameraGridBoundsTheStrongestZoom() {
        let source = CGSize(width: 3840, height: 2160)
        let box = CGSize(width: 1080, height: 1920)
        func path(_ width: Double) -> [CameraPathKeyframe] {
            [.init(t: 0, x: 0, y: 0, w: 0.8, h: 0.8),
             .init(t: 2, x: 0, y: 0, w: width, h: width)]
        }
        #expect(ContinuityCameraGrid.choose(path: path(0.4), source: source, box: box) == .double)
        #expect(ContinuityCameraGrid.choose(path: path(0.15), source: source, box: box) == .single)
        #expect(ContinuityCameraGrid.choose(path: path(0.05), source: source, box: box) == .crop)
        let full = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 1, h: 1)]
        #expect(ContinuityCameraGrid.choose(path: full, source: source, box: source) == .double)
        #expect(ContinuityCameraGrid.double.cacheSuffix.isEmpty)
        #expect(ContinuityCameraGrid.single.cacheSuffix != ContinuityCameraGrid.crop.cacheSuffix)
        #expect(!ContinuityCameraGrid.single.cacheSuffix.isEmpty)
        #expect(!ContinuityCameraGrid.crop.cacheSuffix.isEmpty)
    }

    @Test("A mixed candidate's full tracked run alone chooses the window grid", arguments: [0.2, 0.1, 0.04])
    func mixedSavedAndTrackedWindowGrid(width: Double) async throws {
        var doc = Self.document()
        doc.videoTrack[2].cameraPath = [.init(t: 0, x: 0.4, y: 0.4, w: 0.01, h: 0.01),
                                      .init(t: 1, x: 0.4, y: 0.4, w: 0.01, h: 0.01)]
        let candidates = CenterStageContinuity.runs(resolve(doc), ignoringStoredPaths: true)
        let fullRuns = await CenterStageContinuity.applicableRuns(candidates)
        let full = try #require(fullRuns.first)
        #expect(fullRuns.count == 1 && full.members.count == 2)
        #expect(full.pieces?.allSatisfy { $0.cameraPath == nil } == true)
        #expect(!full.members.contains { $0.id == doc.videoTrack[2].uid })
        let tracked = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: width, h: width),
                       .init(t: 1, x: 0.2, y: 0.2, w: 0.4, h: 0.4)]
        let source = CGSize(width: 1280, height: 720), box = CGSize(width: 640, height: 360)
        let fullGrid = ContinuityCameraGrid.choose(path: tracked, source: source, box: box)
        let expected: ContinuityCameraGrid = width > 0.15 ? .double : width > 0.05 ? .single : .crop
        #expect(fullGrid == expected)
        for lower in [0.75, 1.2, 1.9] {
            let window = MultitrackRenderer.windowed(doc, scenes: [], from: lower, to: lower + 0.2)
            let previewRuns = await CenterStageContinuity.applicableRuns(window.continuity)
            let preview = try #require(previewRuns.first)
            let previewIDs = preview.members.map(\.id), fullIDs = full.members.map(\.id)
            #expect(previewIDs == fullIDs)
            #expect(abs(preview.start - full.start) < 1e-9)
            #expect(abs(preview.end - full.end) < 1e-9)
            // Tracking receives the same full source range, including the
            // strongest zoom before the window, so it returns the same path.
            let previewGrid = ContinuityCameraGrid.choose(path: tracked, source: source, box: box)
            #expect(previewGrid == fullGrid)
            let windowClips = resolve(window.document)
            if lower > 1.8 {
                #expect(windowClips.allSatisfy { !preview.containsSourcePiece($0) })
            } else {
                #expect(windowClips.allSatisfy { preview.containsSourcePiece($0) })
            }
        }
    }

    @Test("Dense crop sampling stays below 0.5% between every pair of knots", arguments: [false, true])
    func denseTransformSampling(reverse: Bool) {
        let path = [CameraPathKeyframe(t: 0, x: 0.02, y: 0.02,
                        w: reverse ? 0.01 : 0.8, h: reverse ? 0.01 : 0.8),
                    .init(t: 2, x: 0.1, y: 0.1, w: reverse ? 0.8 : 0.01, h: reverse ? 0.8 : 0.01)]
        let dense = ContinuityCameraGrid.resampled(path)
        #expect(dense.count > 2)
        for (a, b) in zip(dense, dense.dropFirst()) {
            let ratio = max(a.w / b.w, b.w / a.w)
            #expect(ratio <= ContinuityCameraGrid.maximumScaleRatio + 1e-12)
            for step in 0...100 {
                let fraction = Double(step) / 100
                let time = a.t + fraction * (b.t - a.t)
                let expected = 1 / ((1 - time / 2) / path[0].w + time / 2 / path[1].w)
                let actual = a.w + fraction * (b.w - a.w)
                #expect(abs(actual / expected - 1) <= 0.005)
            }
        }
    }

    @Test func degradedGridsKeepTheRunLevelAndOrdinaryClock() {
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        RenderContext.$settings.withValue(RenderSettings(preset: .custom, customWidth: 1080, customHeight: 1920)) {
            let source = CGSize(width: 3840, height: 2160)
            let held = [CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.4, h: 0.4)]
            let single = AreaFramer.pathFilter(keyframes: held, source: source, area: area,
                transformInterpolation: true, continuityGrid: .single)
            #expect(single.contains("max(1080,round(1080*"))
            #expect(!single.contains("max(2160,"))
            #expect(!single.contains("fps="))
            let crop = AreaFramer.pathFilter(keyframes: held, source: source, area: area,
                transformInterpolation: true, continuityGrid: .crop)
            #expect(crop.hasPrefix("crop@area="))
            #expect(!crop.contains("fps="))
            let ordinary = AreaFramer.pathFilter(keyframes: held, source: source, area: area)
            #expect(ordinary.contains("fps=30"))
        }
    }

    @Test func pausedGraphInterpolatesZoomInTransformSpace() {
        let path = [CameraPathKeyframe(t: 0, x: 0.1, y: 0.1, w: 0.8, h: 0.8),
                    .init(t: 2, x: 0.25, y: 0.25, w: 0.4, h: 0.4)]
        let quarter = CenterStageContinuity.transformSlice(path, from: 0.5, duration: 0)
        let width = quarter.first?.w ?? 0
        #expect(abs(width - 0.64) < 1e-9)
        let area = ScreenCropArea(name: "Full", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
            .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let ordinary = AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1280, height: 720), area: area)
        let fallback = AreaFramer.pathFilter(keyframes: path, source: CGSize(width: 1280, height: 720), area: area,
            transformInterpolation: true)
        #expect(fallback.contains("1.250000000"))
        #expect(fallback.contains("exact=1"))
        #expect(!ordinary.contains("exact=1"))
    }

    @Test(arguments: [CGSize(width: 1000, height: 1000), CGSize(width: 900, height: 1600)])
    func savedPathValidationUsesActualSourceOnBothRoutes(size: CGSize) throws {
        let doc = Self.document()
        try RenderContext.$settings.withValue(doc.renderSettings) {
            var moving = try #require(resolve(doc).first)
            let aspect = Double(RenderEngine.outputWidth) / Double(RenderEngine.outputHeight)
            let width = min(0.8, 0.8 * size.height / size.width * aspect)
            let height = width * size.width / size.height / aspect
            moving.cameraPath = [0, 1].map { .init(t: $0, x: 0, y: 0, w: width, h: height) }
            #expect(CenterStageContinuity.storedPathApplies(moving, sourceSize: size))
            #expect(CenterStageContinuity.savedPathUsesTransform(moving, sourceSize: size))
            let paused = CenterStageContinuity.pausedSavedPath(moving, sourceSize: size)
            #expect(paused.continuityTransform == true)
            #expect(CenterStageContinuity.storedPathApplies(paused, sourceSize: size))
            moving.cameraPath = [0, 1].map { .init(t: $0, x: 0, y: 0, w: 0.8, h: 0.8) }
            #expect(!CenterStageContinuity.storedPathApplies(moving, sourceSize: size))
            #expect(!CenterStageContinuity.savedPathUsesTransform(moving, sourceSize: size))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func vipTrackingRejectsSavedPathsOnEveryRoute(vip: Bool, area: Bool) throws {
        let doc = Self.document()
        try RenderContext.$settings.withValue(doc.renderSettings) {
            var clip = try #require(resolve(doc).first)
            var recipe = CropRecipe(kind: .talker)
            recipe.centerStageVIPs = vip
            clip.framingPlan = .tracked(recipe, region: nil, fit: .fill, feather: 0.08, blur: 0.5)
            clip.cameraPath = [0, 1].map { .init(t: $0, x: 0.1, y: 0.1, w: 0.8, h: 0.8) }
            if area { clip.areaRegion = FreeCropRect() }
            let size = CGSize(width: 1280, height: 720)
            #expect(CenterStageContinuity.storedPathApplies(clip, sourceSize: size) == !vip)
            let paused = CenterStageContinuity.pausedSavedPath(clip, sourceSize: size)
            #expect(CenterStageContinuity.storedPathApplies(paused, sourceSize: size) == !vip)
            var held = clip
            held.hold = true
            #expect(CenterStageContinuity.storedPathApplies(held, sourceSize: size) == !vip)
            // The slice of the clip's own tracked run is used, VIP or not.
            var generated = paused
            generated.continuityRunPath = true
            #expect(CenterStageContinuity.storedPathApplies(generated, sourceSize: size))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func vipSavedPathsStayInTrackingRuns(vip: Bool, failedProbe: Bool) async throws {
        let doc = Self.document()
        let clips = resolve(doc).map { clip in
            var clip = clip
            var recipe = CropRecipe(kind: .talker)
            recipe.centerStageVIPs = vip
            clip.framingPlan = .tracked(recipe, region: nil, fit: .fill, feather: 0.08, blur: 0.5)
            clip.cameraPath = [0, 1].map { .init(t: $0, x: 0.1, y: 0.1, w: 0.8, h: 0.8) }
            return clip
        }
        let first = try #require(clips.first)
        let candidates = CenterStageContinuity.runs(clips, ignoringStoredPaths: true)
        #expect(candidates.count == 1)
        let runs = await RenderContext.$settings.withValue(doc.renderSettings) {
            await CenterStageContinuity.applicableRuns(candidates, sourceSizes: [first.sourcePath:
                failedProbe ? .zero : CGSize(width: 1280, height: 720)])
        }
        #expect(runs.count == (vip ? 1 : 0))
        if vip { #expect(runs.first?.members.count == clips.count) }
    }

    @Test func fadedHighlightWindowStillBelongsToFullRun() throws {
        var doc = Self.document()
        for i in doc.videoTrack.indices { doc.videoTrack[i].strikeHighlights = true }
        let highlight = StrikeHighlightRules.Highlight(limb: [.zero, CGPoint(x: 0.5, y: 0.5)],
            target: CGPoint(x: 0.5, y: 0.5), radius: 0.1, cost: 0, limbSide: .left, usesArm: true, attackerOnLeft: true)
        let tracks = [StrikeHighlightRules.Track(keyframes: [.init(time: 0.1, highlight: highlight),
            .init(time: 0.2, highlight: highlight)], contact: 0.15, aspect: 16.0 / 9)]
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: 2, to: 2.5)
        let rawRun = try #require(window.continuity.first)
        let raw = try #require(resolve(window.document).first)
        let visible = CenterStageContinuity.normalizingStrikeHighlights(raw, tracks: tracks)
        let run = CenterStageContinuity.normalizingStrikeHighlights(rawRun, tracks: [raw.sourcePath: tracks])
        #expect(run.template.strikeHighlights == true)
        #expect(visible.strikeHighlights == nil)
        #expect(run.contains(visible))
        #expect(run.template.strikeTracks != nil) // Still part of render/cache evidence.
    }

}
