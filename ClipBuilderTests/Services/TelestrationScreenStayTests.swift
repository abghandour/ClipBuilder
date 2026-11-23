import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Screen-fixed staying drawings")
struct TelestrationScreenStayTests {
    private func document() -> TimelineDocument {
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 1, startTime: 0)
        hold.hold = true
        hold.wide = false
        hold.telestration = Telestration(figures: [.init(linger: 1.5)])
        var moving = Fixtures.timelineClip(sceneID: nil, sourceStart: 1, duration: 2, startTime: 1)
        moving.wide = false
        return Fixtures.timelineDocument(clips: [hold, moving])
    }

    @Test func trackedAreaUsesItsOwnSurfaceBeforeFollowingPrepass() throws {
        let settings = RenderSettings(preset: .custom, customWidth: 800, customHeight: 800)
        try RenderContext.$settings.withValue(settings) {
            let area = ScreenCropArea(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
                .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)])
            var hold = try #require(MultitrackRenderer.resolveClips(document: document(), scenes: []).first)
            hold.cameraPath = [0, 1].map { .init(t: $0, x: 0.25, y: 0.25, w: 0.5, h: 0.5) }
            hold.continuityTransform = true
            hold.areaPathArea = area
            hold.areaPathSource = CGSize(width: 1600, height: 800)
            hold.fitArea = area
            let layout = ScreenCropLayout(name: "Stay areas", areas: [area])
            hold.framingPlan = .composed(layout: layout, areas: [], fit: .fill)
            let canvas = CGSize(width: 800, height: 800)
            let frame = try #require(TelestrationScreenStay.frame(for: hold,
                source: CGSize(width: 1600, height: 800), canvas: canvas))
            var moving = hold
            moving.hold = false
            moving.areaPathArea = nil
            moving.areaPathSource = nil
            let mapped = try #require(TelestrationScreenStay.mapping(hold: frame, following: moving, canvas: canvas))
            #expect(mapped.frame.area == CGRect(x: 0, y: 0, width: 800, height: 400))
            #expect(mapped.outputSize == canvas)
        }
    }

    @Test("The source rect expands and translates through W, including its stroke scale")
    func painterRect() throws {
        let picture = CGRect(x: 20, y: 40, width: 400, height: 800)
        let cases: [(FreeCropRect, CGRect)] = [
            (.init(), picture),
            (.init(xFrac: 0.25, yFrac: 0.25, wFrac: 0.5, hFrac: 0.5),
             CGRect(x: -180, y: -360, width: 800, height: 1600)),
            (.init(xFrac: 0.1, yFrac: 0.3, wFrac: 0.5, hFrac: 0.5),
             CGRect(x: -60, y: -440, width: 800, height: 1600)),
            (.init(xFrac: 0.375, yFrac: 0, wFrac: 0.25, hFrac: 1),
             CGRect(x: -580, y: 40, width: 1600, height: 800))
        ]
        for (window, expected) in cases {
            #expect(TelestrationScreenStay.painterRect(window: window, picture: picture) == expected)
        }
        #expect(TelestrationScreenStay.painterRect(window: .init(wFrac: 0), picture: picture) == nil)
        #expect(TelestrationScreenStay.painterRect(window: .init(xFrac: .nan), picture: picture) == nil)
    }

    @Test("Resolved hold framings supply W, independently of the following camera", arguments: ["whole", "center", "offCenter", "free", "staticPlan", "area", "camera"])
    func supportedHoldFramings(kind: String) throws {
        let settings = RenderSettings(preset: .custom, customWidth: 800, customHeight: 800)
        try RenderContext.$settings.withValue(settings) {
            let clips = MultitrackRenderer.resolveClips(document: document(), scenes: [])
            var hold = try #require(clips.first)
            var moving = try #require(clips.last)
            #expect(moving.lingeringHold?.first?.originKey == hold.originKey)
            let canvas = CGSize(width: 800, height: 800)
            let source = CGSize(width: 1600, height: 800)
            let area = ScreenCropArea(name: "Test", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
            let crop = FreeCropRect(xFrac: 0.25, yFrac: 0, wFrac: 0.5, hFrac: 1)
            var expected = crop
            switch kind {
            case "whole": expected = .init()
            case "center": hold.wide = true; hold.effectiveCropXFrac = 0.5
            case "offCenter":
                hold.wide = true; hold.effectiveCropXFrac = 0.75
                expected.xFrac = 0.375
            case "free": hold.freeCrops = [.init(src: crop, dst: .init())]
            case "staticPlan": hold.framingPlan = .static(window: crop, fit: .fill, feather: 0, blur: 0)
            case "area":
                hold.areaWindow = crop
                hold.fitArea = area
                hold.staticAreaFilter = AreaFramer.staticFilter(area: area, window: crop)
            default:
                hold.centerStage = true
                hold.cameraPath = [.init(t: 0, x: 0.25, y: 0, w: 0.5, h: 1), .init(t: 1, x: 0.25, y: 0, w: 0.5, h: 1)]
                hold.areaPathSource = source
                hold.areaPathArea = area
            }
            let frame = try #require(TelestrationScreenStay.frame(for: hold, source: source, canvas: canvas))
            #expect(frame.window == expected)
            moving.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.5, h: 1), .init(t: 2, x: 0.5, y: 0, w: 0.5, h: 1)]
            let mapped = try #require(TelestrationScreenStay.mapping(hold: frame, following: moving, canvas: canvas))
            #expect(mapped.frame == frame)
            #expect(mapped.outputSize == canvas)
            // A framing movie clears source burns but retains a fixed stay.
            moving.screenStay = mapped
            moving.useFramedSource(URL(fileURLWithPath: "/tmp/framed.mov"), identity: "framed", areaPass: false, reusable: true)
            #expect(moving.lingering != nil && moving.screenStay == mapped)
        }
    }

    @Test("Unsupported composition and changed layout fall back")
    func unsupportedFramings() throws {
        let clips = MultitrackRenderer.resolveClips(document: document(), scenes: [])
        let hold = try #require(clips.first)
        let moving = try #require(clips.last)
        let size = CGSize(width: 800, height: 800)
        let frame = try #require(TelestrationScreenStay.frame(for: hold, source: size, canvas: size))
        for kind in 0..<5 {
            var unsupported = hold
            switch kind {
            case 0: unsupported.framingPlan = .static(window: nil, fit: .blurredFill, feather: 0, blur: 0)
            case 1: unsupported.freeCrops = [.init(src: .init(), dst: .init()), .init(src: .init(), dst: .init())]
            case 2: unsupported.framingPlan = .composed(layout: .init(name: "Test"), areas: [], fit: .fill)
            case 3: unsupported.centerStage = true // No resolved hold path.
            default: unsupported.staticAreaFilter = "opaque recipe"
            }
            #expect(TelestrationScreenStay.frame(for: unsupported, source: size, canvas: size) == nil)
            if kind < 3 {
                unsupported.hold = false
                #expect(TelestrationScreenStay.mapping(hold: frame, following: unsupported, canvas: size) == nil)
            }
        }
        var changedArea = moving
        changedArea.freeCrops = [.init(src: .init(), dst: .init(wFrac: 0.5))]
        #expect(TelestrationScreenStay.mapping(hold: frame, following: changedArea, canvas: size) == nil)
        // A single crop occupying the same area uses its own stream origin.
        let tile = CGRect(x: 200, y: 0, width: 400, height: 800)
        changedArea.freeCrops = [.init(src: .init(), dst: .init(xFrac: 0.25, wFrac: 0.5))]
        let tileFrame = TelestrationScreenStay.Frame(window: .init(), picture: tile, area: tile)
        let mapped = try #require(TelestrationScreenStay.mapping(hold: tileFrame, following: changedArea, canvas: size))
        #expect(mapped.picture == CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    @Test("Preview windows retain the removed hold and advance only the stay clock")
    func previewContext() throws {
        var original = document()
        original.videoTrack[0].freeCrops = [.init(src: .init(xFrac: 0.25, wFrac: 0.5), dst: .init())]
        original.videoTrack[0].contentWindow = .init(yFrac: 0.1, hFrac: 0.8)
        original.videoTrack[1].contentWindow = .init(yFrac: 0.2, hFrac: 0.6)
        let window = MultitrackRenderer.windowed(original, scenes: [], from: 1.2, to: 2.5)
        let uid = try #require(window.document.videoTrack.first?.uid)
        #expect(window.lingerHolds[uid]?.freeCrops == original.videoTrack[0].freeCrops)
        let again = MultitrackRenderer.windowed(window.document, scenes: [], lingering: window.lingering,
            lingerHolds: window.lingerHolds, from: 0.2, to: 1)
        #expect(again.lingerHolds[uid]?.freeCrops == original.videoTrack[0].freeCrops)
        #expect(again.lingerHolds[uid]?.contentWindow == original.videoTrack[0].contentWindow)
        #expect(abs((again.lingering[uid]?.offset ?? -1) - 0.4) < 1e-9)
        let resolved = MultitrackRenderer.resolveClips(document: again.document, scenes: [],
            lingering: again.lingering, lingerHolds: again.lingerHolds)
        #expect(resolved.first?.lingeringHold?.first?.freeCrops == original.videoTrack[0].freeCrops)
        let json = String(decoding: try JSONEncoder().encode(resolved), as: UTF8.self)
        #expect(!json.contains("lingeringHold") && !json.contains("screenStay"))
        let a = AppStore.builderPreviewKey(document: original, scenes: [], profile: Fixtures.brand(), camera: "steady", window: 1.2...2)
        original.videoTrack[0].freeCrops?[0].src.xFrac = 0.125
        let b = AppStore.builderPreviewKey(document: original, scenes: [], profile: Fixtures.brand(), camera: "steady", window: 1.2...2)
        #expect(a != nil && b != nil && a != b)
    }

    @Test("Pauses from one split source keep distinct hold identities")
    func repeatedOrigin() throws {
        var original = document()
        var secondHold = original.videoTrack[0]
        secondHold.uid = UUID()
        secondHold.startTime = 3
        secondHold.freeCrops = [.init(src: .init(xFrac: 0.5, wFrac: 0.5), dst: .init())]
        var secondMotion = original.videoTrack[1]
        secondMotion.uid = UUID()
        secondMotion.startTime = 4
        original.videoTrack += [secondHold, secondMotion]
        let clips = MultitrackRenderer.resolveClips(document: original, scenes: [])
        let first = try #require(clips.first { $0.startTime == 1 })
        let second = try #require(clips.first { $0.startTime == 4 })
        #expect(first.lingeringHold?.first?.stayHoldID == original.videoTrack[0].uid)
        #expect(second.lingeringHold?.first?.stayHoldID == secondHold.uid)
        #expect(first.lingeringHold?.first?.freeCrops == nil)
        #expect(second.lingeringHold?.first?.freeCrops == secondHold.freeCrops)
    }

    @Test("Only segment evidence depends on a fixed stay; clean framing keys do not")
    func cacheEvidence() throws {
        let clips = MultitrackRenderer.resolveClips(document: document(), scenes: [])
        var moving = try #require(clips.last)
        moving.framingIdentity = "source"
        let box = CGRect(x: 0, y: 0, width: 800, height: 800)
        moving.screenStay = .init(frame: .init(window: .init(), picture: box, area: box), outputSize: box.size, outputOrigin: .zero)
        let before = try MultitrackRenderer.prepassKey(moving, area: nil, tuning: "steady")
        let evidence = try RenderSegmentCache.key(TelestrationLingerResolution.screenEvidence([moving]))
        moving.screenStay?.frame.window.xFrac = 0.25
        #expect(try RenderSegmentCache.key(TelestrationLingerResolution.screenEvidence([moving])) != evidence)
        moving.lingering?.figures[0].linger = 2
        #expect(try MultitrackRenderer.prepassKey(moving, area: nil, tuning: "steady") == before)
        moving.lingering = nil
        #expect(try MultitrackRenderer.prepassKey(moving, area: nil, tuning: "steady") == before)
        #expect(TelestrationLingerResolution.screenEvidence([moving]) == nil)
        #expect(TelestrationLingerResolution.cacheEvidence([moving]) == nil)
    }
    @Test(arguments: [false, true])
    func composedPictureWithOwnResolvedGeometrySupportsFixedStay(path: Bool) throws {
        let settings = RenderSettings(preset: .custom, customWidth: 800, customHeight: 800)
        try RenderContext.$settings.withValue(settings) {
            let source = CGSize(width: 1600, height: 800), canvas = CGSize(width: 800, height: 800)
            let area = ScreenCropArea(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0),
                .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)])
            var hold = try #require(MultitrackRenderer.resolveClips(document: document(), scenes: []).first)
            hold.framingPlan = .composed(layout: .init(name: "Two", areas: [area]), areas: [], fit: .fill)
            hold.fitArea = area
            hold.centerStage = !path // The explicit window overrides an old tracking flag.
            if path {
                hold.cameraPath = [0, 1].map { .init(t: $0, x: 0.25, y: 0.25, w: 0.5, h: 0.5) }
                hold.areaPathArea = area; hold.areaPathSource = source
            } else {
                hold.areaWindow = .init(xFrac: 0.25, yFrac: 0.25, wFrac: 0.5, hFrac: 0.5)
                hold.staticAreaFilter = AreaFramer.staticFilter(area: area, window: try #require(hold.areaWindow))
            }
            let frame = try #require(TelestrationScreenStay.frame(for: hold, source: source, canvas: canvas))
            var following = hold
            following.hold = false
            #expect(TelestrationScreenStay.mapping(hold: frame, following: following, canvas: canvas) != nil)
            following.cameraPath = nil; following.areaPathSource = nil; following.areaWindow = nil
            #expect(TelestrationScreenStay.mapping(hold: frame, following: following, canvas: canvas) == nil)
        }
    }

}
