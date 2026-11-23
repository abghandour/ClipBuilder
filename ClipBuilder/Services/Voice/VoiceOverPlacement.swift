import Foundation

/// Where voice-over recordings sit in a reel. A recording is anchored to the
/// picture under it (video and source second), so it keeps that picture when
/// clips are reordered or trimmed, or pauses and bumpers shift the clock.
/// From its start the voice plays straight through, across the joins.
nonisolated enum VoiceOverPlacement {
    /// One cut of the reel, in reel order.
    struct Cut: Sendable, Equatable {
        var videoID: Int64
        var sourceStart: Double
        var sourceEnd: Double
        var speed = 1.0
        /// Where the cut starts on the reel's clock, and how long it plays.
        var reelStart: Double
        var reelDuration: Double
        /// Pauses on contact inside the cut, on its unpaused clock.
        var pauses: [WizardStrikePauses.Pause] = []
        var stretches: [StrikeImpactRules.Stretch] = []

        /// Seconds from the start of the cut at which a source second shows.
        /// The frame a pause holds shows twice, at the start of the pause and
        /// when the picture moves again; `afterPause` asks for the second.
        func localTime(ofSource time: Double, afterPause: Bool = false) -> Double {
            let planned = max(0, (time - sourceStart) / max(0.01, speed))
            // 0.02 s of source: under the 0.05 s by which an anchor before a pause
            // stays clear of it. Pause times are on the played clock, so it is scaled.
            let reach = afterPause ? 0.02 / max(0.01, speed) : -1e-9
            let held = pauses.reduce(0) { $0 + ($1.time < planned + reach ? $1.duration : 0) }
            return min(reelDuration, planned + held + stretches.reduce(0) { $0 + $1.addedTime(at: planned) })
        }

        func contains(source time: Double) -> Bool {
            time >= sourceStart - 0.02 && time < sourceEnd - 0.02
        }

        /// A rough cut shows a pause on contact as a clip of its own: one
        /// source frame held for the length of the pause.
        var isHold: Bool { sourceEnd - sourceStart < 0.05 }

        /// Seconds from the start of the cut at which a recording made
        /// `offset` seconds into a hold on `time` starts, when the cut holds there.
        func localTime(inHoldOn time: Double, offset: Double) -> Double? {
            guard offset >= 0 else { return nil }
            if isHold {
                guard abs(sourceStart - time) < 0.05 else { return nil }
                return min(offset, max(0, reelDuration - 0.05))
            }
            guard time >= sourceStart - 0.05, time <= sourceEnd + 0.05 else { return nil }
            let planned = max(0, (time - sourceStart) / max(0.01, speed))
            guard let pause = pauses.min(by: { abs($0.time - planned) < abs($1.time - planned) }),
                  abs(pause.time - planned) < 0.05 else { return nil }
            let before = pauses.reduce(0) { $0 + ($1.time < pause.time - 1e-9 ? $1.duration : 0) }
            let stretched = stretches.reduce(0) { $0 + $1.addedTime(at: pause.time) }
            return min(reelDuration, pause.time + before + stretched + min(offset, max(0, pause.duration - 0.05)))
        }
    }

    struct Placed: Sendable, Equatable {
        var take: VoiceTake
        /// Seconds on the reel's clock where the voice starts.
        var start: Double
        /// The cut it starts in (an index into the cuts it was placed in)
        /// and how far into that cut, so the same place can be found on another clock.
        var cut = 0
        var local = 0.0
        var end: Double { start + take.duration }
    }

    /// The showings of one picture in a reel, in reel order: for each, the
    /// cuts that show `time` of `videoID`. A rough cut shows a pause on
    /// contact as a held clip between the two halves of its cut; the hold
    /// and the half after it are one showing. `hold` asks for the showings a
    /// recording made during a pause belongs to: those with the pause, and
    /// those that show the frame without pausing on it.
    static func showings(videoID: Int64, time: Double, hold: Bool, in cuts: [Cut]) -> [[Int]] {
        var groups: [[Int]] = []
        for (index, cut) in cuts.enumerated() where cut.videoID == videoID {
            let shows: Bool
            if cut.isHold {
                shows = hold && abs(cut.sourceStart - time) < 0.05
            } else {
                shows = cut.contains(source: time) || (hold && cut.localTime(inHoldOn: time, offset: 0) != nil)
            }
            guard shows else { continue }
            // A hold and the halves of its own cut are one showing, whichever of
            // them match: the half before ends on the held frame, the half after
            // starts on it. Any other neighbour is another showing.
            if let last = groups.last?.last, last == index - 1, cuts[last].isHold != cut.isHold,
               abs((cuts[last].isHold ? cuts[last].sourceStart : cuts[last].sourceEnd) - cut.sourceStart) < 0.05 {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    /// The takes whose picture is in the reel, in reel order. A take whose
    /// footage was removed is left out; nothing deletes it.
    static func place(_ takes: [VoiceTake], in cuts: [Cut]) -> [Placed] {
        takes.compactMap { take -> Placed? in
            guard take.duration > 0 else { return nil }
            // Where the voice starts inside one showing. Recorded partway into
            // a pause on contact: that far into the same pause; without the
            // pause it falls back to the picture alone.
            func spot(in showing: [Int]) -> (placed: Placed, held: Bool)? {
                if let offset = take.holdOffset {
                    for index in showing {
                        if let local = cuts[index].localTime(inHoldOn: take.sourceTime, offset: offset) {
                            return (Placed(take: take, start: cuts[index].reelStart + local, cut: index, local: local), true)
                        }
                    }
                }
                guard let index = showing.first(where: { !cuts[$0].isHold && cuts[$0].contains(source: take.sourceTime) })
                else { return nil }
                // Recorded while the picture moved: on a frame a pause holds, that
                // is the moment it moves again (a recording made in the pause has an offset).
                let local = cuts[index].localTime(ofSource: take.sourceTime, afterPause: take.holdOffset == nil)
                return (Placed(take: take, start: cuts[index].reelStart + local, cut: index, local: local), false)
            }
            let spots = showings(videoID: take.videoID, time: take.sourceTime, hold: take.holdOffset != nil, in: cuts)
                .compactMap(spot)
            guard !spots.isEmpty else { return nil }
            // Footage that is in the reel more than once: the showing it was
            // recorded over, counted in reel order (the rough cut and the
            // final reel run on different clocks, so times cannot be compared).
            if let occurrence = take.occurrence {
                return spots[min(max(0, occurrence), spots.count - 1)].placed
            }
            // A recording that never noted its showing: a pause it was made
            // in comes first, then the place nearest its own.
            let preferred = spots.contains { $0.held } ? spots.filter(\.held) : spots
            return preferred.min { abs($0.placed.start - take.reelTime) < abs($1.placed.start - take.reelTime) }?.placed
        }
        .sorted { $0.start < $1.start }
    }

    /// The same places on another clock: `cuts` are the cuts `placed` was
    /// worked out in, moved (`joined`). Placing twice could choose two
    /// different showings; this cannot.
    static func moved(_ placed: [Placed], onto cuts: [Cut]) -> [Placed] {
        placed.compactMap { item -> Placed? in
            guard let cut = cuts[safe: item.cut] else { return nil }
            var item = item
            item.start = cut.reelStart + item.local
            return item
        }
        .sorted { $0.start < $1.start }
    }

    /// The picture under a reel second: which video and which source second.
    /// Over a pause on contact it also says how far into the pause.
    /// `occurrence` is which showing of that picture it is (0 = the first),
    /// by the rule `place` chooses with (`showings`).
    static func anchor(at reelTime: Double, in clips: [WizardPreviewClip])
        -> (videoID: Int64, sourceTime: Double, holdOffset: Double?, occurrence: Int)? {
        guard let moment = WizardPreviewClips.moment(in: clips, at: reelTime),
              let index = clips.firstIndex(where: { $0.id == moment.clipID }) else { return nil }
        let clip = clips[index]
        let all = cuts(from: clips)
        func occurrence(time: Double, hold: Bool) -> Int {
            let groups = showings(videoID: clip.scene.videoID, time: time, hold: hold, in: all)
            return groups.firstIndex { $0.contains(index) } ?? groups.filter { ($0.last ?? 0) < index }.count
        }
        if clip.duration < 0.05, let start = clip.outputStart {
            return (clip.scene.videoID, clip.start, max(0, reelTime - start), occurrence(time: clip.start, hold: true))
        }
        // A moment at the very end of a clip belongs to the frame before it.
        let time = min(moment.time, max(clip.start, clip.end - 0.05))
        return (clip.scene.videoID, time, nil, occurrence(time: time, hold: false))
    }

    /// The cuts moved from the timeline's clock to the joined reel's: every
    /// join that overlaps (a crossfade) pulls what follows it earlier.
    static func joined(_ cuts: [Cut], clock: RenderClock) -> [Cut] {
        joined(cuts) { clock.map($0) }
    }

    /// The cuts where `output` puts their starts in the joined reel.
    static func joined(_ cuts: [Cut], output: (Double) -> Double) -> [Cut] {
        cuts.map { cut in
            var cut = cut
            cut.reelStart = output(cut.reelStart)
            return cut
        }
    }

    /// The preview clips of a rough cut as reel cuts, back to back when untimed.
    static func cuts(from clips: [WizardPreviewClip]) -> [Cut] {
        var cursor = 0.0
        return clips.map { clip in
            let start = clip.outputStart ?? cursor
            let duration = clip.outputDuration ?? clip.duration
            cursor = start + duration
            let speed = duration > 0 && clip.duration > 0 ? clip.duration / duration : 1
            return Cut(videoID: clip.scene.videoID, sourceStart: clip.start, sourceEnd: clip.end,
                       speed: speed, reelStart: start, reelDuration: duration)
        }
    }

    // MARK: Captions

    /// The words a take's caption shows, on the take's own clock. The
    /// original text keeps its measured clocks; a corrected or translated
    /// text keeps the clocks of the words it shares and spreads the rest.
    static func captionWords(for take: VoiceTake, language: String?) -> [TranscriptWord] {
        let target = language.map(ProjectLanguageResolver.languageCode) ?? ""
        let translated = target.isEmpty || target == take.language ? nil : take.translations[target]?.text
        let text = (translated ?? take.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let span = speechSpan(of: take)
        if translated == nil,
           let aligned = TranscriptWordAlignment.realign(text: text, original: take.words, start: span.start, end: span.end) {
            return aligned
        }
        return spread(text, start: span.start, end: span.end)
    }

    /// Where the speech sits inside the recording.
    static func speechSpan(of take: VoiceTake) -> (start: Double, end: Double) {
        let start = min(max(0, take.words.first?.start ?? 0), max(0, take.duration - 0.2))
        let end = min(take.duration, max(start + 0.2, take.words.last?.end ?? take.duration))
        return (start, end)
    }

    /// Words given time in proportion to their length.
    static func spread(_ text: String, start: Double, end: Double) -> [TranscriptWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, end > start else { return [] }
        let total = Double(tokens.reduce(0) { $0 + max(1, $1.count) })
        var cursor = start
        return tokens.map { token in
            let length = (end - start) * Double(max(1, token.count)) / total
            defer { cursor += length }
            return TranscriptWord(word: token, start: cursor, end: cursor + length)
        }
    }

    /// The caption lines of the placed takes that fall inside one cut, on the
    /// cut's own clock (seconds from its start). A take that runs over a join
    /// gives each cut the words spoken during it.
    static func captions(for cut: Cut, placed: [Placed], language: String?) -> [TranscriptSegment] {
        placed.compactMap { item in
            // A word belongs to every cut it is spoken during, clamped to that cut.
            // One a correction squeezed between two others keeps a frame of time.
            let words = captionWords(for: item.take, language: language).compactMap { word -> TranscriptWord? in
                let start = item.start + word.start - cut.reelStart
                let end = max(start + 0.04, item.start + word.end - cut.reelStart)
                // A sliver of a word (the tail of one that ends as a crossfade
                // begins) is not shown on the cut it barely touches.
                let inside = min(cut.reelDuration, end) - max(0, start)
                guard inside >= min(0.15, (end - start) / 2) else { return nil }
                var word = word
                word.start = max(0, start)
                word.end = min(cut.reelDuration, end)
                return word
            }
            guard let first = words.first, let last = words.last else { return nil }
            return TranscriptSegment(start: first.start, end: last.end,
                                     text: words.map(\.word).joined(separator: " "), words: words)
        }
    }

    /// The footage's caption lines with the stretches a voice talks over
    /// taken out. `voice` is on the cut's output clock; the footage's lines
    /// are on the source clock, so each voice window is mapped back through
    /// the cut's speed and pauses. A line with word clocks keeps the words
    /// outside the windows; one without is trimmed, or dropped when most of
    /// it is covered.
    static func footage(_ source: [TranscriptSegment], hiddenBy voice: [TranscriptSegment], clipStart: Double,
                        speed: Double, timing: WizardStrikePauses.Timing) -> [TranscriptSegment] {
        guard !voice.isEmpty else { return source }
        func sourceTime(_ output: Double) -> Double { clipStart + timing.plannedTime(forOutput: output) * speed }
        // A window inside a hold collapses to the held frame; keep it a frame wide.
        let windows = voice.map { (start: sourceTime($0.start), end: max(sourceTime($0.end), sourceTime($0.start) + 0.04)) }
        func hidden(_ start: Double, _ end: Double) -> Bool {
            windows.contains { $0.start < end && start < $0.end }
        }
        return source.flatMap { segment -> [TranscriptSegment] in
            guard hidden(segment.start, segment.end) else { return [segment] }
            if let words = segment.words, !words.isEmpty {
                // Runs of words the voice leaves alone become lines of their own.
                var runs: [[TranscriptWord]] = [[]]
                for word in words {
                    if hidden(word.start, max(word.end, word.start + 0.01)) {
                        if runs.last?.isEmpty == false { runs.append([]) }
                    } else {
                        runs[runs.count - 1].append(word)
                    }
                }
                return runs.filter { !$0.isEmpty }.map { run in
                    TranscriptSegment(start: run[0].start, end: run[run.count - 1].end,
                                      text: run.map(\.word).joined(separator: " "), words: run)
                }
            }
            // No word clocks: the text cannot be split, only shown for less time.
            let covered = windows.reduce(0.0) { $0 + max(0, min($1.end, segment.end) - max($1.start, segment.start)) }
            guard covered < (segment.end - segment.start) / 2,
                  let first = windows.filter({ $0.start < segment.end && segment.start < $0.end }).min(by: { $0.start < $1.start }),
                  let last = windows.filter({ $0.start < segment.end && segment.start < $0.end }).max(by: { $0.end < $1.end })
            else { return [] }
            var trimmed = segment
            if first.start - segment.start >= segment.end - last.end { trimmed.end = first.start } else { trimmed.start = last.end }
            return trimmed.end - trimmed.start > 0.2 ? [trimmed] : []
        }
    }

    /// The stretches of a cut, on its own clock, that a voice talks over.
    static func spans(for cut: Cut, placed: [Placed]) -> [ClosedRange<Double>] {
        placed.compactMap { item in
            let start = max(0, item.start - cut.reelStart)
            let end = min(cut.reelDuration, item.end - cut.reelStart)
            return end > start ? start...end : nil
        }
    }
}

extension WizardStrikePauses.Timing {
    /// The inverse of `outputTime`: the unpaused second showing at an output
    /// second. Every second of a hold maps to the held frame.
    func plannedTime(forOutput output: Double) -> Double {
        if !stretches.isEmpty {
            for pause in pauses {
                let start = outputTime(pause.time)
                if output >= start, output < start + pause.duration { return pause.time }
            }
            if output >= outputDuration { return max(0, output - addedDuration) }
            var lower = 0.0, upper = plannedDuration
            for _ in 0..<64 {
                let middle = (lower + upper) / 2
                if outputTime(middle) < output { lower = middle } else { upper = middle }
            }
            return (lower + upper) / 2
        }
        var shift = 0.0
        for pause in pauses.sorted(by: { $0.time < $1.time }) {
            if output <= pause.time + shift { break }
            if output < pause.time + shift + pause.duration { return pause.time }
            shift += pause.duration
        }
        return max(0, output - shift)
    }
}
