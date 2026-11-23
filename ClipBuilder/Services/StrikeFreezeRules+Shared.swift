import Foundation

nonisolated extension StrikeFreezeRules {
    /// Pause times are on the cut's unpaused screen clock, on every track.
    /// Return indices so the caller can count rejected contacts and drawings.
    static func sharedPauseIndices(_ tracks: [[TimelineClip]], pauses: [Pause]) -> [Int] {
        let clips = tracks.flatMap { $0 }
        var kept: [Int] = []
        for (index, pause) in pauses.enumerated() {
            let range = pause.drawing == nil ? holdRange : drawingHoldRange
            guard pause.time.isFinite, pause.duration.isFinite, range.contains(pause.duration) else { continue }
            let covering = clips.filter { pause.time >= $0.startTime && pause.time < $0.startTime + $0.duration }
            guard !covering.isEmpty, covering.allSatisfy({ clip in
                let previous = kept.last.map { pauses[$0].time } ?? clip.startTime
                return pause.time - max(clip.startTime, previous) >= minimumPiece - 1e-9
                    && clip.startTime + clip.duration - pause.time >= minimumPiece - 1e-9
            }) else { continue }
            kept.append(index)
        }
        return kept
    }

    /// Split all pictures atomically. Gaps stay gaps; only later clips move.
    /// Reuse the single-source splitter for its source and camera-path math.
    static func sharedPieces(_ tracks: [[TimelineClip]], pauses: [Pause]) -> [[TimelineClip]]? {
        let selected = sharedPauseIndices(tracks, pauses: pauses).map { pauses[$0] }
        guard !selected.isEmpty else { return nil }
        let mainSource = tracks.flatMap { $0 }.first { $0.track == 0 }?.videoFile
        var result: [[TimelineClip]] = []
        for track in tracks {
            var output: [TimelineClip] = []
            for clip in track {
                let covering = selected.filter { $0.time >= clip.startTime && $0.time < clip.startTime + clip.duration }
                let shift = selected.filter { $0.time < clip.startTime }.reduce(0) { $0 + $1.duration }
                if covering.isEmpty {
                    var moved = clip
                    moved.startTime += shift
                    moved.strikeImpactsFrozen = true
                    output.append(moved)
                    continue
                }
                guard let start = clip.sourceStart else { return nil }
                let sourcePauses = covering.map { pause in
                    Pause(time: start + (pause.time - clip.startTime) * clip.effectiveSpeed,
                          duration: pause.duration, drawing: pause.drawing, source: pause.source)
                }
                var split = pieces(clip, pauses: sourcePauses)
                guard !split.isEmpty else { return nil }
                var holdIndex = 0
                for index in split.indices {
                    split[index].startTime += shift
                    if split[index].hold == true {
                        let pause = sourcePauses[holdIndex]
                        if let drawing = pause.drawing,
                           clip.videoFile != (pause.source ?? mainSource) || abs(pause.time - drawing.time) > 1.0 / 30 + 1e-9 {
                            split[index].telestration = nil
                        }
                        holdIndex += 1
                    }
                }
                output += split
            }
            result.append(output)
        }
        return result
    }
}
