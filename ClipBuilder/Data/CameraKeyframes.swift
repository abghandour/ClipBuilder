import Foundation

/// Editing rules for a clip's custom camera path: keyframes are crop
/// rectangles (fractions of the source frame, top-left origin) at seconds
/// from the clip's source start. The crop glides between keyframes; a hard
/// cut is a repeat of the previous rectangle one hundredth of a second
/// before the next keyframe, so the renderer and the scripting op need no
/// other notion of interpolation.
nonisolated enum CameraKeyframes {
    /// The gap a hold duplicate keeps before the keyframe it cuts to.
    static let cutGap = 0.01
    /// A drag at a time this close to an existing keyframe moves that
    /// keyframe instead of adding one.
    static let mergeWindow = 0.25
    static let minimumSize = 0.05

    static func sameRect(_ a: CameraPathKeyframe, _ b: CameraPathKeyframe) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.w - b.w) < 1e-6 && abs(a.h - b.h) < 1e-6
    }

    /// The keyframe at `index` is reached by a hard cut: the keyframe before
    /// it is a hold duplicate one gap earlier that repeats its own predecessor
    /// (or, for the second keyframe, simply sits one gap earlier).
    static func isCut(_ path: [CameraPathKeyframe], at index: Int) -> Bool {
        guard index >= 1, index < path.count else { return false }
        let hold = path[index - 1]
        guard abs((path[index].t - hold.t) - cutGap) < 0.003 else { return false }
        return index == 1 || sameRect(hold, path[index - 2])
    }

    /// Indices the user sees: every keyframe except hold duplicates.
    static func visible(_ path: [CameraPathKeyframe]) -> [Int] {
        path.indices.filter { !isCut(path, at: $0 + 1) }
    }

    /// The visible keyframe nearest to `t`, when within the merge window.
    static func nearestVisible(_ path: [CameraPathKeyframe], to t: Double, within window: Double = mergeWindow) -> Int? {
        visible(path).min { abs(path[$0].t - t) < abs(path[$1].t - t) }
            .flatMap { abs(path[$0].t - t) <= window ? $0 : nil }
    }

    /// The crop at `t`: the keyframe there or the glide between neighbors.
    static func rect(_ path: [CameraPathKeyframe], at t: Double) -> CameraPathKeyframe? {
        CenterStageService.interpolated(path, at: t)
    }

    /// A rectangle clamped inside the frame at the given size.
    static func clamped(_ frame: CameraPathKeyframe) -> CameraPathKeyframe {
        var result = frame
        result.w = min(1, max(minimumSize, result.w))
        result.h = min(1, max(minimumSize, result.h))
        result.x = min(1 - result.w, max(0, result.x))
        result.y = min(1 - result.h, max(0, result.y))
        return result
    }

    /// Set the crop at `t`: the nearest visible keyframe within the window
    /// takes the rectangle, otherwise a keyframe is inserted. A hold
    /// duplicate that repeats the changed keyframe follows it.
    static func setRect(_ path: [CameraPathKeyframe], at t: Double, rect: CameraPathKeyframe) -> [CameraPathKeyframe] {
        var result = path
        let target = clamped(rect)
        if let index = nearestVisible(result, to: t) {
            // Decide about the following hold before the keyframe changes,
            // since a hold is recognized by repeating this very rectangle.
            let heldByNext = index + 2 < result.count && isCut(result, at: index + 2)
            let time = result[index].t
            result[index] = CameraPathKeyframe(t: time, x: target.x, y: target.y, w: target.w, h: target.h)
            if heldByNext {
                result[index + 1] = CameraPathKeyframe(t: result[index + 1].t, x: target.x, y: target.y, w: target.w, h: target.h)
            }
            return result
        }
        let insert = CameraPathKeyframe(t: max(0, t), x: target.x, y: target.y, w: target.w, h: target.h)
        // Never land on a hold duplicate's instant.
        if result.contains(where: { abs($0.t - insert.t) < 0.003 }) { return result }
        result.append(insert)
        result.sort { $0.t < $1.t }
        return result
    }

    /// Remove the visible keyframe at `index` with its own hold duplicate; a
    /// following cut then holds the keyframe before. Nil when fewer than two
    /// keyframes would remain, which means the path is gone.
    static func remove(_ path: [CameraPathKeyframe], at index: Int) -> [CameraPathKeyframe]? {
        guard path.indices.contains(index) else { return path }
        var result = path
        var removal = [index]
        if isCut(result, at: index) { removal.append(index - 1) }
        // The next keyframe's hold duplicate repeated this one: it now
        // repeats the previous visible keyframe.
        if index + 2 < result.count, isCut(result, at: index + 2) {
            let previous = visible(result).last { $0 < index }.map { result[$0] }
            if let previous {
                result[index + 1] = CameraPathKeyframe(t: result[index + 1].t, x: previous.x, y: previous.y, w: previous.w, h: previous.h)
            } else {
                removal.append(index + 1)
            }
        }
        for i in removal.sorted(by: >) { result.remove(at: i) }
        guard result.count >= 2 else { return nil }
        return result
    }

    /// Turn the glide into the visible keyframe at `index` into a hard cut,
    /// or back into a glide.
    static func setCut(_ path: [CameraPathKeyframe], at index: Int, cut: Bool) -> [CameraPathKeyframe] {
        guard path.indices.contains(index), index > 0 else { return path }
        var result = path
        if cut {
            guard !isCut(result, at: index) else { return result }
            let previous = result[index - 1]
            let time = result[index].t - cutGap
            guard previous.t < time - 0.003 else { return result }
            result.insert(CameraPathKeyframe(t: time, x: previous.x, y: previous.y, w: previous.w, h: previous.h), at: index)
        } else {
            guard isCut(result, at: index) else { return result }
            result.remove(at: index - 1)
        }
        return result
    }

    /// Rectangles resized to a new canvas: `ratio` is the crop's width per
    /// unit height in frame fractions (canvas aspect ÷ source aspect). The
    /// height stays, the width follows, centers hold.
    static func rescaled(_ path: [CameraPathKeyframe], to ratio: Double) -> [CameraPathKeyframe] {
        path.map { frame in
            var h = frame.h
            var w = h * ratio
            if w > 1 { w = 1; h = w / ratio }
            let cx = frame.x + frame.w / 2, cy = frame.y + frame.h / 2
            return clamped(CameraPathKeyframe(t: frame.t, x: cx - w / 2, y: cy - h / 2, w: w, h: h))
        }
    }

    /// A centered full-height crop held across the clip.
    static func seed(span: Double, ratio: Double) -> [CameraPathKeyframe] {
        var w = ratio, h = 1.0
        if w > 1 { w = 1; h = 1 / ratio }
        let x = (1 - w) / 2, y = (1 - h) / 2
        return [CameraPathKeyframe(t: 0, x: x, y: y, w: w, h: h),
                CameraPathKeyframe(t: max(0.1, span), x: x, y: y, w: w, h: h)]
    }

    /// A keyframe's place on the timeline for a clip.
    static func timelineTime(of keyframe: CameraPathKeyframe, clip: TimelineClip) -> Double {
        clip.startTime + keyframe.t / clip.effectiveSpeed
    }

    /// Seconds from the clip's source start for a timeline instant.
    static func sourceOffset(atTimeline time: Double, clip: TimelineClip) -> Double {
        max(0, min(clip.sourceSpan, (time - clip.startTime) * clip.effectiveSpeed))
    }
}
