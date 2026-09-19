import Foundation

/// Who is talking when, for any number of people: voice clusters from the
/// audio and mouth motion per face slot from the picture, combined on a
/// fine time grid and smoothed so the speaker only changes when the
/// evidence does. Slots are the layout's tiles; voices map onto slots by
/// how their speech lines up with mouth motion over the whole recording.
nonisolated enum SpeakerTracker {
    /// What the audio windows hold: spectral averages (the fallback) or
    /// neural voice embeddings, which separate voices far more cleanly and
    /// so earn trust at a lower measured separation.
    enum FeatureKind: Sendable {
        case spectral
        case embedding
    }

    struct Input: Sendable {
        var audioWindows: [SpeakerFeatures.Window]
        var activity: VisualSpeechActivity.Activity
        var speech: [ClosedRange<Double>]
        var tiles: [PodcastTile]
        var duration: Double
        var featureKind: FeatureKind = .spectral
        /// Rows the user attributed by hand, as time ranges per slot: the
        /// tracker learns those voices ahead of anything the border says.
        var corrections: [Correction] = []
        /// Voices remembered from other files for the people in the tiles:
        /// they seed the slot's profile so the audio is trusted before the
        /// border has taught anything here.
        var priors: [Prior] = []
    }

    struct Correction: Sendable, Equatable {
        var range: ClosedRange<Double>
        var slot: Int
    }

    /// A stored voice for a slot: a unit centroid and how many windows
    /// stand behind it.
    struct Prior: Sendable, Equatable {
        var slot: Int
        var vector: [Double]
        var windows: Int
    }

    /// Speech bins where a trusted voice profile named another tile than
    /// the lit one, and how many of them the path gave to the voice.
    struct Disagreement: Sendable, Equatable {
        var bins = 0
        var followedAudio = 0
        /// Bins where the voice was sure (posterior 0.9 or more).
        var confident = 0
        /// Bins at least two seconds from any change of the lit tile —
        /// where the border itself is not in transition.
        var interior = 0
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
        /// Voice profiles learned from the picture, when it taught enough.
        var enrollment: Enrollment?
        var disagreement = Disagreement()
        /// Diagnostics: per bin, the enrolled voice posterior per slot and
        /// the smoothed lit tile per slot.
        var enrolledVoices: [[Double]] = []
        var highlight: [[Double]] = []
        var path: [Int] = []
    }

    /// Voice profiles per slot, learned where the picture was sure: long
    /// stretches with one tile lit alone are labelled audio, so each slot
    /// gets a centroid of its own voice. `separation` says how far apart
    /// the profiles sit compared with how much each one wanders — below
    /// about 1 the voices are not told apart and the audio is not trusted.
    struct Enrollment: Sendable, Equatable {
        var centroids: [Int: [Double]]
        var windowsPerSlot: [Int: Int]
        var separation: Double
        var featureKind: FeatureKind = .spectral
        /// Windows the user's own attributions contributed.
        var correctionWindows = 0
        var correctionWindowsPerSlot: [Int: Int] = [:]
        /// The profiles this file taught on its own, without any prior —
        /// what is worth remembering about a person from this file.
        var fileCentroids: [Int: [Double]] = [:]
        /// Slots a stored voice seeded.
        var priorSlots: Set<Int> = []
        /// How often a window from one taught stretch lands on the right
        /// slot when the profiles are built from the other stretches —
        /// the profiles' accuracy on speech they did not learn from. Nil
        /// when too few windows could be held out.
        var heldOutAgreement: Double?
        var heldOutWindows = 0

        var slotCount: Int { centroids.count }
        /// How much the audio term may weigh: from the held-out accuracy
        /// when it could be measured (nothing at 70%, everything from
        /// 95%), else from the separation. Spectral averages: nothing below
        /// a separation of 0.8, everything from 1.8 up. Embeddings earn it
        /// sooner: on a four-way call they measured 1.3 while placing
        /// every clip on the right person.
        var trust: Double {
            if let heldOutAgreement { return min(1, max(0, (heldOutAgreement - 0.7) / 0.25)) }
            switch featureKind {
            case .spectral: return min(1, max(0, (separation - 0.8) / 1.0))
            case .embedding: return min(1, max(0, (separation - 0.7) / 0.6))
            }
        }
    }

    /// Held-out windows needed before the agreement is believed.
    static let heldOutMinimum = 8

    /// A tile must be lit alone, over speech, at least this long to teach
    /// its voice; and a slot needs this many windows to get a profile.
    static let enrollmentStretch = 4.0
    static let enrollmentWindows = 6
    /// Embedding windows are two seconds long stepping by half: a four
    /// second stretch holds four of them whole.
    static let embeddingEnrollmentWindows = 4
    /// A trusted voice profile weighs about as much as the border.
    static let enrolledAudioWeight = 1.5
    /// A remembered voice counts as at most this many windows (about
    /// twenty seconds of speech): enough to enroll a tile the border never
    /// taught, while a file's own windows outvote it.
    static let priorWindows = 40

    static let visualWeight = 0.55
    static let audioWeight = 0.45
    /// A highlighted tile outranks mouths and blind voices together.
    static let highlightWeight = 2.0
    /// How much of the border's weight a fully trusted voice takes away:
    /// at full trust the border weighs 0.8, so a clear voice (a margin
    /// above about 0.55) holds the speaker through a reaction that lights
    /// another tile, while an unsure voice still follows the border.
    static let highlightYield = 0.6
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
        let geometry: SpeakerClustering.Geometry = input.featureKind == .embedding ? .cosine : .standardized
        let clustering = SpeakerClustering.cluster(input.audioWindows.map(\.vector), minimum: min(2, slots),
                                                   maximum: max(2, slots), geometry: geometry)
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
                    let p = SpeakerClustering.posterior(clustering.vectors[i], centroids: clustering.centroids, geometry: geometry)
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
        // Voice profiles from the border: where the picture taught enough,
        // each bin's audio is matched against the slots' own voices, and
        // that match replaces the blind cluster preference in proportion to
        // how well the profiles separate.
        // Embeddings keep the model's own geometry; spectral averages are
        // standardized so every coefficient counts alike.
        let standardized = geometry == .cosine ? input.audioWindows.map { SpeakerClustering.normalized($0.vector) }
            : SpeakerClustering.standardize(input.audioWindows.map(\.vector))
        var enrollment = enroll(windows: input.audioWindows, vectors: standardized, highlight: highlightBins,
                                speech: bins.map(\.speech), binSeconds: binSeconds, slots: slots,
                                corrections: input.corrections, priors: input.priors, geometry: geometry,
                                minimumWindows: input.featureKind == .embedding ? embeddingEnrollmentWindows : enrollmentWindows)
        enrollment?.featureKind = input.featureKind
        let enrolledVoices: [[Double]] = bins.enumerated().map { b, bin in
            guard let enrollment, bin.speech else { return [Double](repeating: 0, count: slots) }
            let mid = bin.start + binSeconds / 2
            let covering = input.audioWindows.indices.filter { input.audioWindows[$0].start <= mid && mid < input.audioWindows[$0].end }
            guard !covering.isEmpty else { return [Double](repeating: 0, count: slots) }
            var sum = [Double](repeating: 0, count: slots)
            for i in covering {
                let p = slotPosterior(standardized[i], enrollment: enrollment, slots: slots, geometry: geometry)
                for s in 0..<slots { sum[s] += p[s] / Double(covering.count) }
            }
            return sum
        }
        let trust = enrollment?.trust ?? 0
        // Per-bin slot scores, then a smoothed path over the speech bins.
        let highlight = highlightBins
        let scores: [[Double]] = bins.enumerated().map { b, bin in
            (0..<slots).map { s in
                let voice = (0..<clusterCount).reduce(0.0) { $0 + bin.voices[$1] * preference[$1][s] }
                let mouth = bin.mouths[s]
                let lit = highlight[safe: s]?[safe: b] ?? 0
                let blind = audioWeight * voice * Double(slots) / max(1, Double(slots) - 1)
                let audio: Double
                if let enrollment, enrollment.centroids[s] != nil {
                    let enrolled = enrolledAudioWeight * (enrolledVoices[b][s] - 1 / Double(slots))
                    audio = (1 - trust) * blind + trust * enrolled
                } else {
                    // A tile nobody taught keeps its blind clustering: the
                    // profiles say nothing about it, so they must not
                    // count against it.
                    audio = blind
                }
                let border = highlightWeight * (1 - highlightYield * trust) * lit
                return visualWeight * mouth + audio + border
            }
        }
        let path = viterbi(scores: scores, active: bins.map(\.speech))
        // Where a trusted voice and the border named different tiles, and
        // which one the path believed: the number that says whether the
        // audio can hold a speaker through a reaction.
        var disagreement = Disagreement()
        if trust > 0 {
            func litSlot(_ b: Int) -> Int? {
                let lit = (0..<slots).filter { (highlight[safe: $0]?[safe: b] ?? 0) >= 0.5 }
                return lit.count == 1 ? lit[0] : nil
            }
            let margin = Int((2.0 / binSeconds).rounded())
            for (b, bin) in bins.enumerated() where bin.speech && path[b] >= 0 {
                let voices = enrolledVoices[b]
                guard let lit = litSlot(b),
                      let voiceSlot = voices.indices.max(by: { voices[$0] < voices[$1] }),
                      voices[voiceSlot] >= 0.6, voiceSlot != lit else { continue }
                disagreement.bins += 1
                if path[b] == voiceSlot { disagreement.followedAudio += 1 }
                if voices[voiceSlot] >= 0.9 { disagreement.confident += 1 }
                let steady = (max(0, b - margin)...min(bins.count - 1, b + margin)).allSatisfy { litSlot($0) == lit }
                if steady { disagreement.interior += 1 }
            }
        }
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
        close(at: min(input.duration, Double(binCount) * binSeconds))
        // Confidence per turn: how much the trusted voice supports the
        // chosen tile over the turn's bins; where the voice is not trusted,
        // the mean score margin of its bins (a border-driven number).
        for i in turns.indices {
            let turn = turns[i]
            let inside = bins.indices.filter { bins[$0].speech && bins[$0].start >= turn.start && bins[$0].start < turn.end }
            let margin = inside.map { b -> Double in
                let sorted = scores[b].sorted(by: >)
                return sorted.count > 1 ? sorted[0] - sorted[1] : 1
            }
            let byMargin = min(1, max(0, 0.5 + (margin.isEmpty ? 0 : margin.reduce(0, +) / Double(margin.count))))
            let slot = tiles.firstIndex { $0.index == turn.tile } ?? 0
            let support = inside.isEmpty ? 0 : inside.reduce(0.0) { $0 + enrolledVoices[$1][slot] } / Double(inside.count)
            turns[i].confidence = trust * support + (1 - trust) * byMargin
        }
        let overall = margins.isEmpty ? 0 : margins.reduce(0, +) / Double(margins.count)
        return Outcome(turns: turns, clusterSlots: clusterSlots, clusterCount: clusterCount, margin: overall,
                       bins: bins, affinity: affinity, enrollment: enrollment, disagreement: disagreement,
                       enrolledVoices: enrolledVoices, highlight: highlight, path: path)
    }

    /// Learn a voice per slot from the stretches where that tile alone was
    /// lit over speech for at least `enrollmentStretch`, and from the rows
    /// the user attributed by hand, whatever their length. Nil when fewer
    /// than two slots taught enough.
    static func enroll(windows: [SpeakerFeatures.Window], vectors: [[Double]], highlight: [[Double]],
                       speech: [Bool], binSeconds: Double, slots: Int,
                       corrections: [Correction] = [],
                       priors: [Prior] = [],
                       geometry: SpeakerClustering.Geometry = .standardized,
                       minimumStretch: Double = enrollmentStretch,
                       minimumWindows: Int = enrollmentWindows) -> Enrollment? {
        guard slots >= 2, !windows.isEmpty, windows.count == vectors.count else { return nil }
        let binCount = highlight.first?.count ?? speech.count
        guard binCount > 0 else { return nil }
        let needed = Int((minimumStretch / binSeconds).rounded(.up))
        // Bins where exactly one slot is lit, and the stretch is long enough.
        var owner = [Int](repeating: -1, count: binCount)
        for b in 0..<binCount where b < speech.count && speech[b] {
            let lit = (0..<slots).filter { (highlight[safe: $0]?[safe: b] ?? 0) >= 0.5 }
            if lit.count == 1 { owner[b] = lit[0] }
        }
        var taught = [Int](repeating: -1, count: binCount)
        var b = 0
        while b < binCount {
            let slot = owner[b]
            var end = b
            while end < binCount, owner[end] == slot { end += 1 }
            if slot >= 0, end - b >= needed { for i in b..<end { taught[i] = slot } }
            b = end
        }
        // The user's own attributions outrank the border: their bins are
        // taught whatever their length, and where the border taught
        // otherwise the correction wins.
        var corrected = [Bool](repeating: false, count: binCount)
        for correction in corrections where correction.slot >= 0 && correction.slot < slots {
            let first = max(0, Int(correction.range.lowerBound / binSeconds))
            let last = min(binCount - 1, Int(correction.range.upperBound / binSeconds))
            guard first <= last else { continue }
            for i in first...last { taught[i] = correction.slot; corrected[i] = true }
        }
        // Number the taught stretches per slot, so the profiles can be
        // checked on stretches they did not learn from.
        var stretchOf = [Int](repeating: -1, count: binCount)
        var stretchCount = [Int](repeating: 0, count: slots)
        b = 0
        while b < binCount {
            let slot = taught[b]
            var end = b
            while end < binCount, taught[end] == slot { end += 1 }
            if slot >= 0 {
                for i in b..<end { stretchOf[i] = stretchCount[slot] }
                stretchCount[slot] += 1
            }
            b = end
        }
        var members: [Int: [[Double]]] = [:]
        var stretches: [Int: [Int]] = [:]
        var correctionWindows = 0
        var correctionPerSlot: [Int: Int] = [:]
        for (index, window) in windows.enumerated() {
            let mid = (window.start + window.end) / 2
            let bin = Int(mid / binSeconds)
            guard bin >= 0, bin < binCount, taught[bin] >= 0 else { continue }
            // The whole window must sit inside the taught stretch.
            let first = Int(window.start / binSeconds), last = Int(max(window.start, window.end - 0.01) / binSeconds)
            guard first >= 0, last < binCount, taught[first] == taught[bin], taught[last] == taught[bin] else { continue }
            members[taught[bin], default: []].append(vectors[index])
            stretches[taught[bin], default: []].append(stretchOf[bin])
            if corrected[bin] { correctionWindows += 1; correctionPerSlot[taught[bin], default: 0] += 1 }
        }
        func centroid(_ list: [[Double]]) -> [Double] {
            let dimension = list[0].count
            let mean = (0..<dimension).map { d in list.reduce(0) { $0 + $1[d] } / Double(list.count) }
            return geometry == .cosine ? SpeakerClustering.normalized(mean) : mean
        }
        // Remembered voices: a capped run of virtual windows at the stored
        // centroid, so a tile the border never taught still enrolls while
        // the file's own windows outvote the memory. Only vectors of the
        // file's own dimension can be compared.
        let dimension = vectors.first?.count ?? 0
        var priorMembers: [Int: [[Double]]] = [:]
        for prior in priors where prior.slot >= 0 && prior.slot < slots && prior.vector.count == dimension {
            let count = max(1, min(priorWindows, prior.windows))
            priorMembers[prior.slot, default: []] += Array(repeating: prior.vector, count: count)
        }
        var centroids: [Int: [Double]] = [:]
        var fileCentroids: [Int: [Double]] = [:]
        var spreads: [Double] = []
        for slot in Set(members.keys).union(priorMembers.keys) {
            let own = members[slot] ?? []
            let taughtEnough = own.count >= minimumWindows
            guard taughtEnough || priorMembers[slot] != nil else { continue }
            if taughtEnough {
                let center = centroid(own)
                fileCentroids[slot] = center
                spreads.append(own.reduce(0) { $0 + SpeakerClustering.distance($1, center) } / Double(own.count))
            }
            centroids[slot] = centroid(own + (priorMembers[slot] ?? []))
        }
        guard centroids.count >= 2 else { return nil }
        // Held out: even-numbered stretches teach, odd-numbered ones test
        // (a slot with a single stretch alternates windows instead, which
        // leaks a little between neighbours but is all there is).
        var training: [Int: [[Double]]] = [:]
        var testing: [(slot: Int, vector: [Double])] = []
        for slot in centroids.keys {
            let list = members[slot] ?? []
            let labels = stretches[slot] ?? []
            let single = Set(labels).count < 2
            for (index, vector) in list.enumerated() {
                let fold = single ? index : labels[index]
                if fold % 2 == 0 { training[slot, default: []].append(vector) } else { testing.append((slot, vector)) }
            }
            // A remembered voice always teaches and is never tested.
            if let prior = priorMembers[slot] { training[slot, default: []] += prior }
        }
        var agreement: Double?
        var heldOut = 0
        if training.count == centroids.count, training.values.allSatisfy({ !$0.isEmpty }), testing.count >= heldOutMinimum {
            let keys = training.keys.sorted()
            let centers = keys.map { centroid(training[$0]!) }
            let right = testing.count { test in
                let nearest = centers.indices.min { SpeakerClustering.distance(test.vector, centers[$0])
                    < SpeakerClustering.distance(test.vector, centers[$1]) }
                return nearest.map { keys[$0] } == test.slot
            }
            agreement = Double(right) / Double(testing.count)
            heldOut = testing.count
        }
        let keys = centroids.keys.sorted()
        var between: [Double] = []
        for i in keys.indices { for j in keys.indices where j > i {
            between.append(SpeakerClustering.distance(centroids[keys[i]]!, centroids[keys[j]]!))
        } }
        let within = spreads.isEmpty ? 0 : spreads.reduce(0, +) / Double(spreads.count)
        let apart = between.reduce(0, +) / Double(between.count)
        // Profiles with no spread at all are perfectly separated when they
        // differ, not indistinguishable.
        let separation = within > 1e-9 ? apart / within : (apart > 1e-9 ? 10 : 0)
        return Enrollment(centroids: centroids, windowsPerSlot: members.mapValues(\.count), separation: separation,
                          correctionWindows: correctionWindows, correctionWindowsPerSlot: correctionPerSlot,
                          fileCentroids: fileCentroids, priorSlots: Set(priorMembers.keys).intersection(centroids.keys),
                          heldOutAgreement: agreement, heldOutWindows: heldOut)
    }

    /// Which enrolled slot a window's voice is nearest, as a distribution
    /// over all slots (unenrolled slots get nothing).
    static func slotPosterior(_ vector: [Double], enrollment: Enrollment, slots: Int,
                              geometry: SpeakerClustering.Geometry = .standardized) -> [Double] {
        let keys = enrollment.centroids.keys.sorted()
        let p = SpeakerClustering.posterior(vector, centroids: keys.map { enrollment.centroids[$0]! }, geometry: geometry)
        var result = [Double](repeating: 0, count: slots)
        for (index, slot) in keys.enumerated() where slot < slots { result[slot] = p[index] }
        return result
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

