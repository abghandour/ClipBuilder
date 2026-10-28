import Foundation
import CoreGraphics

nonisolated extension WizardOptions {
    var resolvedSafeAreaPlatforms: [SocialPlatform] {
        if let safeAreaPlatforms, !safeAreaPlatforms.isEmpty { return safeAreaPlatforms }
        return renderSettings.platformSafeArea.platforms
    }

    var resolvedSafeArea: PlatformSafeArea? {
        safeAreaOnly == true
            ? PlatformSafeArea.resolve(platforms: resolvedSafeAreaPlatforms, aspectRatio: renderSettings.aspectRatio)
            : PlatformSafeArea.resolve(renderSettings)
    }

    /// Explicit false wins; old Mini runs retain their name-tags-only intent.
    var usesNameTags: Bool { nameTags ?? (nameTagsOnly == true && enableTextOverlays) }
}

nonisolated enum WizardNameTags {
    static func settings(options: WizardOptions, captionStyle: CaptionStyle) -> NameTagPlanner.Settings {
        let render = options.renderSettings
        let safe = options.resolvedSafeArea
        let canvas = CGSize(width: render.width, height: render.height)
        let safeRect = safe.map {
            CGRect(x: $0.rect.minX * canvas.width, y: $0.rect.minY * canvas.height,
                   width: $0.rect.width * canvas.width, height: $0.rect.height * canvas.height)
        }
        let renderer = CaptionRenderer(videoWidth: render.width, videoHeight: render.height,
                                       style: captionStyle, safeArea: safe, safeAreaOnly: options.safeAreaOnly == true)
        return NameTagPlanner.Settings(position: options.nameTagPosition,
            safeRect: safeRect, captionBand: options.addCaptions
                ? renderer.twoRowBand(positionOverride: options.captionPositionOverride) : nil, canvas: canvas, safeOnly: options.safeAreaOnly == true)
    }

    static func overlays(areas: [NameTagPlanner.Area], people: [PersonRecord], tagText: [String: String],
                         options: WizardOptions, captionStyle: CaptionStyle, profile: BrandProfile,
                         imageAspects: [UUID: CGFloat] = [:]) -> [TextOverlayItem] {
        guard options.usesNameTags else { return [] }
        let names = people.filter { !$0.hidden }.compactMap { person in
            person.tagName.map {
                NameTagPlanner.Person(key: person.key, name: $0, role: tagText[person.key] ?? "", position: person.tagPosition)
            }
        }
        let style = profile.tagStyle(id: options.nameTagStyleID)
        let tags = NameTagPlanner.plan(areas: areas, people: names,
            settings: settings(options: options, captionStyle: captionStyle.applyingSharedStyle(profile.textStyles ?? [])), style: style.applyingSharedStyle(profile.textStyles ?? []), imageAspects: imageAspects)
        let canvas = CGSize(width: options.renderSettings.width, height: options.renderSettings.height)
        return tags.map { NameTagPlanner.overlay($0, canvas: canvas, style: style) }
    }

    static func ordinary(scene: SceneRecord, duration: Double, people: [PersonRecord], tagText: [String: String],
                         options: WizardOptions, captionStyle: CaptionStyle, profile: BrandProfile,
                         imageAspects: [UUID: CGFloat] = [:]) -> [TextOverlayItem] {
        let identified = people.filter { $0.tagName != nil && !$0.hidden && scene.tags.contains($0.tag) }
        guard identified.count == 1 else { return [] }
        let area = NameTagPlanner.Area(
            rect: CGRect(x: 0, y: 0, width: options.renderSettings.width, height: options.renderSettings.height),
            spans: [.init(start: 0, end: duration, personKey: identified[0].key)])
        return overlays(areas: [area], people: identified, tagText: tagText, options: options, captionStyle: captionStyle, profile: profile, imageAspects: imageAspects)
    }

    /// Old plans keep their introductions on disk. A name-tag run suppresses
    /// them in every render/review document without mutating the stored plan.
    static func renderPlan(_ plan: WizardPlan, options: WizardOptions) -> WizardPlan {
        guard options.usesNameTags else { return plan }
        var result = plan
        for index in result.clips.indices { result.clips[index].speakerIntroductions = [] }
        return result
    }
}
