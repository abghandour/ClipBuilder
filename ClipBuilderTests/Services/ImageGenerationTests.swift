import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Image generation")
struct ImageGenerationTests {
    @Test func stickerPromptHasKeyAndComposition() {
        let request = ImageGeneration.Request(prompt: "a duck beak", mode: .sticker, frame: nil, subject: nil)
        let prompt = ImageGeneration.prompt(for: request)
        #expect(prompt.contains("#00FF00 (RGB 0,255,0)"))
        #expect(prompt.contains("80 %"))
        #expect(prompt.contains("a duck beak"))
        #expect(prompt.contains("nanobanana edit_image"))
        #expect(prompt.contains("generate_image otherwise"))
        #expect(!prompt.contains("x="))
        #expect(!prompt.contains("Match the lighting"))
    }

    @Test func subjectAndFramePrompt() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var request = ImageGeneration.Request(prompt: "duck face", mode: .sticker, frame: Data([1]), subject: box)
        let prompt = ImageGeneration.prompt(for: request)
        #expect(prompt.contains("Match the lighting and head angle"))
        #expect(prompt.contains("x=0.100, y=0.200, w=0.300, h=0.400 (fractions)"))
        request.subject = nil
        #expect(!ImageGeneration.prompt(for: request).contains("x="))
        request.mode = .edit
        #expect(ImageGeneration.prompt(for: request).contains("Keep everything else identical, same size and framing"))
        #expect(!ImageGeneration.prompt(for: request).contains("Apply the change only"))
        request.subject = box
        #expect(ImageGeneration.prompt(for: request).contains("Apply the change only to the person at x=0.100"))
        #expect(!ImageGeneration.prompt(for: request).contains("#00FF00"))
    }

    @Test func outputDiscoveryExcludesOldAndNonImageFiles() throws {
        let scratch = try TempDirectory(prefix: "ImageGeneration")
        let folder = scratch.url.appendingPathComponent("nanobanana-output")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("old.png")
        try Data([1]).write(to: old)
        let before = Set(ImageGeneration.newOutputFiles(in: scratch.url, before: []).map(\.path))
        let first = folder.appendingPathComponent("first.jpg")
        let newest = folder.appendingPathComponent("new.PNG")
        try Data([1]).write(to: first)
        try Data([1]).write(to: newest)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
        try Data([1]).write(to: folder.appendingPathComponent("log.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory.png"), withIntermediateDirectories: true)
        #expect(ImageGeneration.newOutputFiles(in: scratch.url, before: before).map(\.lastPathComponent) == [newest.lastPathComponent, first.lastPathComponent])
        #expect(ImageGeneration.newOutputFiles(in: scratch.url.appendingPathComponent("missing"), before: []).isEmpty)
    }

    @Test func catalogRoutesOnlyToGemini() {
        // Not in Settings → AI: the only provider that can run it is Gemini.
        #expect(!AITask.configurable.contains(.imageGeneration))
        #expect(AITask.imageGeneration.label == "Image Generation")
        #expect(AICatalog.taskDefaults[AITask.imageGeneration.rawValue] == "gemini")
        #expect(AICatalog.recommendedChains[AITask.imageGeneration.rawValue]?.map(\.provider) == ["gemini"])
    }

    @Test func nonGeminiRoutingIsRejectedWithoutLaunching() async throws {
        var config = AIConfig()
        config.tasks[AITask.imageGeneration.rawValue] = "claude"
        let ai = AIService(config: config, executeProcess: { _, _, _, _, _, _ in
            Issue.record("Image generation must not invoke another provider")
            return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
        })
        do {
            _ = try await ai.generateImage(.init(prompt: "test", mode: .sticker, frame: nil, subject: nil), log: { _ in })
            Issue.record("Expected a configuration error")
        } catch let error as AIError {
            guard case .notConfigured = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test @MainActor func generatedJobFinishesWithoutReview() async throws {
        let jobs = AppJobs()
        let generated = GeneratedImage(image: .init(path: "/tmp/sticker.png", sourcePath: "/tmp/raw.png", width: 64, height: 64),
            subject: nil, provenance: .init(provider: "gemini", task: AITask.imageGeneration.rawValue))
        let id = jobs.start(.generateImage, title: "Generate Image", project: nil, profileGeneration: 0) { _ in
            .generatedImage(generated)
        }
        #expect(jobs.running.first?.kind.shortTitle == "Generate Image")
        #expect(jobs.running.first?.channel == "builder")
        for _ in 0..<200 where jobs.hasLiveTasks { try await Task.sleep(for: .milliseconds(5)) }
        #expect(jobs.items.first(where: { $0.id == id })?.status == .done)
        #expect(jobs.latest(.generateImage)?.result == .generatedImage(generated))
        #expect(jobs.presentedReview == nil)
        #expect(jobs.awaitingReview.isEmpty)
    }
}

struct ImagePlacementTests {
    @Test func fillingWindowCentersTheCropAndMapsBoxesToOutput() {
        // A 16:9 source aspect-filled into a 9:16 frame shows the center 9:16 slice.
        let placement = ImageGeneration.Placement.filling(
            box: CGRect(x: 0, y: 0, width: 1, height: 1), sourceAspect: 16.0 / 9.0, outputAspect: 9.0 / 16.0)
        let w = (9.0 / 16.0) / (16.0 / 9.0)
        #expect(abs(placement.window.wFrac - w) < 1e-9)
        #expect(abs(placement.window.xFrac - (1 - w) / 2) < 1e-9)
        #expect(placement.window.hFrac == 1 && placement.window.yFrac == 0)
        // A face at the source center lands at the output center with width scaled up.
        let face = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
        let out = placement.outputRect(face)
        #expect(abs(out.midX - 0.5) < 1e-9 && abs(out.midY - 0.5) < 1e-9)
        #expect(abs(out.width - 0.1 / w) < 1e-9)
        #expect(placement.shows(face))
        #expect(!placement.shows(CGRect(x: 0.02, y: 0.4, width: 0.1, height: 0.2)))
    }

    @Test func windowInsideAreaBoxMapsThroughBoth() {
        let placement = ImageGeneration.Placement(
            window: FreeCropRect(xFrac: 0.5, yFrac: 0, wFrac: 0.5, hFrac: 0.5),
            box: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let out = placement.outputRect(CGRect(x: 0.75, y: 0.25, width: 0.1, height: 0.1))
        #expect(abs(out.minX - 0.5) < 1e-9 && abs(out.minY - 0.75) < 1e-9)
        #expect(abs(out.width - 0.2) < 1e-9 && abs(out.height - 0.1) < 1e-9)
    }

    @Test func overlayGeometryFollowsModeAndSubject() {
        let placement = ImageGeneration.Placement(
            window: FreeCropRect(), box: CGRect(x: 0, y: 1.0 / 3, width: 1, height: 1.0 / 3))
        let edit = ImageGeneration.overlayGeometry(mode: .edit, subject: nil, placement: placement)
        #expect(abs(edit.yFrac - 0.5) < 1e-9 && edit.wFrac == 1)
        let sticker = ImageGeneration.overlayGeometry(mode: .sticker,
            subject: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), placement: placement)
        #expect(abs(sticker.xFrac - 0.5) < 1e-9 && abs(sticker.yFrac - 0.5) < 1e-9)
        #expect(abs(sticker.wFrac - 0.2) < 1e-9)
        let centered = ImageGeneration.overlayGeometry(mode: .sticker, subject: nil, placement: placement)
        #expect(centered.xFrac == 0.5 && centered.wFrac == 0.3)
    }

    @Test func namesComeFromTilesThenPortraitBoxes() {
        let roster = [
            VideoPersonRecord(videoID: 1, personID: 1, key: "aljo", name: "Aljamain Sterling", descriptor: "",
                              portraitAt: 0, portraitBox: nil),
            VideoPersonRecord(videoID: 1, personID: 2, key: "helwani", name: "", descriptor: "",
                              portraitAt: 0, portraitBox: .init(x: 0.5, y: 0, w: 0.5, h: 1)),
        ]
        let tiles = [PodcastTile(index: 0, x: 0, y: 0, w: 0.5, h: 1, personKey: "ALJO")]
        let names = ImageGeneration.names(for: [
            CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1),
            CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.1),
            CGRect(x: 0.3, y: 0.9, width: 0.1, height: 0.1),
        ], roster: roster, tiles: tiles)
        #expect(names == ["Aljamain Sterling", "helwani", "Aljamain Sterling"])
    }

    @Test func croppedKeepsTheWindowPixels() throws {
        let width = 200, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width where x >= 100 {
            let i = (y * width + x) * 4
            pixels[i] = 255; pixels[i + 3] = 255
        } }
        let context = pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let image = try #require(context?.makeImage())
        let right = ImageGeneration.cropped(image, to: FreeCropRect(xFrac: 0.5, yFrac: 0, wFrac: 0.5, hFrac: 1))
        #expect(right.width == 100 && right.height == 100)
        let jpeg = try #require(ImageGeneration.jpeg(right))
        #expect(jpeg.count > 100)
        let decoded = try ImageGeneration.decode(jpeg)
        #expect(decoded.width == 100)
    }
}
