import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import Clip_Builder

struct CaptionRendererTests {
    @Test func speakerPNGCacheSeparatesStylesAndUsesTheirPlacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var style = CaptionStyle()
        style.color = "#ffffff"
        style.position = "bottom"
        var red = style
        red.color = "#ff0000"
        red.position = "top"
        let safe = try #require(PlatformSafeArea.resolve(platforms: [.instagram], aspectRatio: 9.0 / 16))
        let base = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style,
                                   safeArea: safe, safeAreaOnly: true)
        let renderers = CaptionRendererSet(base: base, speakerStyles: ["ana": red])
        let cache = CaptionPNGCache(renderers: renderers, directory: folder)
        let raster = CaptionOverlayPlan.Raster(text: "Same words")
        var speakerRaster = raster
        speakerRaster.styleID = "ana"
        let plain = try await cache.rendered(raster)
        let speaker = try await cache.rendered(speakerRaster)
        let repeatSpeaker = try await cache.rendered(speakerRaster)
        #expect(plain.pngURL != speaker.pngURL)
        #expect(repeatSpeaker.pngURL == speaker.pngURL)
        #expect(try Self.pixels(plain) != Self.pixels(speaker))
        let selected = cache.renderer(styleID: speakerRaster.styleID)
        #expect(selected.videoWidth == base.videoWidth && selected.videoHeight == base.videoHeight)
        #expect(selected.safeArea == base.safeArea && selected.safeAreaOnly == base.safeAreaOnly)
        #expect(selected.position(for: speaker).y < base.position(for: plain).y)
        #expect(renderers.renderer(styleID: "deleted").style == style)
        #expect(!CaptionRendererSet(base: base).usesSpeakers && renderers.usesSpeakers)
        let segment = TranscriptSegment(start: 0, end: 1, text: "Same words")
        var turn = SpeakerTurn(videoID: 1, start: 0, end: 1, cluster: 0, confidence: 1, personKey: "ana")
        #expect(renderers.renderer(for: segment, turns: [turn], rows: []).styleID == "ana")
        turn.personKey = nil
        #expect(renderers.renderer(for: segment, turns: [turn], rows: []).styleID == nil)
    }

    @Test func wrappedLinesUseTheSelectedAlignment() {
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: nil) == 100)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "center") == 100)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "leading") == 20)
        #expect(CaptionRenderer.lineOrigin(width: 100, boxWidth: 300, padding: 20, alignment: "trailing") == 180)
    }

    @Test func explicitPositionsOverrideTheStyleAndAutoPreservesIt() {
        var style = CaptionStyle()
        style.position = "top"
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
        #expect(renderer.position(for: caption).y == 106)
        #expect(renderer.position(for: caption, positionOverride: "middle").y == 910)
        #expect(renderer.position(for: caption, positionOverride: "bottom").y == 1752)
    }
}

extension CaptionRendererTests {
    @Test func explicitTwoRowPositionsUseFrameEdgesWithOrWithoutPlatforms() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        for safeArea in [safe, nil] {
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safeArea)
            let bottom = renderer.twoRowBand(positionOverride: "bottom")
            let top = renderer.twoRowBand(positionOverride: "top")
            let middle = renderer.twoRowBand(positionOverride: "middle")
            let margin = max(32, 1920 / 28)
            #expect(abs(bottom.maxY - CGFloat(1920 - margin)) <= 1)
            #expect(abs(top.minY - CGFloat(margin)) <= 1)
            #expect(abs(middle.midY - 960) <= 1)
            for band in [bottom, top, middle] { #expect(abs(band.midX - 540) <= 1) }
            let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
            let origin = renderer.position(for: caption, positionOverride: "bottom")
            #expect(origin.x == 290 && origin.y + caption.height == 1920 - margin)
        }
    }

    @Test func autoTwoRowPositionsRemainInsideThePlatformSafeArea() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        for position in ["top", "middle", "bottom"] {
            var style = CaptionStyle()
            style.position = position
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: safe)
            for override in [nil, "auto"] {
                let band = renderer.twoRowBand(positionOverride: override)
                let normalized = CGRect(x: band.minX / 1080, y: band.minY / 1920,
                                        width: band.width / 1080, height: band.height / 1920)
                // Header and footer bound every caption; the button rail only
                // constrains rows it actually overlaps, so a top caption may
                // span the full width.
                let tolerance = 1.0 / 1920
                #expect(normalized.minY >= safe.rect.minY - tolerance)
                #expect(normalized.maxY <= safe.rect.maxY + tolerance)
                let overlapsRail = safe.zones.contains {
                    $0.kind == .rail && $0.rect.minY < normalized.maxY && $0.rect.maxY > normalized.minY
                }
                if overlapsRail { #expect(normalized.maxX <= safe.rect.maxX + 1.0 / 1080) }
            }
        }
    }

    @Test func explicitMarginsScaleAndKeepTheirMinimumOnSmallCanvases() {
        for height in [480, 1080, 1920, 3840] {
            let renderer = CaptionRenderer(videoWidth: height * 9 / 16, videoHeight: height,
                                           style: CaptionStyle(), safeArea: nil)
            let band = renderer.twoRowBand(positionOverride: "bottom")
            #expect(abs(band.maxY - CGFloat(height - max(32, height / 28))) <= 1)
        }
    }
}

extension CaptionRendererTests {
    @Test func highlightNeverMovesThePage() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            for mode in ["color", "box", "scale"] {
                var style = CaptionStyle()
                style.highlight = mode
                let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                let plain = try renderer.render(text: "Every moment has a story", to: folder)
                for index in 0..<5 {
                    let lit = try renderer.render(text: "Every moment has a story", activeIndex: index, to: folder)
                    #expect(abs(lit.width - plain.width) <= 1 && lit.height == plain.height)
                }
            }
        }.value
    }

    @Test func wideHighlightFontIsReservedInEveryState() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.highlight = "color"
            let narrow = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "Thin wide end", to: folder)
            style.highlightFont = "mono"
            style.highlightDecor = CaptionWordDecor(italic: true, bgOn: true)
            style.emphasis = "both"
            style.emphasisDecor = CaptionWordDecor(size: 80)
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "Thin wide end", to: folder)
            // The wider italic highlight and larger emphasis grow the reserved
            // slots before either state is drawn, and never shift the page.
            #expect(plain.width > narrow.width)
            for index in 0..<3 {
                let lit = try renderer.render(text: "Thin wide end", activeIndex: index, to: folder)
                #expect(abs(lit.width - plain.width) <= 1 && lit.height == plain.height)
            }
        }.value
    }
}

extension CaptionRendererTests {
    @Test func entranceFramesKeepTheirEnvelopeAndSafeWidth() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
            for motion in ["pop", "slide-up", "fade"] {
                var style = CaptionStyle()
                style.animation = motion
                style.highlight = "scale"
                let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: safe)
                let steady = try renderer.render(text: "Every strong moment earns victory", to: folder)
                #expect(Double(steady.width) <= safe.rect.width * 1080 + 1)
                for frame in CaptionAnimation.frames(for: motion, duration: 0.16) {
                    let animated = try renderer.render(text: "Every strong moment earns victory", frame: frame, to: folder)
                    #expect(animated.width == steady.width && animated.height == steady.height)
                }
            }
        }.value
    }
}

extension CaptionRendererTests {
    nonisolated private static func pixels(_ rendered: CaptionRenderer.RenderedCaption) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(rendered.pngURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test func decorationsAddPixelsBelowAndThroughTheWord() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.strokeWidth = 0
            style.text = CaptionWordDecor()
            let plain = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "OOOO", to: folder)
            let base = try Self.pixels(plain)
            let occupied = stride(from: 3, to: base.count, by: 4).filter { base[$0] > 128 }
            let minRow = try #require(occupied.map { ($0 / 4) / plain.width }.min())
            let maxRow = try #require(occupied.map { ($0 / 4) / plain.width }.max())
            for strike in [false, true] {
                style.text = CaptionWordDecor(underline: !strike, strikethrough: strike)
                let result = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                    .render(text: "OOOO", to: folder)
                #expect(result.width == plain.width && result.height == plain.height)
                let decorated = try Self.pixels(result)
                let added = stride(from: 3, to: base.count, by: 4).filter { decorated[$0] > 128 && base[$0] == 0 }
                #expect(!added.isEmpty)
                let rows = added.map { ($0 / 4) / plain.width }
                if strike { #expect(rows.contains { $0 > minRow && $0 < maxRow }) }
                else { #expect(rows.contains { $0 < minRow || $0 > maxRow }) }
            }
        }.value
    }

    @Test func squareAndRoundedWordBackgroundCorners() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.strokeWidth = 0
            style.text = CaptionWordDecor(bgOn: true, bgColor: "#ff0000", bgRadius: 0)
            let square = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "WORD", to: folder)
            let bytes = try Self.pixels(square)
            let filled = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 250 }
            let x = try #require(filled.map { ($0 / 4) % square.width }.min()) + 1
            let y = try #require(filled.map { ($0 / 4) / square.width }.min()) + 1
            style.text?.bgRadius = 20
            let rounded = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "WORD", to: folder)
            #expect(square.width == rounded.width && square.height == rounded.height)
            let roundedBytes = try Self.pixels(rounded)
            let corner = (y * square.width + x) * 4 + 3
            #expect(bytes[corner] == 255 && roundedBytes[corner] == 0)
        }.value
    }

    @Test func neighboursKeepTheirPixelPositionsAcrossStates() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.highlight = "color"
            style.highlightFont = "mono"
            style.highlightDecor = CaptionWordDecor(italic: true, size: 70, bgOn: true)
            style.emphasis = "both"
            style.emphasisDecor = CaptionWordDecor(size: 90)
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "IIII IIII IIII", to: folder)
            let base = try Self.pixels(plain)
            for active in [false, true] {
                let changed = try renderer.render(text: "IIII IIII IIII", activeIndex: active ? 1 : nil,
                                                  emphasis: active ? [] : [1], to: folder)
                #expect(changed.width == plain.width && changed.height == plain.height)
                let bytes = try Self.pixels(changed)
                let neighboursMatch = (0..<plain.height).allSatisfy { y in
                    (0..<plain.width).allSatisfy { x in
                        guard x < plain.width / 3 || x >= plain.width * 2 / 3 else { return true }
                        let offset = (y * plain.width + x) * 4
                        return bytes[offset..<offset + 4] == base[offset..<offset + 4]
                    }
                }
                #expect(neighboursMatch)
            }
        }.value
    }
}

extension CaptionRendererTests {
    @Test func safeAreaOnlyKeepsExplicitBottomAboveInstagramFooter() throws {
        let safe = try #require(PlatformSafeArea.resolve(platforms: [.instagram], aspectRatio: 9.0 / 16))
        let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
        let plain = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safe)
        var guarded = plain
        guarded.safeAreaOnly = true
        #expect(plain.position(for: caption, positionOverride: "bottom").y == 1752)
        let position = guarded.position(for: caption, positionOverride: "bottom")
        #expect(Double(position.y + caption.height) <= safe.rect.maxY * 1920 + 1)
        for position in ["bottom", "top", "middle", "auto"] {
            let band = guarded.twoRowBand(positionOverride: position)
            #expect(band.minY >= safe.rect.minY * 1920 - 1)
            #expect(band.maxY <= safe.rect.maxY * 1920 + 1)
        }
    }

    @Test func draggedPositionCentresTheCaptionAndStaysInsideTheFrameAndSafeArea() throws {
        let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/unused"), width: 500, height: 100)
        let plain = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: nil)
        let middle = plain.position(for: caption, positionOverride: CustomPosition(x: 0.5, y: 0.5).string)
        #expect(middle.x == 290 && middle.y == 910)
        let corner = plain.position(for: caption, positionOverride: CustomPosition(x: 1, y: 1).string)
        #expect(corner.x == 580 && corner.y == 1820, "never past the frame edge")
        // The Builder's clip path accepts the same string.
        #expect(plain.position(for: caption, clipPosition: CustomPosition(x: 0.5, y: 0.5).string) == (290, 910))
        // Safe area only keeps a dragged caption clear of the platform chrome.
        let safe = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: 9.0 / 16))
        let guarded = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safe, safeAreaOnly: true)
        let low = guarded.position(for: caption, positionOverride: CustomPosition(x: 0.5, y: 1).string)
        #expect(Double(low.y + caption.height) <= safe.rect.maxY * 1920 + 1)
        let free = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: safe, safeAreaOnly: false)
        #expect(free.position(for: caption, positionOverride: CustomPosition(x: 0.5, y: 1).string).y == 1820,
                "without safe area only the user's spot is honoured exactly")
    }
}

extension CaptionRendererTests {
    @Test func fontOnlyEmphasisUsesItsFontAndDecorWithTheTextColorAtNormalScale() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.color = "#33aa77"
            style.strokeWidth = 0
            style.emphasis = "font"
            style.emphasisColor = "#ff0000" // Must not colour a font-only emphasis word.
            style.emphasisFont = "Georgia"
            style.emphasisDecor = CaptionWordDecor(italic: true)
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "Quiet strength", to: folder)
            let emphasis = try renderer.render(text: "Quiet strength", emphasis: [1], to: folder)
            let pixels = try Self.pixels(emphasis)
            #expect(plain.width == emphasis.width && plain.height == emphasis.height)
            #expect(try Self.pixels(plain) != pixels, "the emphasis font changes the glyphs")
            let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 250 }
            #expect(!opaque.isEmpty)
            // The text colour as the renderer's colour pipeline writes it (generic
            // RGB into the PNG, read back as device RGB), taken from the plain render.
            let plainPixels = try Self.pixels(plain)
            let sample = try #require(stride(from: 0, to: plainPixels.count, by: 4).first { plainPixels[$0 + 3] > 250 })
            let expected: [Int] = [Int(plainPixels[sample]), Int(plainPixels[sample + 1]), Int(plainPixels[sample + 2])]
            func matches(_ offset: Int, in bytes: [UInt8], _ colour: [Int]) -> Bool {
                let r = abs(Int(bytes[offset]) - colour[0])
                let g = abs(Int(bytes[offset + 1]) - colour[1])
                let b = abs(Int(bytes[offset + 2]) - colour[2])
                return r < 4 && g < 4 && b < 4
            }
            let allTextColour: Bool = opaque.allSatisfy { matches($0, in: pixels, expected) }
            #expect(allTextColour, "a font-only emphasis word keeps the text colour")
            // Colour emphasis at the text colour is the same unscaled font/decor.
            style.emphasis = "color"
            style.emphasisColor = style.color
            let reference = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "Quiet strength", emphasis: [1], to: folder)
            #expect(reference.width == emphasis.width && reference.height == emphasis.height)
            #expect(try Self.pixels(reference) == pixels)
            style.emphasis = "font"
            style.emphasisDecor?.italic = false
            let roman = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "Quiet strength", emphasis: [1], to: folder)
            #expect(try Self.pixels(roman) != pixels, "font-only emphasis honors its italic decoration")
            style.emphasisDecor?.italic = true
            style.emphasisFont = "sans"
            let sans = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
                .render(text: "Quiet strength", emphasis: [1], to: folder)
            #expect(try Self.pixels(sans) != pixels, "the family comes from emphasisFont")
        }.value
    }

    @Test func interviewSerifPresetRendersSerifEmphasisAndRedSpokenWords() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let style = try #require(CaptionPresets.styles.first { $0.name == "Interview Serif" }).style
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try renderer.render(text: "Quiet strength wins", to: folder)
            let emphasized = try renderer.render(text: "Quiet strength wins", emphasis: [1], to: folder)
            let spoken = try renderer.render(text: "Quiet strength wins", activeIndex: 0, emphasis: [1], to: folder)
            #expect(plain.width == emphasized.width && plain.height == emphasized.height)
            #expect(spoken.width == emphasized.width && spoken.height == emphasized.height)
            #expect(try Self.pixels(plain) != Self.pixels(emphasized))
            let pixels = try Self.pixels(spoken)
            // The preset's red as the renderer writes it, from an all-red reference render.
            let reference = try Self.pixels(renderer.render(text: "Quiet strength wins", textColor: style.resolvedHighlightColor, to: folder))
            let sample = try #require(stride(from: 0, to: reference.count, by: 4).first { reference[$0 + 3] > 250 })
            let red: [Int] = [Int(reference[sample]), Int(reference[sample + 1]), Int(reference[sample + 2])]
            #expect(red[0] > red[1] + 60 && red[0] > red[2] + 60, "the preset's highlight is red")
            func isRed(_ offset: Int) -> Bool {
                guard pixels[offset + 3] > 250 else { return false }
                let r = abs(Int(pixels[offset]) - red[0])
                let g = abs(Int(pixels[offset + 1]) - red[1])
                let b = abs(Int(pixels[offset + 2]) - red[2])
                return r < 4 && g < 4 && b < 4
            }
            let hasRed: Bool = stride(from: 0, to: pixels.count, by: 4).contains { isRed($0) }
            #expect(hasRed, "the spoken word is drawn in the highlight red")
        }.value
    }
}

extension CaptionRendererTests {
    @Test func highlightWordCanHaveItsOwnWeightOutlineSpacingAndShadow() async throws {
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var style = CaptionStyle()
            style.strokeWidth = 0
            style.highlight = "color"
            style.highlightColor = style.color
            style.text = CaptionWordDecor()
            style.highlightDecor = CaptionWordDecor()
            let inherited = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style)
            let plain = try inherited.render(text: "Quiet strength", to: folder)
            let lit = try inherited.render(text: "Quiet strength", activeIndex: 1, to: folder)
            #expect(try Self.pixels(plain) == Self.pixels(lit), "same colour, same typography: nothing changes")
            for change: (inout CaptionWordDecor) -> Void in [
                { $0.weight = "black" }, { $0.strokeWidth = 4 }, { $0.letterSpacing = 4 }, { $0.shadow = true },
            ] {
                var variant = style
                change(&variant.highlightDecor!)
                let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: variant)
                let unlit = try renderer.render(text: "Quiet strength", to: folder)
                #expect(try Self.pixels(unlit) == Self.pixels(plain) || unlit.width != plain.width,
                        "the plain word is unaffected except for the reserved width")
                let highlighted = try renderer.render(text: "Quiet strength", activeIndex: 1, to: folder)
                #expect(try Self.pixels(highlighted) != Self.pixels(unlit), "the spoken word shows its own typography")
            }
        }.value
    }
}

extension CaptionRendererTests {
    @Test func newDecorCanStrokeTextWithPageBackground() async throws {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var style = CaptionStyle()
            style.bgOn = true
            style.decor = TextDecor(strokeOn: false)
            let plain = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil).render(text: "Box", to: directory)
            style.decor?.strokeOn = true; style.decor?.strokeColor = "#ff0000"; style.decor?.strokeWidth = 4
            let stroke = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil).render(text: "Box", to: directory)
            #expect(try Data(contentsOf: plain.pngURL) != Data(contentsOf: stroke.pngURL))
        }.value
    }
}

extension CaptionRendererTests {
    @Test func asWrittenStatePreservesOriginalCasing() async throws {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var style = CaptionStyle()
            style.uppercase = true
            style.highlight = "color"
            style.highlightDecor = CaptionWordDecor(decor: TextDecor(casing: "asWritten"))
            let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
            let mixed = try renderer.render(text: "MiXeD", activeIndex: 0, to: directory)
            let upper = try renderer.render(text: "MIXED", activeIndex: 0, to: directory)
            #expect(try Data(contentsOf: mixed.pngURL) != Data(contentsOf: upper.pngURL))
        }.value
    }
}
