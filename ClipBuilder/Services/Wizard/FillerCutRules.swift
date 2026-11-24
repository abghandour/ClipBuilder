import Foundation

/// Source-clock cuts shared by Express and the full Wizard. No transcript or
/// saved selection is edited; only the render plan and its captions change.
nonisolated enum FillerCutRules {
    struct Result: Sendable {
        var plan: WizardPlan
        var cutsApplied: Int
        var secondsRemoved: Double
        /// Original clip index for each output piece, also used for rough joins.
        var origins: [Int]

        func expandingTransitions(_ transitions: [String]) -> [String] {
            origins.indices.dropFirst().map { index in
                origins[index] == origins[index - 1] || plan.clips[index].continuesPrevious == true
                    ? "cut" : (transitions[safe: origins[index - 1]] ?? "cut")
            }
        }
    }

    static func spans(rows: [TranscriptRow]) -> [ClosedRange<Double>] {
        let spoken = rows.filter { !$0.isTranslation }.map { (id: $0.id, words: $0.words ?? []) }
        return merged(TranscriptCleanupProposer.propose(rows: rows).compactMap { proposal in
            guard proposal.kind == .filler || proposal.kind == .repeatWord else { return nil }
            // People talk over each other: a cut that would clip a word that stays
            // (someone else's, in another row) is not made.
            let clipsKeptWord = spoken.contains { row in
                row.words.enumerated().contains { index, word in
                    !(row.id == proposal.rowID && proposal.wordRange.contains(index))
                        && word.start < proposal.endTime - 0.01 && word.end > proposal.startTime + 0.01
                }
            }
            return clipsKeptWord ? nil : proposal.startTime...proposal.endTime
        })
    }

    static func split(_ plan: WizardPlan, spans: [Int64: [ClosedRange<Double>]],
                      sceneVideo: [Int64: Int64]) -> Result {
        var result = Result(plan: plan, cutsApplied: 0, secondsRemoved: 0, origins: [])
        result.plan.clips = []
        var applied = plan.appliedFillerSpans ?? [:]
        let candidates = spans.mapValues(merged)
        for (index, clip) in plan.clips.enumerated() {
            guard clip.speed == 1, !clip.replay, clip.areaClips.isEmpty, clip.layout == nil,
                  clip.start.isFinite, clip.end.isFinite, clip.end > clip.start,
                  let videoID = sceneVideo[clip.sceneID], let ranges = candidates[videoID] else {
                result.plan.clips.append(clip)
                result.origins.append(index)
                continue
            }
            var pieces = [clip.start...clip.end]
            var cuts: [ClosedRange<Double>] = []
            for range in ranges {
                guard let pieceIndex = pieces.firstIndex(where: {
                    range.lowerBound < $0.upperBound && range.upperBound > $0.lowerBound
                }) else { continue }
                let piece = pieces[pieceIndex]
                let start = max(piece.lowerBound, range.lowerBound)
                let end = min(piece.upperBound, range.upperBound)
                let left = start - piece.lowerBound, right = piece.upperBound - end
                // Zero is an edge trim; a short nonempty piece is real speech
                // we cannot discard. Never erase the entire clip either.
                guard (left == 0 || left >= 0.5), (right == 0 || right >= 0.5),
                      left + right >= 0.5 else { continue }
                var kept: [ClosedRange<Double>] = []
                if left > 0 { kept.append(piece.lowerBound...start) }
                if right > 0 { kept.append(end...piece.upperBound) }
                pieces.replaceSubrange(pieceIndex...pieceIndex, with: kept)
                cuts.append(start...end)
                result.cutsApplied += 1
                result.secondsRemoved += end - start
            }
            guard !cuts.isEmpty else {
                result.plan.clips.append(clip)
                result.origins.append(index)
                continue
            }
            applied[videoID] = merged((applied[videoID] ?? []) + cuts)
            for (pieceIndex, range) in pieces.enumerated() {
                var piece = clip
                piece.start = range.lowerBound
                piece.end = range.upperBound
                piece.brollCuts = clip.brollCuts.map { broll($0, in: range) }
                if pieceIndex == 0 {
                    let shift = piece.start - clip.start
                    piece.speakerIntroductions = clip.speakerIntroductions.compactMap { introduction in
                        var item = introduction
                        item.startTime = max(0, item.startTime - shift)
                        item.endTime = min(piece.end - piece.start, item.endTime - shift)
                        return item.endTime > item.startTime ? item : nil
                    }
                } else {
                    piece.textOverlay = nil
                    piece.overlayKicker = nil
                    piece.speakerIntroductions = []
                    piece.continuesPrevious = true
                }
                result.plan.clips.append(piece)
                result.origins.append(index)
            }
        }
        result.plan.appliedFillerSpans = applied.isEmpty ? plan.appliedFillerSpans : applied
        if result.cutsApplied > 0 || plan.clips.contains(where: { $0.continuesPrevious == true }) {
            result.plan.transitions = result.expandingTransitions(plan.transitions)
        }
        return result
    }

    /// B-roll over a piece. A cutaway that crosses a filler cut stays over both sides,
    /// each part showing the B-roll footage it showed before; nobody trimmed it, so the
    /// "a trim invalidates the cutaway" rule of `MiniBRollRules.retained` does not apply.
    static func broll(_ cuts: [BRollCut], in range: ClosedRange<Double>, minimum: Double = 0.5) -> [BRollCut] {
        cuts.compactMap { cut -> BRollCut? in
            guard cut.start.isFinite, cut.end.isFinite, cut.end > cut.start else { return nil }
            let start = max(cut.start, range.lowerBound), end = min(cut.end, range.upperBound)
            guard end - start >= min(minimum, cut.end - cut.start) else { return nil }
            guard start != cut.start || end != cut.end else { return cut }
            var part = cut
            part.id = UUID()
            part.start = start
            part.end = end
            part.sceneOffset = cut.sceneOffset + (start - cut.start)
            return part
        }.sorted { $0.start < $1.start }
    }

    /// The applied cuts that a clip playing `range` actually skips. A span inside the
    /// range is footage this clip plays (a slow-motion or replayed occurrence that was
    /// not cut), so its captions keep those words.
    static func skipped(_ spans: [ClosedRange<Double>], playing range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        spans.filter { !($0.lowerBound > range.lowerBound + 0.01 && $0.upperBound < range.upperBound - 0.01) }
    }

    /// One applied cut on the reel's clock, for the scrubber.
    struct Marker: Equatable, Sendable {
        /// Where the join lands in the finished reel.
        var time: Double
        /// Source seconds taken out at it.
        var removed: Double
    }

    /// Footage on screen, in output order: its recording, the source range it plays and where it starts in the reel.
    struct ShownPiece: Equatable, Sendable {
        var videoID: Int64
        var sourceStart: Double
        var sourceEnd: Double
        var output: Double
    }

    /// A marker wherever two neighbouring pieces of one recording skip exactly an applied
    /// span. Two picks that merely have a filler in the footage between them get none.
    static func markers(pieces: [ShownPiece], spans: [Int64: [ClosedRange<Double>]], tolerance: Double = 0.1) -> [Marker] {
        zip(pieces, pieces.dropFirst()).compactMap { before, after in
            guard before.videoID == after.videoID, after.sourceStart - before.sourceEnd > 0.01,
                  spans[after.videoID]?.contains(where: {
                      abs($0.lowerBound - before.sourceEnd) <= tolerance && abs($0.upperBound - after.sourceStart) <= tolerance
                  }) == true else { return nil }
            return Marker(time: after.output, removed: after.sourceStart - before.sourceEnd)
        }
    }

    /// "3 fillers cut (−4.7 s)"; nil without cuts.
    static func summary(_ markers: [Marker]) -> String? {
        guard !markers.isEmpty else { return nil }
        return String(format: "%d %@ cut (−%.1f s)", markers.count, markers.count == 1 ? "filler" : "fillers",
                      markers.reduce(0) { $0 + $1.removed })
    }

    /// Hard cuts at the joins of a plan that was already cut.
    static func cutJoins(_ transitions: [String], clips: [WizardPlanClip]) -> [String] {
        var result = transitions
        for index in clips.indices.dropFirst() where clips[index].continuesPrevious == true && index - 1 < result.count {
            result[index - 1] = "cut"
        }
        return result
    }

    /// Keep the full segment clock: pages can straddle the source gap, and
    /// each retained word still appears at its original source second.
    static func captions(_ segments: [TranscriptSegment], removing spans: [ClosedRange<Double>]) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return segments }
        return segments.compactMap { segment in
            guard let words = segment.words, !words.isEmpty else { return segment }
            let kept = words.filter { word in
                let middle = word.start + (word.end - word.start) / 2
                return !spans.contains { $0.contains(middle) }
            }
            guard !kept.isEmpty else { return nil }
            guard kept.count != words.count else { return segment }
            var result = segment
            result.words = kept
            result.text = kept.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            return result
        }
    }

    private static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for span in spans.filter({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, span.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else { result.append(span) }
        }
        return result
    }
}
