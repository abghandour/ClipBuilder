import Foundation
import CoreGraphics

nonisolated extension WizardOptions {
    /// Explicit false wins; old Mini runs retain their name-tags-only intent.
    var usesNameTags: Bool { nameTags ?? (nameTagsOnly == true && enableTextOverlays) }
}

nonisolated enum WizardNameTags {
    static func settings(options: WizardOptions, captionStyle: CaptionStyle) -> NameTagPlanner.Settings {
        let render = options.renderSettings
        let safe = PlatformSafeArea.resolve(render)
        let canvas = CGSize(width: render.width, height: render.height)
        let safeRect = safe.map {
            CGRect(x: $0.rect.minX * canvas.width, y: $0.rect.minY * canvas.height,
                   width: $0.rect.width * canvas.width, height: $0.rect.height * canvas.height)
        }
        let renderer = CaptionRenderer(videoWidth: render.width, videoHeight: render.height,
                                       style: captionStyle, safeArea: safe)
        return NameTagPlanner.Settings(content: options.nameTagContent, position: options.nameTagPosition,
            safeRect: safeRect, captionBand: options.addCaptions
                ? renderer.twoRowBand(positionOverride: options.captionPositionOverride) : nil, canvas: canvas)
    }

    static func overlays(areas: [NameTagPlanner.Area], people: [PersonRecord],
                         options: WizardOptions, captionStyle: CaptionStyle) -> [TextOverlayItem] {
        guard options.usesNameTags else { return [] }
        let names = people.filter { !$0.name.isEmpty && !$0.hidden }.map {
            NameTagPlanner.Person(key: $0.key, name: $0.displayName, role: $0.descriptor)
        }
        let template = OverlayTemplateStore.composition(named: options.nameTagStyle)?.texts.first
        let tags = NameTagPlanner.plan(areas: areas, people: names,
            settings: settings(options: options, captionStyle: captionStyle), template: template)
        let canvas = CGSize(width: options.renderSettings.width, height: options.renderSettings.height)
        return tags.map { NameTagPlanner.overlay($0, canvas: canvas, template: template) }
    }

    static func ordinary(scene: SceneRecord, duration: Double, people: [PersonRecord],
                         options: WizardOptions, captionStyle: CaptionStyle) -> [TextOverlayItem] {
        let identified = people.filter { !$0.name.isEmpty && !$0.hidden && scene.tags.contains($0.tag) }
        guard identified.count == 1 else { return [] }
        let area = NameTagPlanner.Area(
            rect: CGRect(x: 0, y: 0, width: options.renderSettings.width, height: options.renderSettings.height),
            spans: [.init(start: 0, end: duration, personKey: identified[0].key)])
        return overlays(areas: [area], people: identified, options: options, captionStyle: captionStyle)
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
