import Foundation

nonisolated enum StrikeStatSourceBinding {
    /// One instance per matching clip, including repeats. Duration is source time
    /// and stretches with playback speed, clipped at the trim boundary.
    static func mapped(_ item: TextOverlayItem, clips: [TimelineClip], scenes: [SceneRecord], videos: [VideoRecord]) -> [TextOverlayItem] {
        guard let stat = item.stat else { return [item] }
        guard let videoID = stat.sourceVideoID, let time = stat.sourceTime else { return [] }
        return clips.compactMap { clip in
            let scene = scenes.first { $0.id == clip.sceneID }
            let id = scene?.videoID ?? videos.first { $0.path == clip.videoFile }?.id
            guard id == videoID, !clip.bumper else { return nil }
            let start = clip.sourceStart ?? scene?.startTime ?? 0
            let speed = max(0.01, clip.effectiveSpeed)
            let end = min(clip.sourceEnd ?? (start + clip.sourceSpan), start + clip.sourceSpan)
            guard time >= start, time < end else { return nil }
            var mapped = item
            mapped.startTime = clip.startTime + (time - start) / speed
            mapped.endTime = min(clip.startTime + clip.duration, mapped.startTime + item.duration / speed)
            return mapped
        }
    }

    static func detachAfterTextEdit(_ item: inout TextOverlayItem, previous: TextOverlayItem) {
        guard previous.stat != nil, item.text != previous.text else { return }
        item.stat = nil
        item.design = "tag"
        item.kicker = nil
        item.text = item.text.replacingOccurrences(of: StrikeStatsCopy.badge, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
