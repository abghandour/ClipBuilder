import Foundation

/// Who is talking when, for any number of people: voice clusters from the
/// audio and mouth motion per face slot from the picture, combined on a
/// fine time grid and smoothed so the speaker only changes when the
/// evidence does. Slots are the layout's tiles; voices map onto slots by
/// how their speech lines up with mouth motion over the whole recording.
nonisolated enum SpeakerTracker {
    struct Input: Sendable {
        var audioWindows: [SpeakerFeatures.Window]
        var activity: VisualSpeechActivity.Activity
        var speech: [ClosedRange<Double>]
        var tiles: [PodcastTile]
        var duration: Double
    }

    struct Bin: Sendable, Equatable {
        var start: Double
        var speech: Bool
        /// Voice posterior per cluster.
        var voices: [Double]
        /// Mouth-motion share per slot.
        var mouths: [Double]
    }

    struct Outcome: Sendable {
        var turns: [SpeakerTurn]
        var clusterSlots: [Int: Int]
        var clusterCount: Int
        /// Mean margin between the chosen slot and the runner-up over speech.
        var margin: Double
        /// Diagnostics: the fused grid and the voice-to-slot affinities.
        var bins: [Bin] = []
        var affinity: [[Double]] = []
    }

    static let visualWeight = 0.55
    static let audioWeight = 0.45
    /// A highlighted tile outranks mouths and voices together.
    static let highlightWeight = 2.0
    static let switchPenalty = 0.30
    static let minimumTurn = 0.4

    static func track(_ input: Input, videoID: Int64) -> Outcome {
        let tiles = input.tiles.sorted { $0.index < $1.index }
        let slots = tiles.count
        guard slots >= 1 else { return Outcome(turns: [], clusterSlots: [:], clusterCount: 0, margin: 0) }
        let binSeconds = input.activity.binSeconds
        let binCount = Int((input.duration / binSeconds).rounded(.up))
        // Voices: as many as the picture shows people, but at least what the
        // audio separates on its own.
        let clustering = SpeakerClustering.cluster(input.audioWindows.map(\.vector), minimum: min(2, slots),
                                                   maximum: max(2, slots))
        let clusterCount = clustering.centroids.count
        // Per-slot motion normalized by that slot's own typical level, so a
        // lively face does not drown a calm one.
        let baselines = tiles.indices.map { slot -> Double in
            let values = input.activity.motion[safe: slot]?.filter { $0 > 0 }.sorted() ?? []
            return values.isEmpty ? 1 : max(1e-6, values[values.count / 2])
        }
        var bins: [Bin] = []
        for b in 0..<binCount {
            let start = Double(b) * binSeconds
            let mid = start + binSeconds / 2
            let speech = input.speech.contains { $0.contains(mid) }
            var voices = [Double](repeating: 0, count: max(1, clusterCount))
            if clusterCount > 0 {
                let covering = input.audioWindows.indices.filter { input.audioWindows[$0].start <= mid && mid < input.audioWindows[$0].end }
                for i in covering {
                    let p = SpeakerClustering.posterior(clustering.vectors[i], centroids: clustering.centroids)
                    for c in p.indices { voices[c] += p[c] / Double(covering.count) }
                }
            }
            let raw = tiles.indices.map { slot in (input.activity.motion[safe: slot]?[safe: b] ?? 0) / baselines[slot] }
            let total = raw.reduce(0, +)
            let mouths = total > 1e-9 ? raw.map { $0 / total } : [Double](repeating: 0, count: slots)
            bins.append(Bin(start: start, speech: speech, voices: voices, mouths: mouths))
        }
        // Voice → slot: the slot whose mouth moves most while the voice speaks.
        // With a highlight border the voices learn their slots from it;
        // otherwise from the mouths. A one-bin blip between two agreeing
        // neighbors takes their value, whichever way the highlight arrived.
        let highlightBins = smoothed(input.activity.highlight)
        var affinity = [[Double]](repeating: [Double](repeating: 0, count: slots), count: max(1, clusterCount))
        for (b, bin) in bins.enumerated() where bin.speech {
            let lit = (0..<slots).map { highlightBins[safe: $0]?[safe: b] ?? 0 }
            let evidence = lit.reduce(0, +) > 0.5 ? lit : bin.mouths
            for c in 0..<clusterCount { for s in 0..<slots { affinity[c][s] += bin.voices[c] * evidence[s] } }
        }
        var clusterSlots: [Int: Int] = [:]
        var taken = Set<Int>()
        let pairs = (0..<clusterCount).flatMap { c in (0..<slots).map { s in (c, s, affinity[c][s]) } }
            .sorted { $0.2 > $1.2 }
        for (c, s, _) in pairs where clusterSlots[c] == nil {
            if taken.contains(s), taken.count < slots { continue }
            clusterSlots[c] = s; taken.insert(s)
        }
        for c in 0..<clusterCount where clusterSlots[c] == nil {
            clusterSlots[c] = affinity[c].indices.max { affinity[c][$0] < affinity[c][$1] } ?? 0
        }
        // How much each voice prefers each slot, beyond chance: a voice that
        // covers everyone's speech says nothing about who is talking.
        let preference: [[Double]] = affinity.map { row in
            let total = row.reduce(0, +)
            return row.map { total > 1e-9 ? max(0, $0 / total - 1 / Double(slots)) : 0 }
        }
        // Per-bin slot scores, then a smoothed path over the speech bins.
        let highlight = highlightBins
        let scores: [[Double]] = bins.enumerated().map { b, bin in
            (0..<slots).map { s in
                let voice = (0..<clusterCount).reduce(0.0) { $0 + bin.voices[$1] * preference[$1][s] }
                let mouth = bin.mouths[s]
                let lit = highlight[safe: s]?[safe: b] ?? 0
                return visualWeight * mouth + audioWeight * voice * Double(slots) / max(1, Double(slots) - 1)
                    + highlightWeight * lit
            }
        }
        let path = viterbi(scores: scores, active: bins.map(\.speech))
        // Runs of the same slot over speech become turns.
        var turns: [SpeakerTurn] = []
        var margins: [Double] = []
        var runStart: Double?
        var runSlot = -1
        var runClusters: [Int: Int] = [:]
        func close(at end: Double) {
            guard let start = runStart, runSlot >= 0, end - start >= minimumTurn else { runStart = nil; return }
            let cluster = runClusters.max { $0.value < $1.value }?.key ?? 0
            let tile = tiles[runSlot]
            var turn = SpeakerTurn(videoID: videoID, start: start, end: end, cluster: cluster, confidence: 0)
            turn.tile = tile.index
            turn.resolvedSide = tile.centerX < 0.5 ? .left : .right
            turn.personKey = tile.personKey
            turns.append(turn)
            runStart = nil
        }
        for (b, bin) in bins.enumerated() {
            let slot = path[b]
            if !bin.speech || slot < 0 {
                close(at: bin.start)
                runSlot = -1; runClusters = [:]
                continue
            }
            let sorted = scores[b].sorted(by: >)
            margins.append(sorted.count > 1 ? sorted[0] - sorted[1] : sorted[0])
            if slot != runSlot {
                close(at: bin.start)
                runStart = bin.start; runSlot = slot; runClusters = [:]
            }
            if let best = bin.voices.indices.max(by: { bin.voices[$0] < bin.voices[$1] }) { runClusters[best, default: 0] += 1 }
        }
        close(at: Double(binCount) * binSeconds)
        // Confidence per turn: the mean margin of its bins.
        for i in turns.indices {
            let turn = turns[i]
            let inside = bins.indices.filter { bins[$0].speech && bins[$0].start >= turn.start && bins[$0].start < turn.end }
            let margin = inside.map { b -> Double in
                let sorted = scores[b].sorted(by: >)
                return sorted.count > 1 ? sorted[0] - sorted[1] : 1
            }
            turns[i].confidence = min(1, max(0, 0.5 + (margin.isEmpty ? 0 : margin.reduce(0, +) / Double(margin.count))))
        }
        let overall = margins.isEmpty ? 0 : margins.reduce(0, +) / Double(margins.count)
        return Outcome(turns: turns, clusterSlots: clusterSlots, clusterCount: clusterCount, margin: overall,
                       bins: bins, affinity: affinity)
    }

    /// The lit slot per bin with single-bin blips removed.
    static func smoothed(_ highlight: [[Double]]) -> [[Double]] {
        guard let bins = highlight.first?.count, bins > 2 else { return highlight }
        var lit: [Int?] = (0..<bins).map { b in highlight.indices.first { highlight[$0][b] >= 0.5 } }
        for b in 1..<(bins - 1) where lit[b - 1] == lit[b + 1] && lit[b] != lit[b - 1] { lit[b] = lit[b - 1] }
        return highlight.indices.map { slot in (0..<bins).map { lit[$0] == slot ? 1.0 : 0.0 } }
    }

    /// The best slot per bin with a cost for switching, so a momentary
    /// mouth twitch does not steal the camera. Inactive bins reset the path.
    static func viterbi(scores: [[Double]], active: [Bool]) -> [Int] {
        guard let slots = scores.first?.count, slots > 0 else { return [] }
        var path = [Int](repeating: -1, count: scores.count)
        var best = [Double](repeating: 0, count: slots)
        var back: [[Int]] = []
        var segmentStart = 0
        func flush(_ end: Int) {
            guard end > segmentStart else { back.removeAll(); return }
            var slot = best.indices.max { best[$0] < best[$1] } ?? 0
            for b in stride(from: end - 1, through: segmentStart, by: -1) {
                path[b] = slot
                slot = back[b - segmentStart][slot]
            }
            back.removeAll()
        }
        for b in scores.indices {
            guard active[b] else { flush(b); segmentStart = b + 1; best = [Double](repeating: 0, count: slots); continue }
            var next = [Double](repeating: 0, count: slots)
            var pointers = [Int](repeating: 0, count: slots)
            for s in 0..<slots {
                var bestPrev = best[s], from = s
                for p in 0..<slots where p != s {
                    let candidate = best[p] - switchPenalty
                    if candidate > bestPrev { bestPrev = candidate; from = p }
                }
                next[s] = bestPrev + scores[b][s]
                pointers[s] = from
            }
            best = next
            back.append(pointers)
        }
        flush(scores.count)
        return path
    }
}

