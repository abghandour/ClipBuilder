import Foundation

nonisolated enum BRollCutMapping {
    static func qualifies(video: VideoRecord, scenes: [SceneRecord]) -> Bool {
        video.type == .podcast || video.type == .interview
            || scenes.contains { $0.videoID == video.id && $0.tags.contains("podcast-exchange") }
    }

    /// Advancing the left edge advances the footage too, keeping picture on its words.
    static func trimmed(_ cuts: [BRollCut], to range: ClosedRange<Double>) -> [BRollCut] {
        cuts.compactMap { cut in
            guard cut.start.isFinite, cut.end.isFinite, cut.sceneOffset.isFinite else { return nil }
            let start = max(cut.start, range.lowerBound), end = min(cut.end, range.upperBound)
            guard end > start else { return nil }
            var result = cut
            result.sceneOffset += start - cut.start
            result.start = start
            result.end = end
            return result
        }
    }

    /// Whole exchanges and subcuts use the same source-clock translation.
    static func planned(_ cuts: [BRollCut], candidate: HighlightCandidate,
                        scenes: [SceneRecord]) -> [PodcastHighlightBRollPlanner.Cut] {
        trimmed(cuts, to: candidate.sourceRange).compactMap { cut in
            guard let scene = scenes.first(where: { $0.id == cut.sceneID }),
                  cut.sceneOffset >= 0 else { return nil }
            let duration = min(cut.end - cut.start, scene.duration - cut.sceneOffset)
            guard duration > 0 else { return nil }
            return .init(source: .scene(cut.sceneID), sourceStart: scene.startTime + cut.sceneOffset,
                start: cut.start - candidate.sourceStart, duration: duration, reason: cut.reason)
        }
    }

    /// Camera-layout pieces share a clip origin. Reassemble their source span
    /// without joining separate kept pieces.
    static func sourceSpans(_ clips: [TimelineClip]) -> [TimelineClip] {
        var result: [TimelineClip] = []
        for clip in clips.sorted(by: { $0.startTime < $1.startTime }) {
            if let index = result.firstIndex(where: {
                $0.originKey == clip.originKey && $0.sceneID == clip.sceneID
                    && abs($0.startTime + $0.duration - clip.startTime) < 1e-6
                    && abs(($0.sourceEnd ?? 0) - (clip.sourceStart ?? 0)) < 1e-6
            }) {
                result[index].duration += clip.duration
                result[index].sourceEnd = clip.sourceEnd
            } else {
                result.append(clip)
            }
        }
        return result
    }

    /// No snapping, padding, reaction tiles or automatic fill. The source audio
    /// stays on its main clip; these placements only replace the picture.
    static func timelineClips(_ cuts: [BRollCut], sourceRange: ClosedRange<Double>,
                              scenes: [SceneRecord], reelStart: Double = 0) -> [TimelineClip] {
        let sceneMap = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return trimmed(cuts, to: sourceRange).compactMap { cut in
            guard let scene = sceneMap[cut.sceneID], cut.sceneOffset >= 0 else { return nil }
            let duration = min(cut.end - cut.start, scene.duration - cut.sceneOffset)
            guard duration.isFinite, duration > 0 else { return nil }
            var clip = TimelineClip()
            clip.sceneID = scene.id
            clip.videoFile = scene.videoPath
            clip.sourceStart = scene.startTime + cut.sceneOffset
            clip.sourceEnd = scene.startTime + cut.sceneOffset + duration
            clip.startTime = reelStart + cut.start - sourceRange.lowerBound
            clip.duration = duration
            clip.role = .cutaway
            clip.coverAllAreas = true
            clip.cutawayAudio = .muted
            clip.muted = true
            clip.captions = "none"
            clip.precision = .speech
            clip.transIn = "cut"
            clip.transOut = "cut"
            return clip
        }
    }
}
