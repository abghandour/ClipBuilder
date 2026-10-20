import CoreGraphics
import Foundation

/// Resolves a still from the same feed assignments and source clocks as the timeline.
nonisolated enum WizardPreviewFraming {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func talker(original: Bool, path: SceneCameraPath?, wide: Bool,
                       time: Double, face: CGRect?) -> WizardPreviewComposite.Framing {
        if original { return .cover(face: nil) }
        if wide, let keyframe = path?.keyframes.min(by: { abs($0.t - time) < abs($1.t - time) }) {
            return .path(keyframe)
        }
        return .cover(face: face)
    }

    static func speaker(video: VideoRecord, record: SceneRecord, turns: [SpeakerTurn],
                        roster: [VideoPersonRecord], people: [PersonRecord]) -> (person: PersonRecord?, face: CGRect?)? {
        let time = (record.startTime + record.endTime) / 2
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        let spans = CropRecipePlanner.segments(turns: turns, tiles: tiles,
            range: record.startTime...record.endTime, hold: 1.5)
        guard let talker = spans.first(where: { $0.start <= time && time < $0.end }),
              let tile = tiles.first(where: { $0.index == talker.talker }) else { return nil }
        let entry = roster.first { $0.key == tile.personKey }
            ?? roster.first { person in
                guard let box = person.portraitBox else { return false }
                return tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2)
            }
        let person = people.first { !$0.hidden && !$0.name.isEmpty && $0.key == (entry?.key ?? tile.personKey) }
        let face: CGRect
        if let box = entry?.portraitBox {
            face = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
        } else if let center = tile.faceCenter {
            face = CGRect(x: center.x - 0.025, y: center.y - 0.025, width: 0.05, height: 0.05)
        } else {
            face = CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)
        }
        return (person, face)
    }

    static func resolve(options: WizardOptions, record: SceneRecord, video: VideoRecord?,
                        face: CGRect?, turns: [SpeakerTurn], roster: [VideoPersonRecord],
                        people: [PersonRecord], layouts: [ScreenCropLayout])
        -> (framing: WizardPreviewComposite.Framing, warning: String?) {
        let time = (record.startTime + record.endTime) / 2
        let fallback = talker(original: options.podcastFraming == .original,
            path: record.centerStagePath, wide: record.wide, time: time - record.startTime, face: face)
        guard options.podcastFraming != .original else { return (fallback, nil) }
        // Talker (and "Let AI choose", which picks a recipe per take) on a
        // tiled recording shows the talker's feed full screen, as the
        // podcast timeline does; a single-feed recording keeps the saved
        // Center Stage path or the face crop.
        let kind = options.highlightFraming ?? .talker
        if kind == .talker {
            guard let video, CropRecipePlanner.tiles(video: video, roster: roster).count >= 2 else { return (fallback, nil) }
        }
        do {
            guard let video else {
                throw CropRecipePlanner.Failure(description: "The file's frame size is unknown; analyze it first.")
            }
            let plan = try CropRecipePlanner.plan(CropRecipe(kind: kind), video: video,
                range: record.startTime...record.endTime, turns: turns, roster: roster,
                layouts: layouts, canvasAspect: options.renderSettings.aspectRatio)
            return (.cells(cells(plan: plan, layouts: layouts, video: video, time: time,
                rangeStart: record.startTime, roster: roster, people: people,
                canvasAspect: options.renderSettings.aspectRatio)), nil)
        } catch let failure as CropRecipePlanner.Failure {
            return (fallback, failure.description)
        } catch {
            return (fallback, error.localizedDescription)
        }
    }

    /// Only pixels affect the base-frame cache; tag text and talking metadata do not.
    static func pixelFraming(_ framing: WizardPreviewComposite.Framing) -> WizardPreviewComposite.Framing {
        if case .cells(let cells) = framing {
            return .cells(cells.map { .init(source: $0.source, area: $0.area) })
        }
        return framing
    }

    static func cells(plan: CropRecipePlanner.Plan, layouts: [ScreenCropLayout], video: VideoRecord,
                      time: Double, rangeStart: Double, roster: [VideoPersonRecord],
                      people: [PersonRecord], canvasAspect: Double) -> [WizardPreviewComposite.Cell] {
        let areas = layouts.first { $0.name.caseInsensitiveCompare(plan.layout.name) == .orderedSame }?.areasInTrackOrder ?? []
        let tiles = CropRecipePlanner.tiles(video: video, roster: roster)
        return plan.slots.enumerated().compactMap { index, slot in
            let area: CGRect
            if plan.layout.isFullScreen {
                area = full
            } else if areas.indices.contains(index) {
                let box = areas[index].bounds
                area = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
            } else { return nil }
            // Recipe paths are hard cuts, with a hold key just before each cut.
            let keyframe = slot.path?.last { $0.t <= time - rangeStart } ?? slot.path?.first
            let region = keyframe.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
                ?? (slot.window ?? slot.region).map { CGRect(x: $0.xFrac, y: $0.yFrac, width: $0.wFrac, height: $0.hFrac) }
                ?? full
            let crop = CropRecipePlanner.crop(
                tile: PodcastTile(index: -1, x: region.minX, y: region.minY, w: region.width, h: region.height),
                aspect: canvasAspect * area.width / max(0.001, area.height),
                sourceAspect: Double(video.width) / Double(video.height), center: keyframe == nil ? slot.focus : nil)
            let source = CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac)
            let tile = tiles.first { $0.contains(x: source.midX, y: source.midY) }
            let entry = roster.first { $0.key == tile?.personKey }
                ?? roster.first { person in
                    guard let box = person.portraitBox else { return false }
                    return tile?.contains(x: box.x + box.w / 2, y: box.y + box.h / 2) == true
                }
            let person = people.first { !$0.hidden && !$0.name.isEmpty && $0.key == (entry?.key ?? tile?.personKey) }
            let face = entry?.portraitBox.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            return WizardPreviewComposite.Cell(source: source, area: area, person: person, face: face,
                                               isTalking: slot.talking.contains { $0.contains(time) })
        }
    }
}
