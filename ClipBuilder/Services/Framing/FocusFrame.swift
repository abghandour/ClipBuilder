import CoreGraphics
import Foundation

/// Focus frames are always stored in oriented, uncropped source fractions.
nonisolated enum FocusFrame {
    static let nobodyInside = "Nobody inside the focus frame"

    static func rect(_ frame: FreeCropRect) -> CGRect {
        CGRect(x: frame.xFrac, y: frame.yFrac, width: frame.wFrac, height: frame.hFrac)
    }

    static func window(_ rect: CGRect) -> FreeCropRect {
        FreeCropRect(xFrac: rect.minX, yFrac: rect.minY, wFrac: rect.width, hFrac: rect.height)
    }

    /// The one conversion to a stream after baked bars are removed. An empty
    /// intersection falls back to the remaining content, never to an invalid crop.
    static func resolved(_ frame: FreeCropRect, contentBox: RenderEngine.ContentBox? = nil) -> FreeCropRect {
        let values = [frame.xFrac, frame.yFrac, frame.wFrac, frame.hFrac]
        let finite = values.allSatisfy(\.isFinite)
        let requested = finite ? rect(frame) : CGRect(x: 0, y: 0, width: 1, height: 1)
        if contentBox == nil, finite, requested.minX >= 0, requested.minY >= 0,
           requested.maxX <= 1, requested.maxY <= 1, requested.width > 0, requested.height > 0 { return frame }
        let content = contentBox.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let intersection = requested.intersection(content)
        guard content.width > 0, content.height > 0, !intersection.isNull,
              intersection.width > 0, intersection.height > 0 else { return FreeCropRect() }
        return window(CGRect(x: (intersection.minX - content.minX) / content.width,
            y: (intersection.minY - content.minY) / content.height,
            width: intersection.width / content.width, height: intersection.height / content.height))
    }

    /// The same resolved window when the consumer still decodes the original file
    /// (tracking, the fused compositor and preview). Source clocks are unchanged.
    static func sourceWindow(_ frame: FreeCropRect, contentBox: RenderEngine.ContentBox? = nil) -> FreeCropRect {
        let local = resolved(frame, contentBox: contentBox)
        guard let box = contentBox else { return local }
        return FreeCropRect(xFrac: box.x + local.xFrac * box.w, yFrac: box.y + local.yFrac * box.h,
            wFrac: local.wFrac * box.w, hFrac: local.hFrac * box.h)
    }

    static func clipped(_ plan: FramingPlan, contentBox: RenderEngine.ContentBox?) -> FramingPlan {
        switch plan {
        case .static(let window?, let fit, let feather, let blur):
            return .static(window: sourceWindow(window, contentBox: contentBox), fit: fit, feather: feather, blur: blur)
        case .tracked(let recipe, let region?, let fit, let feather, let blur):
            return .tracked(recipe, region: sourceWindow(region, contentBox: contentBox), fit: fit, feather: feather, blur: blur)
        default: return plan
        }
    }

    static func handleAspectLocked(framing: Framing) -> Bool {
        framing.subject == .original && !(framing.fit == .blurredFill && framing.lockAspect == false)
    }

    static func initial(framing: Framing, sourceSize: CGSize, canvasAspect: Double) -> FreeCropRect {
        guard handleAspectLocked(framing: framing) else { return FreeCropRect() }
        return AreaFramer.fallbackWindow(aspect: canvasAspect, sourceSize: sourceSize, center: nil)
    }

    static func contains(_ frame: FreeCropRect, x: Double, y: Double) -> Bool {
        let box = rect(resolved(frame))
        return x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY
    }

    static func filtered(_ context: FramingContext, frame: FreeCropRect) -> FramingContext {
        var result = context
        result.roster = context.roster.filter { person in
            guard let box = person.portraitBox else { return false }
            return contains(frame, x: box.x + box.w / 2, y: box.y + box.h / 2)
        }
        let keys = Set(result.roster.map(\.key))
        result.feeds = context.feeds.filter { tile in
            if let key = tile.personKey, context.roster.contains(where: { $0.key == key }), !keys.contains(key) { return false }
            let picture = tile.picture
            return contains(frame, x: picture.centerX, y: picture.centerY)
        }.map { tile in
            var tile = tile.picture
            let visible = rect(FreeCropRect(xFrac: tile.x, yFrac: tile.y, wFrac: tile.w, hFrac: tile.h)).intersection(rect(frame))
            tile.x = visible.minX; tile.y = visible.minY; tile.w = visible.width; tile.h = visible.height
            tile.pictureX = nil; tile.pictureY = nil; tile.pictureW = nil; tile.pictureH = nil
            return tile
        }
        let indices = Set(result.feeds.map(\.index))
        result.turns = context.turns.filter { turn in
            if let key = turn.personKey { return keys.contains(key) }
            if let index = CropRecipePlanner.tile(for: turn, tiles: context.feeds) { return indices.contains(index) }
            return false
        }
        result.storedPath = nil
        return result
    }

    /// Fit a newly planned shot inside the bounds without changing its aspect.
    /// This is applied after selecting only in-frame subjects, never to a stored scene path.
    static func fitting(_ shot: FreeCropRect, inside frame: FreeCropRect) -> FreeCropRect {
        let factor = min(1, min(frame.wFrac / max(0.0001, shot.wFrac), frame.hFrac / max(0.0001, shot.hFrac)))
        let width = shot.wFrac * factor, height = shot.hFrac * factor
        return FreeCropRect(xFrac: min(frame.xFrac + frame.wFrac - width, max(frame.xFrac, shot.xFrac)),
            yFrac: min(frame.yFrac + frame.hFrac - height, max(frame.yFrac, shot.yFrac)), wFrac: width, hFrac: height)
    }

    /// Recipe paths are created from filtered evidence and stamped with their
    /// bounds. A new frame invalidates that stamp; scene paths never have it.
    static func hasReplannedPath(_ clip: TimelineClip) -> Bool {
        guard let plan = clip.framingPlan, !plan.isStatic, plan.recipe?.centerStage != true,
              let frame = plan.sourceWindow, clip.areaRegion == frame, let path = clip.cameraPath, !path.isEmpty else { return false }
        return path.allSatisfy { key in
            key.x >= frame.xFrac - 1e-9 && key.y >= frame.yFrac - 1e-9
                && key.x + key.w <= frame.xFrac + frame.wFrac + 1e-9
                && key.y + key.h <= frame.yFrac + frame.hFrac + 1e-9
        }
    }

    /// Install source geometry on a timeline clip without reusing an unbounded
    /// explicit path. Free crops work even when there is no Screen/layout row.
    static func apply(_ plan: FramingPlan, to clip: inout TimelineClip, replanned: Bool = false) {
        switch plan {
        case .static(let window?, _, _, _):
            clip.freeCrops = [FreeCrop(src: resolved(window), dst: FreeCropRect())]
            clip.areaWindow = nil; clip.areaRegion = nil; clip.areaFocus = nil
            clip.cameraPath = nil; clip.centerStage = false; clip.cropXFrac = nil
        case .tracked(_, let region?, _, _, _):
            let keepPath = replanned || hasReplannedPath(clip)
            clip.areaRegion = keepPath && clip.cameraPath != nil ? region : FitSpec.intersection(clip.areaRegion ?? region, region)
            clip.areaWindow = nil; clip.freeCrops = nil
            if !keepPath { clip.cameraPath = nil }
            else if clip.cameraPath != nil { clip.areaFocus = nil }
            clip.centerStage = true
            if let focus = clip.areaFocus, !contains(region, x: focus.x, y: focus.y) { clip.areaFocus = nil }
        default: break
        }
    }
}
