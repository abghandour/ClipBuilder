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
    }
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
        var content: String? = nil
        var position: String? = nil
        var safeRect: CGRect? = nil
        var captionBand: CGRect? = nil
        var canvas: CGSize = CGSize(width: 1080, height: 1920)
    }

    static func plan(areas: [Area], people: [Person], settings: Settings,
                     template: TextOverlayItem? = nil) -> [NameTag] {
        let names = Dictionary(people.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let explicitCorner = Corner(rawValue: settings.position ?? "")
        let frame = CGRect(origin: .zero, size: settings.canvas)
        let renderer = TextOverlayRenderer(videoWidth: Int(settings.canvas.width),
                                           videoHeight: Int(settings.canvas.height), safeArea: nil)
        return areas.flatMap { area -> [NameTag] in
            let inset = min(area.rect.width, area.rect.height) * 0.04
            var allowed = area.rect.insetBy(dx: inset, dy: inset)
            if explicitCorner == nil, let safe = settings.safeRect {
                allowed = allowed.intersection(safe)
                if allowed.isNull || allowed.isEmpty { allowed = safe.intersection(frame) }
            }
            guard !allowed.isNull, allowed.width > 0, allowed.height > 0 else { return [] }
            var tags: [NameTag] = []
            for span in area.spans.sorted(by: { $0.start < $1.start }) {
                guard span.end > span.start, let key = span.personKey, let person = names[key] else { continue }
                let name = person.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let role = person.role.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !name.isEmpty else { continue }
                let lines = settings.content == "nameAndRole" && !role.isEmpty ? [name, role] : [name]
                var item = styledItem(lines: lines, template: template)
                let scale = settings.canvas.height / 1920
                item.fontsize = Int(min(64, max(30, min(area.rect.width, area.rect.height) * 0.075 / scale)))
                let layout = renderer.nameTagLayout(item, maxWidth: min(area.rect.width * 0.6, allowed.width))
                let width = layout.size.width
                let height = layout.size.height
                func rect(_ corner: Corner) -> CGRect {
                    let y = corner == .bottomLeading || corner == .bottomTrailing ? allowed.maxY - height : allowed.minY
                    let verticalBounds = height <= allowed.height ? allowed
                        : (explicitCorner == nil ? settings.safeRect?.intersection(frame) ?? frame : frame)
                    return CGRect(x: corner == .topTrailing || corner == .bottomTrailing ? allowed.maxX - width : allowed.minX,
                                  y: max(verticalBounds.minY, min(y, verticalBounds.maxY - height)),
                                  width: width, height: height)
                }
                let face = span.faceBox.map { $0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15) }
                func overlap(_ box: CGRect) -> CGFloat {
                    [face, settings.captionBand].compactMap { $0 }.reduce(0) { total, obstacle in
                        let hit = box.intersection(obstacle)
                        return total + (hit.isNull ? 0 : hit.width * hit.height)
                    }
                }
                let corner = explicitCorner ?? Corner.allCases.enumerated().min {
                    let a = overlap(rect($0.element)), b = overlap(rect($1.element))
                    return a == b ? $0.offset < $1.offset : a < b
                }!.element
                guard let placed = clearingCaption(rect(corner), corner: corner, area: area.rect,
                    allowed: allowed, frame: frame, safe: explicitCorner == nil ? settings.safeRect : nil,
                    band: settings.captionBand, gap: settings.canvas.height * 0.01) else { continue }
                let tag = NameTag(personKey: key, lines: lines, areaRect: area.rect, rect: placed,
                                  corner: corner, fontSize: layout.fontSize, start: span.start, end: span.end)
                if let last = tags.last, last.personKey == key, last.lines == tag.lines,
                   last.rect == tag.rect, abs(last.end - tag.start) < 0.00001 {
                    tags[tags.count - 1].end = tag.end
                } else { tags.append(tag) }
            }
            return tags
        }
    }

    /// Prefer the requested side within the area. If the band consumes the
    /// whole cell, use the nearest adjacent free strip of the frame instead.
    private static func clearingCaption(_ rect: CGRect, corner: Corner, area: CGRect,
                                        allowed: CGRect, frame: CGRect, safe: CGRect?,
                                        band: CGRect?, gap: CGFloat) -> CGRect? {
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
        for bounds in [allowed, areaBounds, frameBounds, frame] where !bounds.isNull && !bounds.isEmpty {
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

    private static func styledItem(lines: [String], template: TextOverlayItem?) -> TextOverlayItem {
        var item = template ?? LowerThirdOverlay.composition(name: lines[0], role: "").texts[0]
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
            func span(start: Double, end: Double, crop: CGRect) -> Span {
                // Crops sit within feed cells. Choose by overlap before looking
                // up identity, so an unnamed feed never inherits another name.
                let tile = tiles.max { lhs, rhs in
                    func score(_ tile: PodcastTile) -> CGFloat {
                        let hit = crop.intersection(CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h))
                        return hit.isNull ? 0 : hit.width * hit.height
                    }
                    return score(lhs) < score(rhs)
                }
                guard let tile,
                      crop.intersects(CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)) else {
                    return Span(start: start, end: end, personKey: nil)
                }
                var face: CGRect?
                if let box = roster.first(where: { $0.key == tile.personKey })?.portraitBox {
                    face = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
                } else if let center = tile.faceCenter {
                    face = CGRect(x: center.x - tile.w * 0.10, y: center.y - tile.h * 0.10,
                                  width: tile.w * 0.20, height: tile.h * 0.20)
                }
                let projected = face.map { box in
                    CGRect(x: area.minX + (box.minX - crop.minX) / max(0.001, crop.width) * area.width,
                           y: area.minY + (box.minY - crop.minY) / max(0.001, crop.height) * area.height,
                           width: box.width / max(0.001, crop.width) * area.width,
                           height: box.height / max(0.001, crop.height) * area.height)
                }
                return Span(start: start, end: end, personKey: tile.personKey, faceBox: projected)
            }
            if let path = slot.path, !path.isEmpty {
                var spans: [Span] = []
                for (index, frame) in path.enumerated() {
                    let end = index + 1 < path.count ? min(duration, path[index + 1].t) : duration
                    guard end > frame.t else { continue }
                    spans.append(span(start: max(0, frame.t), end: end,
                        crop: CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)))
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
                return Area(rect: area, spans: [span(start: 0, end: duration,
                    crop: CGRect(x: crop.xFrac, y: crop.yFrac, width: crop.wFrac, height: crop.hFrac))])
            }
            return Area(rect: area, spans: [])
        }
    }

    static func overlay(_ tag: NameTag, canvas: CGSize, template: TextOverlayItem? = nil) -> TextOverlayItem {
        var item = styledItem(lines: tag.lines, template: template)
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
