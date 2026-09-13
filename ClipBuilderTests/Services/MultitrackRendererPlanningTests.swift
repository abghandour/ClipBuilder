import Foundation
import Testing
@testable import Clip_Builder

@Suite("Multitrack renderer planning")
struct MultitrackRendererPlanningTests {
    @Test("clip resolution applies track settings and drops missing scenes")
    func resolveClips() {
        var valid = Fixtures.timelineClip(sceneID: 1, sourceStart: 2, duration: 4, track: 0, speed: 0.5)
        valid.position = nil
        valid.captions = "inherit"
        var missing = Fixtures.timelineClip(sceneID: 999, track: 1)
        missing.videoFile = nil
        missing.sourceStart = nil
        var document = Fixtures.timelineDocument(clips: [valid, missing])
        document.trackSettings[0] = TrackSettings(muted: true, defaultPosition: "center", captions: "bottom")

        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [Fixtures.scene()])
        #expect(resolved.count == 1)
        #expect(resolved[0].muted)
        #expect(resolved[0].effectivePosition == "center")
        #expect(resolved[0].captionsPosition == "bottom")
        #expect(resolved[0].speed == 0.5)
    }

    @Test("layered segments represent overlaps and omit gaps")
    func layeredSegments() {
        let clips = [
            resolved(start: 0, duration: 3, track: 0),
            resolved(start: 2, duration: 3, track: 1),
            resolved(start: 7, duration: 1, track: 0),
        ]
        let segments = MultitrackRenderer.buildLayeredSegments(clips)
        #expect(segments.map(\.start) == [0, 2, 3, 7])
        #expect(segments.map(\.end) == [2, 3, 5, 8])
        #expect(segments[1].clips.count == 2)
    }

    @Test("crop blocks split clips and discard tracks without an area")
    func cropBlocks() {
        var document = TimelineDocument()
        document.cropBlocks = [
            CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 2),
            CropBlockItem(layout: .fullScreen, startTime: 2, duration: 2),
        ]
        let trackZero = resolved(start: 0, duration: 4, track: 0)
        let trackOne = resolved(start: 0, duration: 4, track: 1)
        let pieces = MultitrackRenderer.applyCropBlocks([trackZero, trackOne], document: document)
        #expect(pieces.filter { $0.track == 0 }.count == 2)
        #expect(pieces.filter { $0.track == 1 }.count == 1)
        #expect(pieces.first { $0.track == 1 }?.duration == 2)
    }

    @Test("overlay planning preserves local clocks, gaps, transition windows and z-order")
    func overlayPlanning() {
        typealias Overlay = MultitrackRenderer.TimedOverlayPNG
        func overlay(_ start: Double, _ end: Double) -> Overlay {
            Overlay(png: URL(fileURLWithPath: "/overlay.png"), startTime: start, endTime: end,
                    transIn: "fade", transOut: "slide_up")
        }
        let first = resolved(start: 0, duration: 3, track: 0)
        var second = resolved(start: 3, duration: 3, track: 0)
        let hardCuts = MultitrackRenderer.buildLayeredSegments([first, second])
        let local = MultitrackRenderer.partitionOverlays([overlay(3.5, 5), overlay(0.5, 3)], segments: hardCuts)
        #expect(local.bySegment[1]?.first?.startTime == 0.5)
        #expect(local.bySegment[1]?.first?.endTime == 2)
        #expect(local.bySegment[1]?.first?.transOut == "slide_up")
        // An inclusive end exactly at a cut belongs on the first frame of
        // the next segment too, so it must stay in the full-timeline pass.
        #expect(local.remaining.count == 1)
        second.transIn = "fade"
        let transitions = MultitrackRenderer.buildLayeredSegments([first, second])
        let mixed = MultitrackRenderer.partitionOverlays([overlay(0.2, 1), overlay(2.5, 3.5)], segments: transitions)
        #expect(mixed.bySegment[0]?.count == 1)
        #expect(mixed.remaining.count == 1)
        let stacked = MultitrackRenderer.partitionOverlays([overlay(0, 4), overlay(0.5, 1)], segments: hardCuts)
        #expect(stacked.bySegment.isEmpty)
        #expect(stacked.remaining.count == 2)
        let gaps = [MultitrackRenderer.Segment(start: 0, end: 2, clips: []),
                    MultitrackRenderer.Segment(start: 2, end: 5, clips: [first])]
        #expect(MultitrackRenderer.partitionOverlays([overlay(0.5, 1)], segments: gaps).remaining.count == 1)
    }

    // MARK: - B-roll (cutaways)

    private func cutawayClip(start: Double, duration: Double, track: Int,
                             coverAll: Bool = false,
                             audio: CutawayAudio = .muted) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: duration,
                                         startTime: start, track: track)
        clip.videoFile = "/tmp/broll.mp4"
        clip.role = .cutaway
        clip.coverAllAreas = coverAll
        clip.cutawayAudio = audio
        clip.enforceCutawayRules()
        return clip
    }

    @Test("placements draw main, cutaway, cover-all and bumper in one order, and the masks follow it")
    func placementOrderAndMasks() throws {
        var document = Fixtures.timelineDocument(clips: [])
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"),
                                             startTime: 0, duration: 10)]
        let mainZero = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6, track: 0)
        let mainOne = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 6, track: 1)
        let cutaway = cutawayClip(start: 0, duration: 6, track: 0)
        let cover = cutawayClip(start: 0, duration: 6, track: 0, coverAll: true)
        document.videoTrack = [cover, mainOne, cutaway, mainZero]

        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let segment = try #require(MultitrackRenderer.buildLayeredSegments(resolved).first)
        let placements = MultitrackRenderer.placements(for: segment)
        #expect(placements.count == 4)
        #expect(placements.map(\.originKey) == [mainZero.originKey, cutaway.originKey,
                                                mainOne.originKey, cover.originKey],
                "track 0 main, track 0 B-roll, track 1 main, then the cover-all B-roll on top")
        #expect(placements.last?.fillCanvas == true && placements.last?.screenCrop == nil)

        // Masks are keyed by the index into THIS list, never re-sorted.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        let masks = MultitrackRenderer.maskFiles(for: placements, in: scratch)
        #expect(masks[3] == nil, "a cover-all cutaway is unmasked")
        #expect(masks[0] != nil && masks[0] == masks[1],
                "the track's main clip and its B-roll share one area mask")
        #expect(masks[2] != nil && masks[2] != masks[0],
                "track 1 gets its own area, keyed by its index in this order")
        #expect(placements[0].screenCrop == placements[1].screenCrop,
                "a cutaway inherits the area of its own track")
        #expect(placements[2].screenCrop != placements[0].screenCrop)
    }

    @Test("a bumper draws above every track when it shares a segment")
    func bumperLayerIsHighest() {
        let bumper = MultitrackRenderer.ResolvedClip(
            sourcePath: "/bumper.mp4", videoID: nil, sourceStart: 0, startTime: 0, duration: 2,
            track: 0, wide: false, bumper: true, muted: false, transIn: nil, transOut: nil,
            effectivePosition: "center", effectiveCropXFrac: nil, freeCrops: nil,
            screenCrop: nil, areaWindow: nil, captionsPosition: nil)
        var cover = resolved(start: 0, duration: 2, track: 0)
        cover.role = .cutaway
        cover.coverAllAreas = true
        #expect(MultitrackRenderer.placementLayer(for: bumper)
                > MultitrackRenderer.placementLayer(for: cover))
    }

    @Test("draw order survives a crop split and a gap split")
    func orderStableAcrossSplits() throws {
        var document = Fixtures.timelineDocument(clips: [])
        let lower = cutawayClip(start: 0, duration: 6, track: 0)
        var upper = cutawayClip(start: 2, duration: 4, track: 0)
        upper.videoFile = "/tmp/broll2.mp4"
        document.videoTrack = [upper, lower]
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 3),
                               CropBlockItem(layout: .fullScreen, startTime: 3, duration: 3)]

        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.count == 4, "both cutaways are cut at the crop boundary")
        for segment in MultitrackRenderer.buildLayeredSegments(resolved)
        where segment.clips.count == 2 {
            let placements = MultitrackRenderer.placements(for: segment)
            #expect(placements.map(\.originKey) == [lower.originKey, upper.originKey],
                    "the later-starting cutaway stays on top in every piece")
        }

        // A gap split makes two genuinely separate pieces of one clip; the
        // tail's later start puts it on top, which is what we want.
        var gapped = Fixtures.timelineDocument(clips: [cutawayClip(start: 0, duration: 6, track: 0)])
        BumperPlanner.insertGap(in: &gapped, at: 3, duration: 0)
        let pieces = MultitrackRenderer.resolveClips(document: gapped, scenes: [])
        #expect(pieces.count == 2)
        #expect(MultitrackRenderer.placementLayer(for: pieces[0])
                == MultitrackRenderer.placementLayer(for: pieces[1]))
        let ordered = MultitrackRenderer.orderedPlacements(
            MultitrackRenderer.placements(for: MultitrackRenderer.Segment(
                start: 3, end: 6, clips: [pieces[1], pieces[0]])))
        #expect(ordered.map(\.originalStart) == [0, 3], "the tail draws after its head")
    }

    @Test("clips that agree on layer, start and origin still order by document position")
    func totalOrderByDocumentIndex() {
        var first = resolved(start: 0, duration: 2, track: 0)
        first.originKey = "same"
        first.documentIndex = 3
        var second = first
        second.documentIndex = 1
        second.sourcePath = "/tmp/second.mp4"
        let ordered = MultitrackRenderer.placements(for: MultitrackRenderer.Segment(
            start: 0, end: 2, clips: [first, second]))
        #expect(ordered.map(\.sourcePath) == ["/tmp/second.mp4", "/tmp/fixture.mp4"])
    }

    @Test("a cover-all cutaway keeps its place where its track has no area")
    func coverAllSurvivesMissingArea() throws {
        var document = Fixtures.timelineDocument(clips: [])
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 10)]
        let area = cutawayClip(start: 0, duration: 4, track: 2)
        let cover = cutawayClip(start: 0, duration: 4, track: 2, coverAll: true)
        document.videoTrack = [area, cover]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.count == 1, "the area cutaway on a track without an area is dropped")
        let survivor = try #require(resolved.first)
        #expect(survivor.originKey == cover.originKey)
        #expect(survivor.fillCanvas && survivor.screenCrop == nil)
    }

    @Test("a muted cutaway never reaches the mix; a mixed one does, with its gain")
    func cutawayAudioInTheMix() throws {
        var document = Fixtures.timelineDocument(clips: [])
        var muted = cutawayClip(start: 0, duration: 4, track: 0)
        muted.volume = 3
        var mixed = cutawayClip(start: 0, duration: 4, track: 0, audio: .mixed)
        mixed.videoFile = "/tmp/broll2.mp4"
        mixed.volume = 3
        let main = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4, track: 0)
        document.videoTrack = [main, muted, mixed]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let segment = try #require(MultitrackRenderer.buildLayeredSegments(resolved).first)
        let placements = MultitrackRenderer.placements(for: segment)
        let mutedPlacement = try #require(placements.first { $0.originKey == muted.originKey })
        let mixedPlacement = try #require(placements.first { $0.originKey == mixed.originKey })
        let mainPlacement = try #require(placements.first { $0.originKey == main.originKey })
        #expect(mutedPlacement.muted, "a muted cutaway is never mixed")
        #expect(!mixedPlacement.muted && !mainPlacement.muted)
        #expect(MultitrackRenderer.audioGainFilter(for: mixedPlacement) == "volume=0.600,")
        #expect(MultitrackRenderer.audioGainFilter(for: mainPlacement) == "",
                "an ordinary clip has no per-clip gain")
    }

    @Test("only a mixed-in cutaway changes how the segment's audio is mixed")
    func audioMixKeepsUnityGain() {
        let single = MultitrackRenderer.audioMixFilter(labels: ["[a0]"], cutawayAudio: false)
        #expect(single.filters.isEmpty && single.source == "[a0]")

        // Without B-roll audio the mix is exactly what it always was.
        let plain = MultitrackRenderer.audioMixFilter(labels: ["[a0]", "[a1]"], cutawayAudio: false)
        #expect(plain.filters.first == "[a0][a1]amix=inputs=2:duration=longest:dropout_transition=0[amix]")

        let withCutaway = MultitrackRenderer.audioMixFilter(labels: ["[a0]", "[a1]"], cutawayAudio: true)
        let filter = withCutaway.filters.first ?? ""
        #expect(filter.contains("amix=inputs=2"))
        #expect(filter.contains("normalize=0"), "amix would otherwise halve both inputs")
        #expect(withCutaway.source == "[amix]")

        let silence = MultitrackRenderer.audioMixFilter(labels: [], cutawayAudio: true)
        #expect(silence.source == "[asilent]" && silence.filters.count == 1)
    }

    @Test("a silent cutaway's file does not change how the segment is mixed")
    func mixSwitchFollowsTheStreamsThatContribute() {
        func placement(role: ClipRole, muted: Bool) -> MultitrackRenderer.Placement {
            MultitrackRenderer.Placement(sourcePath: "/tmp/x.mp4", sourceStart: 0, sourceDur: 1,
                                         isWide: false, layer: 0, position: "center",
                                         muted: muted, role: role, startTime: 0)
        }
        let main = placement(role: .main, muted: false)
        let mixedCutaway = placement(role: .cutaway, muted: false)
        let mutedCutaway = placement(role: .cutaway, muted: true)

        #expect(MultitrackRenderer.mixNeedsUnityGain([main, mixedCutaway]))
        #expect(!MultitrackRenderer.mixNeedsUnityGain([main, mutedCutaway]))
        // A mixed cutaway whose source carries no audio never reaches the
        // list of contributors, so the mix keeps amix's default.
        #expect(!MultitrackRenderer.mixNeedsUnityGain([main]),
                "a cutaway with no audio stream contributes nothing")
    }

    @Test("a pausing bumper's split leaves one dissolve, not two")
    func gapSplitKeepsOneDissolve() throws {
        var broll = cutawayClip(start: 0, duration: 6, track: 0)
        broll.fadeIn = 1
        broll.fadeOut = 1
        broll.enforceCutawayRules()
        var document = Fixtures.timelineDocument(clips: [broll])
        BumperPlanner.insertGap(in: &document, at: 3, duration: 2)
        let pieces = document.cutaways(inTrack: 0)
        #expect(pieces.count == 2)
        #expect(pieces[0].fadeIn == 1 && pieces[0].fadeOut == 0, "the head keeps the way in")
        #expect(pieces[1].fadeIn == 0 && pieces[1].fadeOut == 1, "the tail keeps the way out")
    }

    @Test("a cutaway boundary does not retrigger the main clip's transition")
    func joinTransitionsIgnoreCutaways() throws {
        var document = Fixtures.timelineDocument(clips: [])
        var main = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 8, track: 0)
        main.transIn = "fade"
        main.transOut = "slide_up"
        document.videoTrack = [main, cutawayClip(start: 3, duration: 2, track: 0)]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let segments = MultitrackRenderer.buildLayeredSegments(resolved)
        #expect(segments.map(\.start) == [0, 3, 5])

        let joins = segments.dropFirst().enumerated().map { index, segment -> String? in
            let incoming = MultitrackRenderer.joinClip(in: segment.clips)
            let outgoing = MultitrackRenderer.joinClip(in: segments[index].clips)
            #expect(incoming?.role == .main && outgoing?.role == .main)
            let entry = incoming.flatMap { abs($0.originalStart - segment.start) < 0.001 ? $0.transIn : nil }
            let exit = outgoing.flatMap { abs($0.originalEnd - segment.start) < 0.001 ? $0.transOut : nil }
            return entry ?? exit
        }
        #expect(joins == [nil, nil], "the boundaries the cutaway made are inside one clip")
    }

    @Test("a real cut takes the incoming transition in, else the outgoing transition out")
    func ordinaryJoinsUseBothEnds() throws {
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4, track: 0)
        first.transOut = "slide_up"
        var second = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4,
                                           startTime: 4, track: 0)
        second.videoFile = "/tmp/second.mp4"
        let document = Fixtures.timelineDocument(clips: [first, second])
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        let segments = MultitrackRenderer.buildLayeredSegments(resolved)
        #expect(segments.count == 2)
        let incoming = try #require(MultitrackRenderer.joinClip(in: segments[1].clips))
        let outgoing = try #require(MultitrackRenderer.joinClip(in: segments[0].clips))
        let entry = abs(incoming.originalStart - segments[1].start) < 0.001 ? incoming.transIn : nil
        let exit = abs(outgoing.originalEnd - segments[1].start) < 0.001 ? outgoing.transOut : nil
        #expect(entry == nil && exit == "slide_up")
        #expect((entry ?? exit) == "slide_up", "the join falls back to the outgoing clip")
    }

    @Test("a dissolve keeps its place across a split and is omitted where it does not reach")
    func fadeOffsetsAcrossASplit() throws {
        var document = Fixtures.timelineDocument(clips: [])
        var broll = cutawayClip(start: 0, duration: 6, track: 0)
        broll.fadeIn = 2
        broll.fadeOut = 2
        broll.enforceCutawayRules()
        document.videoTrack = [broll]
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 3),
                               CropBlockItem(layout: .fullScreen, startTime: 3, duration: 3)]
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [])
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.originalStart == 0 && $0.originalEnd == 6 })

        let segments = MultitrackRenderer.buildLayeredSegments(resolved)
        let first = MultitrackRenderer.placements(for: segments[0])[0]
        #expect(first.fadeIn == MultitrackRenderer.Fade(start: 0, duration: 2))
        #expect(first.fadeOut == nil, "the fade out is entirely in the second half")
        let second = MultitrackRenderer.placements(for: segments[1])[0]
        #expect(second.fadeIn == nil, "the fade in finished before this piece")
        #expect(second.fadeOut == MultitrackRenderer.Fade(start: 1, duration: 2))

        // A fade that straddles a boundary keeps a negative start in the
        // plan, but the filter it produces starts at 0 for the remainder:
        // ffmpeg's `fade` cannot start before the segment does.
        let straddling = try #require(MultitrackRenderer.fade(
            into: MultitrackRenderer.Segment(start: 1, end: 3, clips: []), start: 0, seconds: 2))
        #expect(straddling == MultitrackRenderer.Fade(start: -1, duration: 2))
        var continuing = MultitrackRenderer.Placement(
            sourcePath: "/tmp/broll.mp4", sourceStart: 0, sourceDur: 2, isWide: false,
            layer: 1, position: "center", muted: true, role: .cutaway,
            fadeIn: straddling, startTime: 0)
        let filter = try #require(MultitrackRenderer.fadeFilters(for: continuing, index: 0,
                                                                masked: true).filters.first)
        // The envelope CONTINUES: the second half of the clip is padded by
        // the second of fade that already ran, the whole two-second fade
        // runs over that padded timeline, and the padding is cut off again,
        // so the segment opens half way up the ramp instead of at zero.
        #expect(filter.contains("tpad=start_duration=1.000:start_mode=clone"))
        #expect(filter.contains("fade=t=in:alpha=1:st=0.000:d=2.000"))
        #expect(filter.contains("trim=start=1.000,setpts=PTS-STARTPTS"))
        #expect(!filter.contains("st=-"), "a negative start is not valid ffmpeg")
        let padIndex = try #require(filter.range(of: "tpad")).lowerBound
        let fadeIndex = try #require(filter.range(of: "fade=t=in")).lowerBound
        let trimIndex = try #require(filter.range(of: "trim=start")).lowerBound
        #expect(padIndex < fadeIndex && fadeIndex < trimIndex, "pad, fade, then trim")

        // A dissolve out that began before this segment finishes it off the
        // same way, over its own full duration.
        continuing.fadeIn = nil
        continuing.fadeOut = MultitrackRenderer.Fade(start: -0.5, duration: 2)
        let out = try #require(MultitrackRenderer.fadeFilters(for: continuing, index: 0,
                                                             masked: true).filters.first)
        #expect(out.contains("tpad=start_duration=0.500:start_mode=clone"))
        #expect(out.contains("fade=t=out:alpha=1:st=0.000:d=2.000"))
        #expect(out.contains("trim=start=0.500"))

        // A window that is over contributes nothing at all.
        continuing.fadeOut = MultitrackRenderer.Fade(start: -3, duration: 2)
        #expect(MultitrackRenderer.fadeFilters(for: continuing, index: 0, masked: true).filters.isEmpty)

        // A start a hair below zero is rounding noise, not a continuation.
        continuing.fadeOut = nil
        continuing.fadeIn = MultitrackRenderer.Fade(start: -0.0004, duration: 1)
        let nearZero = try #require(MultitrackRenderer.fadeFilters(for: continuing, index: 0,
                                                                  masked: true).filters.first)
        #expect(nearZero.contains("fade=t=in:alpha=1:st=0.000:d=1.000"))
        #expect(!nearZero.contains("st=-") && !nearZero.contains("tpad"))
    }

    @Test("the dissolve filter runs after the mask, which is what makes the alpha")
    func fadeFiltersFollowTheMask() throws {
        var placement = MultitrackRenderer.Placement(
            sourcePath: "/tmp/broll.mp4", sourceStart: 0, sourceDur: 2, isWide: false,
            layer: 1, position: "center", muted: true,
            role: .cutaway, fadeIn: MultitrackRenderer.Fade(start: 0, duration: 1),
            fadeOut: MultitrackRenderer.Fade(start: 1, duration: 1),
            startTime: 0)
        let masked = MultitrackRenderer.fadeFilters(for: placement, index: 2, masked: true)
        let maskedFilter = try #require(masked.filters.first)
        #expect(maskedFilter.hasPrefix("[vm2]"), "it consumes the alphamerge output")
        #expect(!maskedFilter.contains("yuva420p"), "the mask already made an alpha channel")
        #expect(maskedFilter.contains("fade=t=in:alpha=1:st=0.000:d=1.000"))
        #expect(maskedFilter.contains("fade=t=out:alpha=1:st=1.000:d=1.000"))
        #expect(maskedFilter.hasSuffix("[vf2]") && masked.label == "vf2")

        let unmasked = MultitrackRenderer.fadeFilters(for: placement, index: 0, masked: false)
        let unmaskedFilter = try #require(unmasked.filters.first)
        #expect(unmaskedFilter.hasPrefix("[v0]format=yuva420p,fade=t=in"))

        placement.fadeIn = nil
        placement.fadeOut = nil
        let none = MultitrackRenderer.fadeFilters(for: placement, index: 0, masked: true)
        #expect(none.filters.isEmpty && none.label == "vm0", "no dissolve, no extra step")
    }

    private func resolved(start: Double, duration: Double, track: Int) -> MultitrackRenderer.ResolvedClip {
        MultitrackRenderer.ResolvedClip(
            sourcePath: "/tmp/fixture.mp4", videoID: 1, sourceStart: 0,
            startTime: start, duration: duration, track: track, wide: false,
            muted: false, transIn: nil, transOut: nil, effectivePosition: "center",
            effectiveCropXFrac: nil, freeCrops: nil, screenCrop: nil,
            areaWindow: nil, captionsPosition: nil
        )
    }
}

extension MultitrackRendererPlanningTests {
    @Test("every catalog builder matches its v1 expression", arguments: EffectCatalog.presets)
    func effectExpressions(_ preset: EffectCatalog.Preset) throws {
        let expected: [String: String] = [
            "none": "", "bw": "hue=s=0", "noir": "hue=s=0,eq=contrast=1.35",
            "sepia": "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131",
            "faded": "curves=preset=lighter,eq=contrast=0.85:brightness=0.04",
            "vivid": "eq=saturation=1.45:contrast=1.08",
            "warm": "colortemperature=temperature=4500", "cool": "colortemperature=temperature=8500",
            "vintage": "curves=preset=vintage,vignette=angle=PI/5,noise=alls=10:allf=t+u",
            "invert": "negate", "duotone": "hue=s=0,lutrgb=r='0+val*1':g='0+val*1':b='0+val*1'",
            "brightness": "eq=brightness=0", "contrast": "eq=contrast=1", "saturation": "eq=saturation=1",
            "gamma": "eq=gamma=1", "temperature": "colortemperature=temperature=6500:mix=1",
            "vignette": "vignette=angle=PI/2*0.5", "sharpen": "unsharp=5:5:1", "blur": "gblur=sigma=5",
            "pixelate": EffectCatalog.supportsPixelize ? "pixelize=w=12:h=12"
                : "scale=iw/12:ih/12,scale=iw*12:ih*12:flags=neighbor",
            "posterize": "lutrgb=r='trunc(val/64)*64':g='trunc(val/64)*64':b='trunc(val/64)*64'",
            "grain": "noise=alls=10:allf=t+u", "rgbsplit": "rgbashift=rh=4:bh=-4",
            "vhs": "chromashift=cbh=4:crh=-4,noise=alls=14:allf=t+u,huesaturation=saturation=-0.2",
            "edges": "edgedetect=mode=colormix:high=0.4:low=0.2",
            "mirror": "crop=iw/2:ih:0:0,split[l][r];[r]hflip[rf];[l][rf]hstack"
        ]
        let spec = EffectSpec(preset: preset.id)
        let actual = preset.builder(spec, 1080, 1920)
        if preset.id.hasPrefix("lut:") {
            let url = try #require(EffectCatalog.lutURL(named: String(preset.id.dropFirst(4))))
            #expect(actual == "lut3d=file='\(EffectCatalog.escapeFilterPath(url.path))'")
        } else {
            #expect(actual == expected[preset.id])
        }
    }

    @Test func effectWrappingAndPlacementPads() {
        let spec = EffectSpec(preset: "bw", intensity: 0.4)
        #expect(EffectCatalog.filter(for: spec, width: 100, height: 100)
            == "split[a][b];[b]hue=s=0[e];[a][e]blend=all_mode=normal:all_opacity=0.4")
        #expect(EffectCatalog.filter(for: .init(preset: "bw", intensity: 0), width: 100, height: 100).isEmpty)
        var filters = ["[2:v]scale=100:100[v0]", "[3:v]scale=100:100[v1_0]"]
        MultitrackRenderer.insertEffect(spec, label: "v0", width: 100, height: 100, filters: &filters)
        MultitrackRenderer.insertEffect(.init(preset: "mirror", intensity: 0.5), label: "v1_0",
                                       width: 100, height: 100, filters: &filters)
        #expect(filters[0].hasSuffix("[pre_v0]"))
        #expect(filters[2].contains("[fx_v0_a]") && filters[2].hasSuffix("[v0]"))
        #expect(filters[3].contains("[fx_v1_0_l]") && !filters[3].contains("[l]"))
        var plain = ["[2:v]scale=100:100[v0]"]
        MultitrackRenderer.insertEffect(.init(preset: "bw"), label: "v0", width: 100, height: 100, filters: &plain)
        #expect(plain == ["[2:v]scale=100:100,hue=s=0[v0]"])
    }

    @Test func effectParametersFallbackAndAvailability() throws {
        let duo = EffectSpec(preset: "duotone", params: ["shadow_r": 0.2, "highlight_r": 0.8])
        let filter = EffectCatalog.filter(for: duo, width: 100, height: 100)
        #expect(filter.contains("r='51+val*0.6'"))
        #expect(EffectCatalog.pixelate(block: 10, supported: false)
            == "scale=iw/10:ih/10,scale=iw*10:ih*10:flags=neighbor")
        #expect(!EffectCatalog.isAvailable("warm", filters: ["hue"]))
        #expect(!EffectCatalog.isAvailable("edges", filters: []))
        #expect(EffectCatalog.isAvailable("pixelate", filters: ["scale"]))
        // An empty probe (ffmpeg missing) is never cached: the next call retries.
        EffectCatalog.resetAvailability()
        #expect(EffectCatalog.parseFilters("").isEmpty)
        // ffmpeg 8 prints two flag characters, older builds three; header lines have no arrow.
        #expect(EffectCatalog.parseFilters(" T.. hue V->V Adjust hue\n ... pixelize V->V Pixelate\n Filters:") == ["hue", "pixelize"])
        #expect(EffectCatalog.parseFilters(" TS gblur             V->V       Apply Gaussian Blur filter.\n T. hue               V->V       Adjust hue.\n  T.. = Timeline support\n") == ["gblur", "hue"])
        for spec in [EffectSpec(preset: "unknown"), .init(preset: "bw", params: ["sigma": 1]),
                     .init(preset: "blur", params: ["sigma": 21]), .init(preset: "blur", params: ["sigma": .nan]),
                     .init(preset: "bw", intensity: -0.1), .init(preset: "bw", intensity: 1.01),
                     .init(preset: "bw", intensity: .infinity)] {
            #expect(throws: (any Error).self) { try EffectCatalog.validate(spec) }
        }
        try EffectCatalog.validate(.init(preset: "blur", params: ["sigma": 20], intensity: 0))
        #expect(EffectCatalog.lutURL(named: "../outside") == nil)
        #expect(EffectCatalog.escapeFilterPath("/tmp/look:one.cube") == #"/tmp/look\:one.cube"#)
        #expect(EffectCatalog.escapeFilterPath("/tmp/it's.cube") == #"/tmp/it'\\\''s.cube"#)
        #expect(EffectCatalog.escapeFilterPath(#"/tmp/a\b.cube"#) == #"/tmp/a\\b.cube"#)
    }

    @Test func effectResolutionAndLegacyCodable() throws {
        var clip = Fixtures.timelineClip(sceneID: 1)
        var doc = Fixtures.timelineDocument(clips: [clip])
        doc.trackSettings[0].effect = .init(preset: "bw")
        let inherited = try #require(MultitrackRenderer.resolveClips(document: doc, scenes: [Fixtures.scene()]).first)
        #expect(inherited.effectiveEffect?.preset == "bw")
        var ungraded = inherited
        ungraded.effectiveEffect = nil
        #expect(try RenderSegmentCache.key(inherited) != RenderSegmentCache.key(ungraded))
        let placements = MultitrackRenderer.placements(for: .init(start: 0, end: 1, clips: [inherited]))
        #expect(placements.first?.effectiveEffect?.preset == "bw")
        clip.effect = .init(preset: "none")
        doc.videoTrack = [clip]
        #expect(MultitrackRenderer.resolveClips(document: doc, scenes: [Fixtures.scene()]).first?.effectiveEffect == nil)
        clip.effect = .init(preset: "sepia")
        doc.videoTrack = [clip]
        #expect(MultitrackRenderer.resolveClips(document: doc, scenes: [Fixtures.scene()]).first?.effectiveEffect?.preset == "sepia")
        doc.videoTrack[0].bumper = true
        #expect(MultitrackRenderer.resolveClips(document: doc, scenes: [Fixtures.scene()]).first?.effectiveEffect == nil)
        #expect(try JSONDecoder().decode(EffectSpec.self, from: Data("{}".utf8)) == EffectSpec())
        #expect(try JSONDecoder().decode(TrackSettings.self, from: Data("{}".utf8)).effect == nil)
        #expect(try JSONDecoder().decode(TimelineClip.self, from: Data("{}".utf8)).effect == nil)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(doc))
        #expect(decoded.trackSettings[0].effect == doc.trackSettings[0].effect)
        #expect(decoded.videoTrack[0].effect == doc.videoTrack[0].effect)
        var changed = clip
        changed.effect = nil
        #expect(changed != clip)
        #expect(RenderSegmentCache.rendererVersion == "multitrack-segment-v4")
    }
}

extension MultitrackRendererPlanningTests {
    @Test("Builder output names carry project, non-default timeline, and the date")
    func builderOutputNames() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 12, hour: 12)))
        #expect(MultitrackRenderer.outputBaseName(project: "Poatan", timeline: "Fight Recap", date: date)
            == "Poatan - Fight Recap - 09-12-26")
        // The default timeline name and its duplicates are left out.
        for name in ["Untitled Timeline", "Untitled Timeline Copy", "Untitled Timeline Copy 2", "untitled timeline 3", "", "  "] {
            #expect(MultitrackRenderer.outputBaseName(project: "Poatan", timeline: name, date: date) == "Poatan - 09-12-26", Comment(rawValue: name))
        }
        #expect(!MultitrackRenderer.isDefaultTimelineName("Untitled Timeline Fight"))
        #expect(MultitrackRenderer.outputBaseName(project: nil, timeline: nil, date: date) == "09-12-26")
        // Path separators and colons never reach the filesystem.
        #expect(MultitrackRenderer.outputBaseName(project: "A/B:C", timeline: "x\\y", date: date) == "A-B-C - x-y - 09-12-26")
        #expect(MultitrackRenderer.outputBaseName(project: "...", timeline: nil, date: date) == "09-12-26"
            || !MultitrackRenderer.outputBaseName(project: "...", timeline: nil, date: date).hasPrefix("."))
    }

    @Test("Output files gain a counter when the name is taken")
    func uniqueOutputFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MultitrackRenderer.uniqueFile(named: "Poatan - 09-12-26", in: root)
        #expect(first.lastPathComponent == "Poatan - 09-12-26.mp4")
        try Data().write(to: first)
        let second = MultitrackRenderer.uniqueFile(named: "Poatan - 09-12-26", in: root)
        #expect(second.lastPathComponent == "Poatan - 09-12-26 2.mp4")
        try Data().write(to: second)
        #expect(MultitrackRenderer.uniqueFile(named: "Poatan - 09-12-26", in: root).lastPathComponent == "Poatan - 09-12-26 3.mp4")
    }
}
