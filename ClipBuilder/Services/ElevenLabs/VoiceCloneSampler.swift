import Foundation

/// Pure selection: no database, media work, or network calls.
nonisolated enum VoiceCloneSampler {
    struct Sample: Sendable, Equatable {
        let videoID: Int64
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    struct Selection: Sendable, Equatable {
        let ranges: [Sample]
        let reason: String?
        var seconds: Double { ranges.reduce(0) { $0 + $1.duration } }
    }

    private struct Candidate {
        let sample: Sample
        let rowEnds: [Double]
    }

    static func select(personKey: String, name: String, turns: [SpeakerTurn],
                       transcripts: [TranscriptRow]) -> Selection {
        let rowsByVideo = Dictionary(grouping: transcripts.filter {
            !$0.isTranslation && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime
                && ($0.speakerKey == nil || $0.speakerKey == personKey)
        }, by: \.videoID)
        let turnsByVideo = Dictionary(grouping: turns.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > max(0, $0.start)
        }, by: \.videoID)
        var candidates: [Int64: [Candidate]] = [:]
        for (videoID, videoTurns) in turnsByVideo {
            let rows = (rowsByVideo[videoID] ?? []).sorted { $0.startTime < $1.startTime }
            let others = videoTurns.filter { $0.personKey != personKey }
            var accepted: [Sample] = []
            let own = videoTurns.filter {
                $0.personKey == personKey && $0.confidence >= 0.6 && $0.end - $0.start >= 3
            }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            for turn in own {
                var clean = [max(0, turn.start)..<turn.end]
                // Unknown speakers also block the sample: they are not proven
                // to be this person. Already selected audio must not count twice.
                let blocked = others.map { ($0.start - 0.3)..<($0.end + 0.3) }
                    + accepted.map { $0.start..<$0.end }
                for block in blocked {
                    clean = clean.flatMap { range -> [Range<Double>] in
                        guard range.overlaps(block) else { return [range] }
                        var pieces: [Range<Double>] = []
                        if range.lowerBound < block.lowerBound {
                            pieces.append(range.lowerBound..<min(range.upperBound, block.lowerBound))
                        }
                        if range.upperBound > block.upperBound {
                            pieces.append(max(range.lowerBound, block.upperBound)..<range.upperBound)
                        }
                        return pieces
                    }
                }
                for range in clean {
                    let complete = rows.filter {
                        $0.startTime >= range.lowerBound && $0.endTime <= range.upperBound
                    }
                    guard let first = complete.first, let end = complete.map(\.endTime).max(),
                          end - first.startTime >= 3 else { continue }
                    let sample = Sample(videoID: videoID, start: first.startTime, end: end)
                    accepted.append(sample)
                    candidates[videoID, default: []].append(Candidate(sample: sample,
                        rowEnds: complete.map(\.endTime).sorted()))
                }
            }
        }
        for id in candidates.keys {
            candidates[id]?.removeAll { candidate in
                !candidate.rowEnds.contains { end in
                    end - candidate.sample.start >= 3 && end - candidate.sample.start <= 120
                }
            }
            candidates[id]?.sort {
                if $0.sample.duration != $1.sample.duration { return $0.sample.duration > $1.sample.duration }
                return $0.sample.start < $1.sample.start
            }
        }
        // Round-robin across videos, longest available turn first in each
        // round. Only whole transcript rows may fill the remaining budget.
        var selected: [Sample] = []
        var seconds = 0.0
        while candidates.values.contains(where: { !$0.isEmpty }), seconds < 120 {
            let videoIDs = candidates.keys.filter { candidates[$0]?.isEmpty == false }.sorted {
                let lhs = candidates[$0]?.first?.sample.duration ?? 0
                let rhs = candidates[$1]?.first?.sample.duration ?? 0
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }
            for (index, id) in videoIDs.enumerated() {
                guard let candidate = candidates[id]?.removeFirst() else { continue }
                let sample = candidate.sample
                // Reserve one complete row span for the remaining videos so
                // a single long interview cannot consume the entire sample.
                let reserved = videoIDs.dropFirst(index + 1).compactMap { otherID -> Double? in
                    guard !selected.contains(where: { $0.videoID == otherID }),
                          let next = candidates[otherID]?.first,
                          let end = next.rowEnds.first(where: { $0 - next.sample.start >= 3 }) else { return nil }
                    return end - next.sample.start
                }.reduce(0, +)
                let budgetEnd = sample.start + max(0, 120 - seconds - reserved)
                guard let end = candidate.rowEnds.last(where: { $0 <= budgetEnd }),
                      end - sample.start >= 3 else { continue }
                let trimmed = Sample(videoID: id, start: sample.start, end: end)
                selected.append(trimmed)
                seconds += trimmed.duration
            }
        }
        let reason = seconds < 30
            ? "Only \(Int(seconds.rounded(.down))) s of \(name) alone; analyze more of their footage or pick a voice."
            : nil
        return Selection(ranges: selected, reason: reason)
    }
}
