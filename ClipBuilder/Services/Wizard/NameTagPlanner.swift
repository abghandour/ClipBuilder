import Foundation
import CoreGraphics

nonisolated struct NameTag: Sendable, Equatable {
    var personKey: String
    var lines: [String]
    var areaRect: CGRect
    var rect: CGRect
    var corner: NameTagPlanner.Corner
    var fontSize: Int
    var start: Double
    var end: Double
}

/// All geometry is in canvas pixels with a top-left origin; clocks are cut-local.
nonisolated enum NameTagPlanner {
    enum Corner: String, CaseIterable, Sendable {
        case bottomLeading, bottomTrailing, topLeading, topTrailing
    }
    struct Person: Sendable {
        var key: String
        var name: String
        var role: String = ""
        /// This person's own corner (a `Corner` raw value); nil follows the run.
        var position: String? = nil
    }

    /// The person tag field that stores a per-person corner.
    static let positionField = "Tag position"
    struct Span: Sendable {
        var start: Double
        var end: Double
        var personKey: String?
        var faceBox: CGRect? = nil
    }
    struct Area: Sendable {
        var rect: CGRect
        var spans: [Span]
    }
    struct Settings: Sendable {
        var position: String? = nil
        var safeRect: CGRect? = nil
        var captionBand: CGRect? = nil
        var canvas: CGSize = CGSize(width: 1080, height: 1920)
        var safeOnly = false
    }

    static func plan(areas: [Area], people: [Person], settings: Settings,
                     style: TagStyle = TagStyle(), imageAspects: [UUID: CGFloat] = [:]) -> [NameTag] {
        let names = Dictionary(people.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let explicitCorner = Corner(rawValue: settings.position ?? "")
        // Dragged in the preview: every tag without its own corner is centred
        // on this canvas point (inside its area), never moved for the caption.
        let customAnchor = CustomPosition(settings.position)
        let frame = CGRect(origin: .zero, size: settings.canvas)
        let renderer = TextOverlayRenderer(videoWidth: Int(settings.canvas.width),
                                           videoHeight: Int(settings.canvas.height), safeArea: nil)
        return areas.flatMap { area -> [NameTag] in
            let inset = min(area.rect.width, area.rect.height) * 0.04
            var allowed = area.rect.insetBy(dx: inset, dy: inset)
            if (explicitCorner == nil || settings.safeOnly), let safe = settings.safeRect {
                allowed = allowed.intersection(safe)
                if allowed.isNull || allowed.isEmpty { allowed = safe.intersection(frame) }
            }
            guard !allowed.isNull, allowed.width > 0, allowed.height > 0 else { return [] }
            var tags: [NameTag] = []
            for span in area.spans.sorted(by: { ($0.start, $0.faceBox?.midX ?? 0) < ($1.start, $1.faceBox?.midX ?? 0) }) {
                guard span.end > span.start, let key = span.personKey, let person = names[key] else { continue }
                let name = person.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let role = person.role.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !name.isEmpty else { continue }
                let lines = !role.isEmpty ? [name, role] : [name]
                var item = styledItem(lines: lines, style: style)
                let scale = settings.canvas.height / 1920
                item.fontsize = Int(min(64, max(30, min(area.rect.width, area.rect.height) * 0.075 / scale)))
                let layout = renderer.nameTagLayout(item, maxWidth: min(area.rect.width * 0.6, allowed.width), imageAspects: imageAspects)
                let fit = min(1, min(area.rect.width * 0.6, allowed.width) / max(1, layout.size.width),
                              allowed.height / max(1, layout.size.height))
                let width = layout.size.width * fit
                let height = layout.size.height * fit
                func rect(_ corner: Corner) -> CGRect {
                    let y = corner == .bottomLeading || corner == .bottomTrailing ? allowed.maxY - height : allowed.minY
                    let verticalBounds = height <= allowed.height ? allowed
                        : ((explicitCorner == nil || settings.safeOnly) ? settings.safeRect?.intersection(frame) ?? frame : frame)
                    return CGRect(x: corner == .topTrailing || corner == .bottomTrailing ? allowed.maxX - width : allowed.minX,
                                  y: max(verticalBounds.minY, min(y, verticalBounds.maxY - height)),
                                  width: width, height: height)
                }
                let face = span.faceBox.map { $0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15) }
                // Tags already on screen at the same time in this area (the
                // other person of a two-shot) are obstacles too.
                let concurrent = tags.filter { $0.personKey != key && $0.start < span.end && $0.end > span.start }.map(\.rect)
                func overlap(_ box: CGRect) -> CGFloat {
                    ([face, settings.captionBand].compactMap { $0 } + concurrent).reduce(0) { total, obstacle in
                        let hit = box.intersection(obstacle)
                        return total + (hit.isNull ? 0 : hit.width * hit.height)
                    }
                }
                // Ties go to the corner on the person's side of the area.
                func sidePenalty(_ corner: Corner) -> Int {
                    guard let face = span.faceBox else { return 0 }
                    let trailing = corner == .topTrailing || corner == .bottomTrailing
                    return (face.midX >= area.rect.midX) == trailing ? 0 : 1
                }
                let personCorner = Corner(rawValue: person.position ?? "")
                let gap = settings.canvas.height * 0.01
                if personCorner == nil, let customAnchor {
                    let origin = customAnchor.origin(size: CGSize(width: width, height: height), in: allowed)
                    let anchored = CGRect(origin: origin, size: CGSize(width: width, height: height))
                    let corner: Corner = anchored.midY < area.rect.midY
                        ? (anchored.midX < area.rect.midX ? .topLeading : .topTrailing)
                        : (anchored.midX < area.rect.midX ? .bottomLeading : .bottomTrailing)
                    let bounds = settings.safeOnly ? (settings.safeRect?.intersection(frame) ?? frame) : frame
                    let placed = clearingConcurrent(anchored, corner: corner, others: concurrent, bounds: bounds, gap: gap) ?? anchored
                    let tag = NameTag(personKey: key, lines: layout.lines, areaRect: area.rect, rect: placed,
                                      corner: corner, fontSize: layout.fontSize, start: span.start, end: span.end)
                    if let index = tags.lastIndex(where: { $0.personKey == key && $0.lines == tag.lines
                            && $0.rect == tag.rect && abs($0.end - tag.start) < 0.00001 }) {
                        tags[index].end = tag.end
                    } else { tags.append(tag) }
                    continue
                }
                let corner = personCorner ?? explicitCorner ?? Corner.allCases.enumerated().min {
                    (overlap(rect($0.element)), sidePenalty($0.element), $0.offset)
                        < (overlap(rect($1.element)), sidePenalty($1.element), $1.offset)
                }!.element
                let safe = (explicitCorner == nil || settings.safeOnly) ? settings.safeRect : nil
                guard let cleared = clearingCaption(rect(corner), corner: corner, area: area.rect,
                    allowed: allowed, frame: frame, safe: safe,
                    band: settings.captionBand, safeOnly: settings.safeOnly, gap: gap) else { continue }
                // Two people on screen at once never share pixels: a tag that
                // lands on another is stacked away from it along its corner's
                // edge, and failing that takes the first free corner.
                let bounds = safe.map { $0.intersection(frame) } ?? frame
                let placed = clearingConcurrent(cleared, corner: corner, others: concurrent, bounds: bounds, gap: gap) ?? {
                    for other in Corner.allCases where other != corner {
                        guard let candidate = clearingCaption(rect(other), corner: other, area: area.rect,
                            allowed: allowed, frame: frame, safe: safe,
                            band: settings.captionBand, safeOnly: settings.safeOnly, gap: gap),
                              let free = clearingConcurrent(candidate, corner: other, others: concurrent, bounds: bounds, gap: gap)
                        else { continue }
                        return free
                    }
                    return cleared
                }()
                let tag = NameTag(personKey: key, lines: layout.lines, areaRect: area.rect, rect: placed,
                                  corner: corner, fontSize: layout.fontSize, start: span.start, end: span.end)
                if let index = tags.lastIndex(where: { $0.personKey == key && $0.lines == tag.lines
                        && $0.rect == tag.rect && abs($0.end - tag.start) < 0.00001 }) {
                    tags[index].end = tag.end
                } else { tags.append(tag) }
            }
            return tags
        }
    }

    /// Slide a tag off the tags already on screen: up from a bottom corner,
    /// down from a top one, as far as the bounds allow. nil when no clear
    /// spot exists along that edge.
    static func clearingConcurrent(_ rect: CGRect, corner: Corner, others: [CGRect],
                                   bounds: CGRect, gap: CGFloat) -> CGRect? {
        var candidate = rect
        for _ in 0..<(others.count + 1) {
            guard let hit = others.first(where: { candidate.intersects($0) }) else { return candidate }
            let y = corner == .bottomLeading || corner == .bottomTrailing
                ? hit.minY - gap - candidate.height : hit.maxY + gap
            guard y >= bounds.minY - 0.00001, y + candidate.height <= bounds.maxY + 0.00001 else { return nil }
            candidate.origin.y = y
        }
        return others.contains { candidate.intersects($0) } ? nil : candidate
    }

    /// Prefer the requested side within the area. If the band consumes the
    /// whole cell, use the nearest adjacent free strip of the frame instead.
    private static func clearingCaption(_ rect: CGRect, corner: Corner, area: CGRect,
                                        allowed: CGRect, frame: CGRect, safe: CGRect?,
                                        band: CGRect?, safeOnly: Bool, gap: CGFloat) -> CGRect? {
        guard let band, rect.intersects(band.insetBy(dx: 0, dy: -gap)) else { return rect }
        let above = band.minY - gap - rect.height
        let below = band.maxY + gap
        let bottom = corner == .bottomLeading || corner == .bottomTrailing
        let coversArea = band.minY <= area.minY && band.maxY >= area.maxY
        let nearerAbove = area.minY - band.minY <= band.maxY - area.maxY
        let preferred = coversArea
            ? (nearerAbove ? [above, below] : [below, above])
            : (bottom ? [above, below] : [below, above])
        let areaBounds = safe.map { area.intersection($0) } ?? area
        let frameBounds = safe.map { frame.intersection($0) } ?? frame
        for bounds in [allowed, areaBounds, frameBounds] + (safeOnly ? [] : [frame]) where !bounds.isNull && !bounds.isEmpty {
            guard rect.height <= bounds.height else { continue }
            for y in preferred {
                let candidate = CGRect(x: rect.minX,
                    y: max(bounds.minY, min(y, bounds.maxY - rect.height)),
                    width: rect.width, height: rect.height)
                if candidate.maxY <= band.minY - gap + 0.00001 || candidate.minY >= band.maxY + gap - 0.00001 {
                    return candidate
                }
            }
        }
        // A band covering the entire frame leaves no place for a readable tag.
        return nil
    }

    private static func styledItem(lines: [String], style: TagStyle) -> TextOverlayItem {
        var item = TextOverlayItem()
        item.tagStyle = style
        item.text = lines.joined(separator: "\n")
        item.design = "nameTag"
        item.kicker = nil
        return item
    }

    /// Read the actual composed slots, including their hold keyframes. No
    /// second speaker-turn planner: its cut times could disagree with the picture.
    static func areas(plan: CropRecipePlanner.Plan, tiles: [PodcastTile], roster: [VideoPersonRecord],
                      layouts: [ScreenCropLayout], canvas: CGSize, duration: Double, sourceAspect: Double = 1) -> [Area] {
        let rectangles: [CGRect]
        if plan.layout.isFullScreen {
            rectangles = [CGRect(origin: .zero, size: canvas)]
        } else {
            rectangles = layouts.first { $0.name.caseInsensitiveCompare(plan.layout.name) == .orderedSame }?
                .areasInTrackOrder.map {
                    let b = $0.bounds
                    return CGRect(x: b.x * canvas.width, y: b.y * canvas.height,
                                  width: b.w * canvas.width, height: b.h * canvas.height)
                } ?? []
        }
        return zip(plan.slots, rectangles).map { slot, area in
            // A portrait from an analysis before face snapping can cover the
            // whole frame; the feed's own face position is the better guide.
            func face(of tile: PodcastTile) -> CGRect? {
                if let box = roster.first(where: { $0.key == tile.personKey })?.portraitBox,
                   box.w < 0.9 || box.h < 0.9, tile.contains(x: box.x + box.w / 2, y: box.y + box.h / 2) {
                    return CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
                }
                if let center = tile.faceCenter {
                    return CGRect(x: center.x - tile.w * 0.10, y: center.y - tile.h * 0.10,
                                  width: tile.w * 0.20, height: tile.h * 0.20)
                }
                return nil
            }
            func span(tile: PodcastTile, start: Double, end: Double, crop: CGRect) -> Span {
                let projected = face(of: tile).map { box in
                    CGRect(x: area.minX + (box.minX - crop.minX) / max(0.001, crop.width) * area.width,
                           y: area.minY + (box.minY - crop.minY) / max(0.001, crop.height) * area.height,
                           width: box.width / max(0.001, crop.width) * area.width,
                           height: box.height / max(0.001, crop.height) * area.height)
                }
                return Span(start: start, end: end, personKey: tile.personKey, faceBox: projected)
            }
            /// Every feed whose face the crop shows is tagged, so a two-shot
            /// names both people. A crop showing no face falls back to the
            /// feed it overlaps most, chosen before looking up identity so an
            /// unnamed feed never inherits another name.
            func shownSpans(start: Double, end: Double, crop: CGRect) -> [Span] {
                let shown = tiles.filter { tile in
                    let point = face(of: tile).map { CGPoint(x: $0.midX, y: $0.midY) }
                        ?? CGPoint(x: tile.centerX, y: tile.centerY)
                    return crop.contains(point)
                }
                if !shown.isEmpty { return shown.map { span(tile: $0, start: start, end: end, crop: crop) } }
                let tile = tiles.max { lhs, rhs in
                    func score(_ tile: PodcastTile) -> CGFloat {
                        let hit = crop.intersection(CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h))
                        return hit.isNull ? 0 : hit.width * hit.height
                    }
                    return score(lhs) < score(rhs)
                }
                guard let tile,
                      crop.intersects(CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)) else {
                    return [Span(start: start, end: end, personKey: nil)]
                }
                return [span(tile: tile, start: start, end: end, crop: crop)]
            }
            if let path = slot.path, !path.isEmpty {
                var spans: [Span] = []
                for (index, frame) in path.enumerated() {
                    let end = index + 1 < path.count ? min(duration, path[index + 1].t) : duration
                    guard end > frame.t else { continue }
                    spans += shownSpans(start: max(0, frame.t), end: end,
                        crop: CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h))
                }
                return Area(rect: area, spans: spans)
            }
            var stillCrop = slot.window
            if stillCrop == nil, let region = slot.region {
                let tile = PodcastTile(index: -1, x: region.xFrac, y: region.yFrac,
                                       w: region.wFrac, h: region.hFrac)
                stillCrop = CropRecipePlanner.crop(tile: tile, aspect: area.width / max(1, area.height),
                                                   sourceAspect: sourceAspect, center: slot.focus)
            }
            if let crop = stillCrop {
                return Area(rect: area, spans: shownSpans(start: 0, end: duration,
                    crop: CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac)))
            }
            return Area(rect: area, spans: [])
        }
    }

    static func overlay(_ tag: NameTag, canvas: CGSize, style: TagStyle = TagStyle()) -> TextOverlayItem {
        var item = styledItem(lines: tag.lines, style: style)
        item.startTime = tag.start
        item.endTime = tag.end
        item.unbounded = false
        item.transIn = "cut"
        item.transOut = "cut"
        item.xFrac = tag.rect.midX / canvas.width
        item.yFrac = tag.rect.midY / canvas.height
        item.wFrac = tag.rect.width / canvas.width
        item.hFrac = tag.rect.height / canvas.height
        // The measured value already uses the renderer's 1920-high design space.
        item.fontsize = tag.fontSize
        return item
    }
}
