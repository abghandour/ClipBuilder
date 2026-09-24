import Foundation
import Testing
@testable import Clip_Builder

@Suite("Platform safe area")
struct PlatformSafeAreaTests {
    private let portrait = 9.0 / 16.0
    private let landscape = 16.0 / 9.0

    @Test("Portrait platforms cover reels, YouTube covers landscape, and the union is the intersection")
    func resolution() throws {
        let reels = try #require(PlatformSafeArea.resolve(platforms: [.instagram], aspectRatio: portrait))
        #expect(reels.rect.minY == 0.13 && reels.rect.maxY == 0.75 && reels.rect.maxX == 0.84)
        #expect(PlatformSafeArea.resolve(platforms: [.youtube], aspectRatio: portrait) == nil)
        #expect(PlatformSafeArea.resolve(platforms: [.instagram, .tiktok], aspectRatio: landscape) == nil)

        let all = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: portrait))
        #expect(all.platforms == [.instagram, .tiktok, .youtubeShorts])
        #expect(all.rect.minY == 0.13)          // Instagram's header is the tallest
        #expect(all.rect.maxY == 0.74)          // TikTok's footer starts highest
        #expect(all.rect.maxX == 0.83)          // Shorts' rail is the widest

        let player = try #require(PlatformSafeArea.resolve(platforms: [.youtube], aspectRatio: landscape))
        #expect(player.rect.minY == 0.14 && player.rect.maxY == 0.84 && player.rect.maxX == 1)
    }

    @Test("The flag off, or no platforms, resolves to nothing")
    func disabled() {
        var settings = RenderSettings()
        #expect(PlatformSafeArea.resolve(settings) != nil)
        settings.platformSafeArea.enabled = false
        #expect(PlatformSafeArea.resolve(settings) == nil)
        settings.platformSafeArea = PlatformSafeAreaSettings(enabled: true, platforms: [])
        #expect(PlatformSafeArea.resolve(settings) == nil)
    }

    @Test("Centres clamp so the whole box stays inside, oversized boxes centre on the area")
    func clamping() throws {
        let area = try #require(PlatformSafeArea.resolve(platforms: [.youtubeShorts], aspectRatio: portrait))
        // Right-aligned lower third (x 0.73, w 0.42) moves left of the rail.
        let name = area.clampedCenter(x: 0.73, y: 0.78, width: 0.42, height: 0.07)
        #expect(abs(name.x - (0.83 - 0.21)) < 0.0001)
        #expect(abs(name.y - (0.80 - 0.035)) < 0.0001)
        // Already inside: unchanged.
        let hook = area.clampedCenter(x: 0.4, y: 0.3, width: 0.5, height: 0.1)
        #expect(hook.x == 0.4 && hook.y == 0.3)
        // Wider than the safe area: centred on it.
        let banner = area.clampedCenter(x: 0.9, y: 0.5, width: 0.95, height: 0.1)
        #expect(abs(banner.x - 0.415) < 0.0001)
        #expect(area.collisions(with: CGRect(x: 0.6, y: 0.7, width: 0.4, height: 0.2)) == [.youtubeShorts])
        #expect(area.collisions(with: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.1)).isEmpty)
    }

    @Test("Overlay items move into the area, legacy positions gain fractions")
    func overlayItems() throws {
        let area = try #require(PlatformSafeArea.resolve(platforms: SocialPlatform.allCases, aspectRatio: portrait))
        var text = TextOverlayItem(text: "Name", startTime: 0, endTime: 3)
        text.xFrac = 0.5; text.yFrac = 0.76; text.wFrac = 0.82; text.hFrac = 0.12
        let moved = text.keptClear(of: area)
        #expect(abs((moved.yFrac ?? 0) - (0.74 - 0.06)) < 0.0001)
        // At that height the 82%-wide box overlaps the rail, so it slides left of it.
        #expect(abs((moved.xFrac ?? 0) - 0.42) < 0.0001)
        #expect(text.keptClear(of: nil) == text)
        // A top hook never meets the rail: it stays centred.
        var hook = text
        hook.yFrac = 0.2
        #expect(hook.keptClear(of: area).xFrac == 0.5 && hook.keptClear(of: area).yFrac == 0.2)

        var legacy = TextOverlayItem(text: "Bottom", startTime: 0, endTime: 3)
        legacy.position = "bottom"
        let lifted = legacy.keptClear(of: area)
        #expect(abs((lifted.xFrac ?? 0) - 0.42) < 0.0001)
        #expect((lifted.yFrac ?? 1) + 0.04 <= 0.74 + 0.0001)

        var logo = ImageOverlayItem(path: "/tmp/logo.png", startTime: 0, endTime: 3)
        logo.xFrac = 0.95; logo.yFrac = 0.05; logo.wFrac = 0.2
        let tucked = logo.keptClear(of: area, frameAspectRatio: portrait)
        // Below the header it clears every rail, so it keeps the right edge.
        #expect(abs(tucked.xFrac - 0.9) < 0.0001)
        #expect(tucked.yFrac > 0.13)
    }

    @Test("A document keeps top-level and block overlays clear, and only when the flag is on")
    func document() {
        var document = TimelineDocument()
        document.renderSettings = RenderSettings()
        var text = TextOverlayItem(text: "Name", startTime: 0, endTime: 3)
        text.xFrac = 0.73; text.yFrac = 0.9; text.wFrac = 0.42; text.hFrac = 0.07
        document.textOverlays = [text]
        var block = OverlayBlockItem()
        block.composition = LowerThirdOverlay.composition(name: "Guest", role: "Coach", rightAligned: true)
        document.overlayBlocks = [block]

        let cleared = document.keepingOverlaysClearOfPlatformChrome()
        #expect((cleared.textOverlays[0].yFrac ?? 1) < 0.74)
        #expect((cleared.textOverlays[0].xFrac ?? 1) < 0.73)
        #expect(cleared.overlayBlocks[0].composition.texts.allSatisfy { ($0.xFrac ?? 1) + 0.21 <= 0.83 + 0.0001 })

        document.renderSettings.platformSafeArea.enabled = false
        #expect(document.keepingOverlaysClearOfPlatformChrome().textOverlays[0].yFrac == 0.9)
    }

    @Test("Captions lift above the footer and settle below the header")
    func captions() {
        let settings = RenderSettings()
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(),
                                       safeArea: PlatformSafeArea.resolve(settings))
        let caption = CaptionRenderer.RenderedCaption(pngURL: URL(fileURLWithPath: "/tmp/c.png"), width: 900, height: 120)
        let bottom = renderer.position(for: caption, positionOverride: "bottom")
        #expect(bottom.y + 120 <= Int(0.74 * 1920))
        #expect(bottom.y + 120 > Int(0.74 * 1920) - 80)
        let top = renderer.position(for: caption, positionOverride: "top")
        #expect(top.y >= Int(0.13 * 1920))
        let plain = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: CaptionStyle(), safeArea: nil)
        #expect(plain.position(for: caption).y == 1920 - 120 - max(40, 1920 / 18))
    }

    @Test("Render settings saved before the flag decode with it on, and round-trip")
    func decoding() throws {
        let legacy = Data(#"{"preset":"portrait1080","customWidth":1080,"customHeight":1920,"quality":"balanced","customCRF":20}"#.utf8)
        let decoded = try JSONDecoder().decode(RenderSettings.self, from: legacy)
        #expect(decoded.platformSafeArea == PlatformSafeAreaSettings())
        var custom = RenderSettings()
        custom.platformSafeArea = PlatformSafeAreaSettings(enabled: true, platforms: [.tiktok])
        let roundTrip = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(custom))
        #expect(roundTrip == custom)
        #expect(roundTrip.platformSafeArea.platforms == [.tiktok])
    }
}
