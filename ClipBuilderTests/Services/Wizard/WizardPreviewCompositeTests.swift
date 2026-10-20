import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clip_Builder

@Suite("Wizard preview composite")
struct WizardPreviewCompositeTests {
    @Test func bottomCaptionsLeaveTheTopBandUntouched() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        input.options.addCaptions = true
        input.options.captionPosition = "bottom"
        let captioned = try await WizardPreviewComposite.render(input)
        #expect(captioned.width == 640 && captioned.height == 360)
        #expect(try changedPixels(plain, captioned, in: CGRect(x: 0, y: 180, width: 640, height: 180)) > 100)
        #expect(try changedPixels(plain, captioned, in: CGRect(x: 0, y: 0, width: 640, height: 120)) == 0)
    }

    @Test func topTrailingNameTagUsesThatCorner() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        input.options.nameTags = true
        input.options.nameTagPosition = "topTrailing"
        let tagged = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, tagged, in: CGRect(x: 320, y: 0, width: 320, height: 180)) > 100)
        #expect(try changedPixels(plain, tagged, in: CGRect(x: 0, y: 180, width: 640, height: 180)) == 0)
    }

    @Test func disabledWatermarkLeavesLogoAreaUnchanged() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        let logo = FileManager.default.temporaryDirectory.appendingPathComponent("preview-logo-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: logo) }
        try frameData(red: 1).write(to: logo)
        input.profile.logoPath = logo.path
        let disabled = try await WizardPreviewComposite.render(input)
        let corner = CGRect(x: 0, y: 0, width: 200, height: 120)
        #expect(try changedPixels(plain, disabled, in: corner) == 0)
        input.options.includeWatermark = true
        let enabled = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, enabled, in: corner) > 0)
    }

    @Test func portraitCanvasCropsLandscapeFrame() async throws {
        var input = try input()
        input.options.renderSettings.preset = .portrait1080
        let image = try await WizardPreviewComposite.render(input)
        #expect(image.width == 1080 && image.height == 1920)
    }

    @Test func faceCropIsClampedToSourceEdges() {
        let rect = WizardPreviewComposite.coverRect(source: CGSize(width: 640, height: 360),
            canvas: CGSize(width: 1080, height: 1920), face: CGRect(x: 0.9, y: 0.3, width: 0.1, height: 0.2))
        #expect(rect.maxX == 1080)
        #expect(rect.minX < 0 && rect.minY == 0 && rect.height == 1920)
    }

    @Test func expressOptionsUseProfileSafeAreaAndOwnChoices() {
        var profile = Fixtures.brand()
        profile.defaultRenderSettings = RenderSettings(preset: .landscape1080)
        var settings = MiniWizardSettings()
        settings.preset = .square1080
        settings.captions = true
        settings.captionPosition = "top"
        settings.nameTags = true
        settings.watermark = false
        let options = settings.previewOptions(profile: profile)
        #expect(options.renderSettings.preset == .square1080)
        #expect(options.renderSettings.platformSafeArea == profile.defaultRenderSettings.platformSafeArea)
        #expect(options.addCaptions && options.usesNameTags && !options.includeWatermark)
        #expect(options.captionPositionOverride == "top")
    }

    @Test func sourceWordClocksDoNotHideCaptions() async throws {
        var input = try input()
        input.options.addCaptions = true
        input.options.captionPosition = "bottom"
        let expected = try await WizardPreviewComposite.render(input)
        input.scene.words = [
            TranscriptWord(word: "A", start: 120, end: 120.2),
            TranscriptWord(word: "strong", start: 120.2, end: 120.5),
            TranscriptWord(word: "moment", start: 120.5, end: 121),
        ]
        let actual = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(expected, actual, in: CGRect(x: 0, y: 0, width: 640, height: 360)) == 0)
    }

    @Test func expressRememberedSettingsNeverInheritWizardBranding() throws {
        let suite = "WizardPreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("none", forKey: "wizard.brandingMode")
        let profile = Fixtures.brand()
        #expect(MiniWizardSettings.remembered(profile: profile, defaults: defaults).watermark)
        var own = MiniWizardSettings()
        own.watermark = false
        own.remember(profileName: profile.profileName, defaults: defaults)
        #expect(!MiniWizardSettings.remembered(profile: profile, defaults: defaults).watermark)
    }

    @Test func overlayUsesItsStartAndWatermarkTemplateHonorsZeroOpacity() async throws {
        var input = try input()
        let plain = try await WizardPreviewComposite.render(input)
        var text = TextOverlayItem()
        text.text = "Preview overlay"
        text.unbounded = true
        input.templates = [OverlayTemplate(name: "Preview", composition: OverlayComposition(texts: [text]))]
        input.options.fixedOverlayTemplate = "Preview"
        input.options.fixedOverlayStart = 12
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let overlay = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, overlay, in: frame) > 0)
        input.options.fixedOverlayDuration = 0
        let disabledOverlay = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, disabledOverlay, in: frame) == 0)
        input.options.fixedOverlayTemplate = nil
        input.options.includeWatermark = true
        input.options.watermarkOverlayTemplate = "Preview"
        input.options.watermarkOpacity = 0
        let invisibleWatermark = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, invisibleWatermark, in: frame) == 0)
    }

    @Test func previewKeyIgnoresAudioAndQualityButTracksVisuals() {
        var options = WizardOptions()
        let scene = Fixtures.scene()
        let profile = Fixtures.brand()
        let original = PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        options.useMusic.toggle()
        options.muteSource.toggle()
        options.renderSettings.quality = .archival
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) == original)
        options.captionPosition = "top"
        #expect(PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: []) != original)
        #expect(PreviewKey(options: WizardOptions(), scene: scene, profile: profile,
                           contentRevision: 0, overlayTexts: ["Changed"]) != original)
    }

    @Test func originalIgnoresFacesAndSavedPaths() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        input.options.renderSettings = RenderSettings(preset: .custom, customWidth: 180, customHeight: 320)
        let plain = try await WizardPreviewComposite.render(input)
        let face = CGRect(x: 0.8, y: 0.2, width: 0.1, height: 0.1)
        let path = SceneCameraPath(camera: "test", keyframes: [.init(t: 0, x: 0.5, y: 0, w: 0.5, h: 1)])
        input.scene.faceRect = face
        input.scene.framing = WizardPreviewFraming.talker(original: true, path: path, wide: true, time: 0, face: face)
        let original = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(plain, original, in: CGRect(x: 0, y: 0, width: 180, height: 320)) == 0)
        input.scene.framing = WizardPreviewFraming.talker(original: false, path: nil, wide: true, time: 0, face: face)
        let talker = try await WizardPreviewComposite.render(input)
        #expect(try changedPixels(original, talker, in: CGRect(x: 0, y: 0, width: 180, height: 320)) > 0)
    }

    @Test func savedPathUsesSceneLocalTimeAndOnlyWideContent() {
        let early = CameraPathKeyframe(t: 0, x: 0, y: 0, w: 0.5, h: 1)
        let late = CameraPathKeyframe(t: 8, x: 0.5, y: 0, w: 0.5, h: 1)
        let path = SceneCameraPath(camera: "test", keyframes: [early, late])
        #expect(WizardPreviewFraming.talker(original: false, path: path, wide: true, time: 7, face: nil) == .path(late))
        #expect(WizardPreviewFraming.talker(original: false, path: path, wide: false, time: 7, face: nil) == .cover(face: nil))
    }

    @Test func gridDrawsEachFeedInItsOwnCell() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        var video = Fixtures.video()
        video.width = 640
        video.height = 360
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        // A left/right Screen Crop makes each source colour directly observable.
        let layout = ScreenCropLayout(name: "Preview columns", areas: [
            ScreenCropArea(name: "Left", points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 0.5, y: 1), .init(x: 0, y: 1)]),
            ScreenCropArea(name: "Right", points: [.init(x: 0.5, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0.5, y: 1)]),
        ])
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .grid, layout: layout.name), video: video,
            range: 0...10, turns: [], roster: [], layouts: [layout], canvasAspect: 640.0 / 360)
        let cells = WizardPreviewFraming.cells(plan: plan, layouts: [layout], video: video,
            time: 1, rangeStart: 0, roster: [], people: [], canvasAspect: 640.0 / 360)
        #expect(cells.count == 2)
        input.scene.framing = .cells(cells)
        let grid = try await WizardPreviewComposite.render(input)
        let expected = try #require(CGImageSourceCreateWithData(input.frameData as CFData, nil))
        let source = try #require(CGImageSourceCreateImageAtIndex(expected, 0, nil))
        #expect(try changedPixels(source, grid, in: CGRect(x: 10, y: 10, width: 300, height: 340)) == 0)
        #expect(try changedPixels(source, grid, in: CGRect(x: 330, y: 10, width: 300, height: 340)) == 0)
        let geometry = WizardPreviewComposite.tagGeometry(scene: input.scene, canvas: CGSize(width: 640, height: 360))
        #expect(geometry.areas.map(\.rect) == [CGRect(x: 0, y: 0, width: 320, height: 360), CGRect(x: 320, y: 0, width: 320, height: 360)])
    }

    @Test func talkerOnTiledRecordingShowsTheTalkingFeedFullScreen() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        var turn = SpeakerTurn(videoID: video.id, start: 5, end: 10, cluster: 1, confidence: 1)
        turn.tile = 1
        var scene = Fixtures.scene()
        scene.startTime = 4
        scene.endTime = 10
        var options = WizardOptions()
        options.highlightFraming = .talker
        let resolved = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        #expect(resolved.warning == nil)
        guard case .cells(let cells) = resolved.framing else {
            Issue.record("talker on a tiled recording should use the recipe plan, got \(resolved.framing)")
            return
        }
        #expect(cells.count == 1)
        #expect(cells[0].area == WizardPreviewFraming.full)
        #expect(cells[0].source.midX > 0.5 && cells[0].source.width <= 0.5)
        // "Let AI choose" resolves the same way for the preview.
        options.highlightFraming = nil
        if case .cells = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn).framing {} else {
            Issue.record("nil framing should preview as talker on a tiled recording")
        }
        // Original keeps the whole recording.
        options.podcastFraming = .original
        if case .cover(face: nil) = WizardPreviewFraming.resolve(options: options, record: scene, video: video, face: nil,
            turns: [turn], roster: [], people: [], layouts: ScreenCropStore.builtIn).framing {} else {
            Issue.record("original should be a plain cover crop")
        }
    }

    @Test func recipePathSwitchesAtTheCutAndFindsTalkingCell() throws {
        var video = Fixtures.video()
        video.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        var turn = SpeakerTurn(videoID: video.id, start: 5, end: 10, cluster: 1, confidence: 1)
        turn.tile = 1
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .talkerAndPrevious), video: video,
            range: 4...10, turns: [turn], roster: [], layouts: ScreenCropStore.builtIn, canvasAspect: 9.0 / 16)
        let cells = WizardPreviewFraming.cells(plan: plan, layouts: ScreenCropStore.builtIn, video: video,
            time: 7, rangeStart: 4, roster: [], people: [], canvasAspect: 9.0 / 16)
        #expect(cells.count == 2)
        #expect(cells[0].source.midX > 0.5)
        #expect(cells[0].isTalking)
        #expect(cells[1].source.midX < 0.5)
    }

    @Test func unavailableRecipeFallsBackToTalkerWithReason() {
        var options = WizardOptions()
        options.highlightFraming = .grid
        let face = CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2)
        let result = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: Fixtures.video(),
            face: face, turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        #expect(result.framing == .cover(face: face))
        #expect(result.warning?.contains("two or more feeds") == true)
        let missing = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: nil,
            face: face, turns: [], roster: [], people: [], layouts: [])
        #expect(missing.framing == .cover(face: face))
        #expect(missing.warning?.contains("analyze it first") == true)
        var split = Fixtures.video()
        split.podcastLayout = PodcastLayout.splitHorizontal.rawValue
        options.highlightFraming = .talkerAndRest
        let noTurns = WizardPreviewFraming.resolve(options: options, record: Fixtures.scene(), video: split,
            face: face, turns: [], roster: [], people: [], layouts: ScreenCropStore.builtIn)
        #expect(noTurns.framing == .cover(face: face))
        #expect(noTurns.warning?.contains("No speaker turns") == true)
    }

    @Test func cellFacesMapToTheirOwnCanvasAreaAndTagTextDoesNotChangePixelsKey() {
        let cell = WizardPreviewComposite.Cell(source: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            area: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            face: CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.2))
        var scene = WizardPreviewComposite.Scene(videoURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
            time: 1, faceRect: nil, person: nil, captionText: nil, words: nil)
        scene.sourceSize = CGSize(width: 4000, height: 1000)
        scene.framing = .cells([cell])
        let geometry = WizardPreviewComposite.tagGeometry(scene: scene, canvas: CGSize(width: 1000, height: 1000))
        let face = geometry.areas.first?.spans.first?.faceBox
        #expect(abs((face?.minX ?? 0) - 400) < 0.001)
        #expect(face?.minY == 600 && face?.width == 200 && face?.height == 100)
        var talking = cell
        talking.isTalking = true
        #expect(WizardPreviewFraming.pixelFraming(.cells([cell])) == WizardPreviewFraming.pixelFraming(.cells([talking])))
    }

    @Test func noLookMatchesUngradedBase() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        input.options.lookPreset = "none"
        let ungraded = try WizardPreviewComposite.croppedFrame(input)
        let base = try await WizardPreviewComposite.prepareBase(input)
        #expect(base.error == nil)
        #expect(try changedPixels(ungraded, base.image, in: CGRect(x: 0, y: 0, width: 640, height: 360)) == 0)
    }

    @Test(.enabled(if: FFmpeg.isAvailable, "ffmpeg is required for Look grading"))
    func halfIntensityLookChangesPixels() async throws {
        var input = try input()
        input.frameData = try frameData(red: 1, split: true)
        let plain = try WizardPreviewComposite.croppedFrame(input)
        input.options.lookPreset = "bw"
        input.options.lookIntensity = 0.5
        #expect(WizardEngine.lookEffect(for: input.options) != nil)
        let base = try await WizardPreviewComposite.prepareBase(input)
        #expect(base.error == nil)
        #expect(try changedPixels(plain, base.image, in: CGRect(x: 0, y: 0, width: 640, height: 360)) > 1000)
        // A graded frame decoded lazily from a deleted scratch file draws black.
        #expect(try meanBrightness(base.image) > 40)
    }

    private func meanBrightness(_ image: CGImage) throws -> Double {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        var total = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            total += Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
        }
        return Double(total) / Double(image.width * image.height * 3)
    }

    @Test func previewKeyTracksLookStrengthAndCamera() {
        let scene = Fixtures.scene(), profile = Fixtures.brand()
        var options = WizardOptions()
        func key() -> PreviewKey {
            PreviewKey(options: options, scene: scene, profile: profile, contentRevision: 0, overlayTexts: [])
        }
        let plain = key()
        options.lookPreset = "bw"
        let look = key()
        #expect(look != plain)
        options.lookIntensity = 0.5
        #expect(key() != look)
        let graded = key()
        options.highlightFraming = .grid
        #expect(key() != graded)
    }

    private func input() throws -> WizardPreviewComposite.Input {
        var options = WizardOptions()
        options.renderSettings = RenderSettings(preset: .custom, customWidth: 640, customHeight: 360)
        options.includeWatermark = false
        return .init(scene: .init(videoURL: URL(fileURLWithPath: "/tmp/preview.mp4"), time: 1,
                                  faceRect: nil, person: nil, captionText: "A strong moment", words: nil),
                     options: options, profile: Fixtures.brand(), templates: [], frameData: try frameData())
    }

    private func frameData(red: CGFloat = 0.1, split: Bool = false) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        if split {
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 320, y: 0, width: 320, height: 360))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Rasterize both into the same byte layout; y=0 is the top of the image.
    private func changedPixels(_ a: CGImage, _ b: CGImage, in rect: CGRect) throws -> Int {
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let left = try #require(a.cropping(to: rect))
        let right = try #require(b.cropping(to: rect))
        let lhs = try pixels(left), rhs = try pixels(right)
        var count = 0
        var opaque = true
        for offset in stride(from: 0, to: lhs.count, by: 4) {
            if lhs[offset..<offset + 3] != rhs[offset..<offset + 3] {
                opaque = opaque && rhs[offset + 3] == 255
                count += 1
            }
        }
        #expect(opaque)
        return count
    }
}
