import Foundation
import Testing
@testable import Clip_Builder

struct CaptionRendererTests {
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
