import Foundation
import CoreGraphics

/// A destination whose player draws its own buttons, captions and header
/// over the picture. Burned-in overlays that land under that chrome are
/// hidden from the viewer.
nonisolated enum SocialPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case instagram, tiktok, youtubeShorts, youtube

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .youtubeShorts: "YouTube Shorts"
        case .youtube: "YouTube"
        }
    }

    var shortLabel: String {
        switch self {
        case .instagram: "Reels"
        case .tiktok: "TikTok"
        case .youtubeShorts: "Shorts"
        case .youtube: "YouTube"
        }
    }

    /// Which canvases this platform's chrome applies to: the portrait feeds
    /// draw over 9:16 (and near-portrait) reels, the YouTube player over
    /// landscape and square video.
    func applies(toAspectRatio aspectRatio: Double) -> Bool {
        switch self {
        case .instagram, .tiktok, .youtubeShorts: aspectRatio < 0.9
        case .youtube: aspectRatio >= 0.9
        }
    }
}

/// The flag: keep overlays and captions out of the chosen platforms' chrome.
nonisolated struct PlatformSafeAreaSettings: Codable, Sendable, Equatable, Hashable {
    var enabled = true
    var platforms: [SocialPlatform] = SocialPlatform.allCases

    var isActive: Bool { enabled && !platforms.isEmpty }
}

/// One region of a platform's player that covers the picture, as a rect in
/// normalized frame coordinates (origin top-left, 0…1 on both axes).
nonisolated struct PlatformChromeZone: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable {
        case header       // top bar: title, search, tabs
        case rail         // right-hand action buttons
        case footer       // username, description, audio line
        case playerBar    // landscape: progress bar and transport controls
    }

    var platform: SocialPlatform
    var kind: Kind
    var rect: CGRect
}

/// Where each platform's chrome sits. The numbers are fractions of the
/// frame measured on current phone layouts (the rail's bottom and the
/// footer's top overlap on every portrait platform).
nonisolated enum PlatformChrome {
    static func zones(for platform: SocialPlatform, aspectRatio: Double) -> [PlatformChromeZone] {
        guard platform.applies(toAspectRatio: aspectRatio) else { return [] }
        func zone(_ kind: PlatformChromeZone.Kind, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PlatformChromeZone {
            PlatformChromeZone(platform: platform, kind: kind, rect: CGRect(x: x, y: y, width: w, height: h))
        }
        switch platform {
        case .instagram:
            return [zone(.header, 0, 0, 1, 0.13),
                    zone(.rail, 0.84, 0.46, 0.16, 0.40),
                    zone(.footer, 0, 0.75, 1, 0.25)]
        case .tiktok:
            return [zone(.header, 0, 0, 1, 0.12),
                    zone(.rail, 0.84, 0.42, 0.16, 0.44),
                    zone(.footer, 0, 0.74, 1, 0.26)]
        case .youtubeShorts:
            return [zone(.header, 0, 0, 1, 0.11),
                    zone(.rail, 0.83, 0.36, 0.17, 0.56),
                    zone(.footer, 0, 0.80, 1, 0.20)]
        case .youtube:
            return [zone(.header, 0, 0, 1, 0.14),
                    zone(.playerBar, 0, 0.84, 1, 0.16)]
        }
    }
}

/// The part of the frame no chosen platform covers, and the zones around
/// it. Overlays are clamped into `rect`; the preview shades the zones.
nonisolated struct PlatformSafeArea: Sendable, Equatable {
    var rect: CGRect
    var zones: [PlatformChromeZone]
    var platforms: [SocialPlatform]

    /// Nil when the flag is off or no chosen platform covers this canvas.
    static func resolve(_ settings: RenderSettings) -> PlatformSafeArea? {
        resolve(settings.platformSafeArea, aspectRatio: settings.aspectRatio)
    }

    static func resolve(_ settings: PlatformSafeAreaSettings, aspectRatio: Double) -> PlatformSafeArea? {
        guard settings.isActive else { return nil }
        return resolve(platforms: settings.platforms, aspectRatio: aspectRatio)
    }

    /// The safe area of these platforms regardless of the flag (the preview
    /// simulation uses it with one platform at a time).
    static func resolve(platforms: [SocialPlatform], aspectRatio: Double) -> PlatformSafeArea? {
        let zones = platforms.flatMap { PlatformChrome.zones(for: $0, aspectRatio: aspectRatio) }
        guard !zones.isEmpty else { return nil }
        var minX = 0.0, minY = 0.0, maxX = 1.0, maxY = 1.0
        for zone in zones {
            switch zone.kind {
            case .header: minY = max(minY, zone.rect.maxY)
            case .rail: maxX = min(maxX, zone.rect.minX)
            case .footer, .playerBar: maxY = min(maxY, zone.rect.minY)
            }
        }
        let rect = CGRect(x: minX, y: minY, width: max(0.2, maxX - minX), height: max(0.2, maxY - minY))
        return PlatformSafeArea(rect: rect, zones: zones,
                                platforms: platforms.filter { $0.applies(toAspectRatio: aspectRatio) })
    }

    /// The centre that keeps a box of `width`×`height` (fractions of the
    /// frame) inside the safe area. A box wider or taller than the area is
    /// centred on it.
    ///
    /// Header and footer span the full width, so the box first moves
    /// between them. A rail only covers part of the height, so the box
    /// moves left of it only where its rows actually overlap the rail — a
    /// hook at the top stays centred, a lower third slides off the buttons.
    func clampedCenter(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
            lower <= upper ? min(max(value, lower), upper) : (lower + upper) / 2
        }
        let halfW = max(0, width) / 2
        let halfH = max(0, height) / 2
        let clampedY = clamp(y, lower: rect.minY + halfH, upper: rect.maxY - halfH)
        var maxX = 1.0
        for zone in zones where zone.kind == .rail
            && zone.rect.minY < clampedY + halfH && zone.rect.maxY > clampedY - halfH {
            maxX = min(maxX, zone.rect.minX)
        }
        return (clamp(x, lower: halfW, upper: maxX - halfW), clampedY)
    }

    /// The top-left origin that keeps a `width`×`height` box inside the area.
    func clampedOrigin(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        let center = clampedCenter(x: x + width / 2, y: y + height / 2, width: width, height: height)
        return (center.x - width / 2, center.y - height / 2)
    }

    /// The platforms whose chrome a normalized box would sit under.
    func collisions(with box: CGRect) -> [SocialPlatform] {
        var hit: [SocialPlatform] = []
        for zone in zones where zone.rect.intersects(box) && !hit.contains(zone.platform) {
            hit.append(zone.platform)
        }
        return hit
    }

    /// Fraction of the frame height taken by the chrome along the bottom.
    var bottomInset: Double { 1 - rect.maxY }
    var topInset: Double { rect.minY }
    var rightInset: Double { 1 - rect.maxX }
}

extension TextOverlayItem {
    /// The box the overlay occupies, as fractions of the frame. Legacy items
    /// (no fractions) get the renderer's named-position estimate.
    var normalizedBox: CGRect {
        let width = wFrac ?? 0.82
        let height = hFrac ?? 0.08
        let x = xFrac ?? 0.5
        let y = yFrac ?? {
            switch position {
            case "top": return 0.08 + height / 2
            case "center", "middle": return 0.5
            default: return 0.85 + height / 2
            }
        }()
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    /// The same overlay moved into the safe area (a no-op when nil).
    func keptClear(of safeArea: PlatformSafeArea?) -> TextOverlayItem {
        guard let safeArea else { return self }
        let box = normalizedBox
        let center = safeArea.clampedCenter(x: box.midX, y: box.midY, width: box.width, height: box.height)
        var item = self
        if abs(center.x - box.midX) > 0.0005 || abs(center.y - box.midY) > 0.0005 || xFrac == nil || yFrac == nil {
            item.xFrac = center.x
            item.yFrac = center.y
        }
        return item
    }
}

extension ImageOverlayItem {
    /// The box the image occupies, taking it as square when its aspect is unknown.
    func normalizedBox(aspectRatio: Double = 1, frameAspectRatio: Double = 9.0 / 16.0) -> CGRect {
        let width = wFrac
        let height = width * frameAspectRatio / max(0.01, aspectRatio)
        return CGRect(x: xFrac - width / 2, y: yFrac - height / 2, width: width, height: height)
    }

    func keptClear(of safeArea: PlatformSafeArea?, aspectRatio: Double = 1, frameAspectRatio: Double = 9.0 / 16.0) -> ImageOverlayItem {
        guard let safeArea else { return self }
        let box = normalizedBox(aspectRatio: aspectRatio, frameAspectRatio: frameAspectRatio)
        let center = safeArea.clampedCenter(x: box.midX, y: box.midY, width: box.width, height: box.height)
        var item = self
        item.xFrac = center.x
        item.yFrac = center.y
        return item
    }
}

extension TimelineDocument {
    /// Every text and image overlay (top level and inside overlay blocks)
    /// moved into the canvas's safe area.
    func keepingOverlaysClearOfPlatformChrome() -> TimelineDocument {
        guard let safeArea = PlatformSafeArea.resolve(renderSettings) else { return self }
        var document = self
        let frameAspect = renderSettings.aspectRatio
        document.textOverlays = textOverlays.map { $0.keptClear(of: safeArea) }
        document.imageOverlays = imageOverlays.map { $0.keptClear(of: safeArea, frameAspectRatio: frameAspect) }
        for index in document.overlayBlocks.indices {
            let composition = document.overlayBlocks[index].composition
            document.overlayBlocks[index].composition.texts = composition.texts.map { $0.keptClear(of: safeArea) }
            document.overlayBlocks[index].composition.images = composition.images.map {
                $0.keptClear(of: safeArea, frameAspectRatio: frameAspect)
            }
        }
        return document
    }
}
