import Foundation

/// Evidence-linked fight stories (docs/Fight-Story-Plan.md): one timeline
/// from an interview claim (a transcript pick), a fight sequence (fight
/// picks), and an outcome card. Every clip and the card carry a
/// `StoryProvenance` back to the transcript range, fight events, or the
/// outcome and research records they came from. Pure: the store loads the
/// records and scenes, this only lays them out.
nonisolated enum FightStoryBuilder {
    /// The outcome card's copy: a small kicker above a headline, plus an
    /// optional second line.
    struct StoryCardCopy: Codable, Sendable, Equatable {
        var kicker: String
        var headline: String
        var subline: String?

        init(kicker: String, headline: String, subline: String? = nil) {
            self.kicker = kicker
            self.headline = headline
            self.subline = subline
        }

        var isEmpty: Bool { headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// The card's text: the headline, then the subline on its own line.
        var text: String {
            let sub = subline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return sub.isEmpty ? headline : headline + "\n" + sub
        }
    }

    struct Input: Sendable {
        var claim: TranscriptPick
        var claimScene: SceneRecord
        var claimVideo: VideoRecord
        /// Fight picks in story order.
        var fight: [FightPick]
        /// Scenes covering each fight pick's range, keyed by pick id.
        var fightScenes: [Int64: SceneRecord]
        var fightVideo: VideoRecord
        var outcome: FightOutcome?
        var research: FightResearchRecord?
        var card: StoryCardCopy
        var stat: StrikeStatPayload?
        var cardDuration: Double = 2.5
        /// The spoken text of the claim, for its provenance label.
        var claimText: String?
        /// The scene behind the outcome card (from `backdropRange`). Nil
        /// falls back to a raw-file clip of the fight video over that range.
        var backdropScene: SceneRecord?
    }

    /// The card shows for this long when the caller does not say otherwise.
    static let defaultCardDuration = 2.5
    /// Darkens the footage under the card so the copy reads.
    static let backdropEffect = EffectSpec(preset: "brightness", params: ["brightness": -0.35])

    // MARK: - Build

    /// Claim first, fight clips in pick order, then the outcome card over a
    /// dimmed backdrop clip of the fight video. Start times are rippled.
    ///
    /// The renderer's output ends at the last clip, so a bare trailing gap
    /// would never render; the card's "gap" is a `cardDuration` backdrop
    /// clip from fight footage outside the picked ranges (see
    /// `backdropRange`), which also gives a stat card the source time it
    /// binds to.
    static func build(_ input: Input, renderSettings: RenderSettings) -> TimelineDocument {
        var document = TimelineDocument()
        document.renderSettings = renderSettings
        var cursor = 0.0

        let claimStart = input.claim.start
        let claimEnd = max(input.claim.start, input.claim.end)
        if claimEnd - claimStart > 0.001 {
            var clip = makeClip(scene: input.claimScene, start: claimStart, end: claimEnd, at: cursor)
            clip.provenance = StoryProvenance(kind: .transcript, videoID: input.claimVideo.id,
                                              sourceStart: claimStart, sourceEnd: claimEnd,
                                              transcriptPickID: input.claim.id,
                                              label: input.claimText.flatMap { $0.isEmpty ? nil : $0 })
            document.videoTrack.append(clip)
            cursor += clip.duration
        }

        let plan = backdropPlan(fight: input.fight, videoDuration: input.fightVideo.duration,
                                cardDuration: input.cardDuration)
        let backdrop = plan.range
        for (index, pick) in input.fight.enumerated() {
            let start = pick.start
            var end = max(pick.start, pick.end)
            // No free footage: the backdrop is the last pick's tail, cut off
            // the pick so the two never show the same source moment.
            if plan.trimsLastPick, index == input.fight.count - 1 { end = backdrop.lowerBound }
            guard end - start > 0.001, let scene = input.fightScenes[pick.id] else { continue }
            var clip = makeClip(scene: scene, start: start, end: end, at: cursor)
            clip.provenance = StoryProvenance(kind: .fightAction, videoID: input.fightVideo.id,
                                              sourceStart: start, sourceEnd: end, fightPickID: pick.id,
                                              eventIDs: pick.eventIDs, label: "Fight sequence \(index + 1)")
            document.videoTrack.append(clip)
            cursor += clip.duration
        }

        let cardStart = cursor
        let cardLength = backdrop.upperBound - backdrop.lowerBound
        guard cardLength > 0.001 else { return document }
        var card: TimelineClip
        if let scene = input.backdropScene {
            card = makeClip(scene: scene, start: backdrop.lowerBound, end: backdrop.upperBound, at: cardStart)
        } else {
            card = TimelineClip()
            card.videoFile = input.fightVideo.path
            card.sourceStart = backdrop.lowerBound
            card.sourceEnd = backdrop.upperBound
            card.startTime = cardStart
            card.duration = cardLength
            card.wide = input.fightVideo.wide
        }
        card.captions = "none"
        card.effect = backdropEffect
        let cardProvenance = self.cardProvenance(input)
        var backdropProvenance = cardProvenance
        backdropProvenance.videoID = input.fightVideo.id
        backdropProvenance.sourceStart = backdrop.lowerBound
        backdropProvenance.sourceEnd = backdrop.upperBound
        card.provenance = backdropProvenance
        document.videoTrack.append(card)

        var overlay = TextOverlayItem(text: input.card.text, startTime: cardStart, endTime: cardStart + cardLength)
        overlay.design = "hero"
        overlay.kicker = input.card.kicker.isEmpty ? nil : input.card.kicker
        overlay.fontfamily = "Anton"
        overlay.fontsize = 64
        overlay.strokeColor = "black"
        overlay.strokeWidthEm = 0.05
        overlay.boxOpacity = 0
        overlay.xFrac = 0.5
        // A stat card binds to the backdrop's source time; when the backdrop
        // still repeats picked footage it would show on the fight clip too.
        let stat = plan.allowsStat ? input.stat : nil
        overlay.yFrac = stat == nil ? 0.45 : 0.25
        overlay.wFrac = 0.86
        overlay.hFrac = 0.16
        overlay.provenance = cardProvenance
        document.textOverlays.append(overlay)

        if var stat {
            // Stat cards bind to a source moment: the backdrop's first frame.
            stat.sourceVideoID = input.fightVideo.id
            stat.sourceTime = backdrop.lowerBound
            var item = TextOverlayItem(text: StrikeStatsCopy.text(stat), startTime: cardStart,
                                       endTime: cardStart + cardLength)
            item.stat = stat
            item.design = stat.kind?.rawValue
            item.yFrac = 0.6
            item.boxOpacity = 0.9
            item.provenance = cardProvenance
            document.textOverlays.append(item)
        }
        return document
    }

    /// The outcome record when there is one, else the research record.
    static func cardProvenance(_ input: Input) -> StoryProvenance {
        let label = input.research?.fightLabel.isEmpty == false ? input.research?.fightLabel : nil
        return StoryProvenance(kind: input.outcome == nil ? .research : .outcome,
                               videoID: input.fightVideo.id,
                               researchVideoID: input.research?.videoID, label: label)
    }

    /// Where the outcome card's backdrop comes from.
    struct BackdropPlan: Sendable, Equatable {
        var range: ClosedRange<Double>
        /// The backdrop is the last pick's tail: that pick's clip ends at
        /// `range.lowerBound` instead of its own end.
        var trimsLastPick = false
        /// False when the backdrop repeats picked footage (the last pick is
        /// too short to give up a tail), so a stat card bound to it would
        /// also show on the fight clip: the stat card is left out.
        var allowsStat = true
    }

    /// The fight-video range behind the outcome card: right after the
    /// sequence's last picked moment when that stretch is free, else the
    /// longest free stretch outside every pick. With no free stretch, the
    /// tail of the last pick, trimmed off that pick's clip when the pick is
    /// at least twice the card long; otherwise the tail overlaps the pick
    /// and the stat card is omitted. A range that overlaps a shown pick
    /// would show a stat card twice, since stat cards appear on every clip
    /// covering their source time.
    static func backdropPlan(fight: [FightPick], videoDuration: Double,
                             cardDuration: Double) -> BackdropPlan {
        let length = max(0.5, cardDuration)
        let picks = fight.map { ($0.start, max($0.start, $0.end)) }.sorted { $0.0 < $1.0 }
        let lastEnd = picks.map(\.1).max() ?? 0
        if videoDuration > 0 {
            var free: [(Double, Double)] = []
            var cursor = 0.0
            for (start, end) in picks {
                if start > cursor { free.append((cursor, start)) }
                cursor = max(cursor, end)
            }
            if videoDuration > cursor { free.append((cursor, videoDuration)) }
            if let after = free.first(where: { abs($0.0 - lastEnd) < 0.001 && $0.1 - $0.0 >= length - 0.001 }) {
                return BackdropPlan(range: after.0...(after.0 + length))
            }
            if let longest = free.filter({ $0.1 - $0.0 >= length - 0.001 }).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) {
                return BackdropPlan(range: longest.0...(longest.0 + length))
            }
        }
        guard let last = fight.last else { return BackdropPlan(range: 0...length) }
        let end = max(last.start, last.end)
        if end - last.start >= 2 * length - 0.001 {
            return BackdropPlan(range: (end - length)...end, trimsLastPick: true)
        }
        return BackdropPlan(range: max(last.start, end - length)...end, allowsStat: false)
    }

    /// The backdrop's source range (see `backdropPlan`).
    static func backdropRange(fight: [FightPick], videoDuration: Double,
                              cardDuration: Double) -> ClosedRange<Double> {
        backdropPlan(fight: fight, videoDuration: videoDuration, cardDuration: cardDuration).range
    }

    private static func makeClip(scene: SceneRecord, start: Double, end: Double, at time: Double) -> TimelineClip {
        var clip = TimelineClip()
        clip.sceneID = scene.id
        clip.videoFile = scene.videoPath
        clip.sourceStart = start
        clip.sourceEnd = end
        clip.startTime = time
        clip.duration = end - start
        clip.sceneFullDuration = (scene.duration * 10).rounded() / 10
        clip.wide = scene.wide
        clip.cropXFrac = scene.cropXFrac
        return clip
    }

    // MARK: - Card copy

    /// Copy from the outcome record (method, round, winner) and the research
    /// story's hook line, for when the AI copy is unavailable.
    static func fallbackCard(outcome: FightOutcome?, research: FightResearchRecord?, fightLabel: String,
                             names: [String: String] = [:]) -> StoryCardCopy {
        let event = [outcome?.event, research?.event]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let label = fightLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let kicker = (event ?? (label.isEmpty ? "Result" : label)).uppercased()
        let hook = hookLine(research)
        guard let outcome else {
            return StoryCardCopy(kicker: kicker, headline: hook ?? (label.isEmpty ? "Final result" : label))
        }
        let method = methodPhrase(outcome.method)
        let roundText = outcome.round.map { "Round \($0)" }
        let headline: String
        if let winner = outcome.winnerKey.flatMap({ names[$0] ?? displayName(key: $0) }),
           outcome.method != "draw", outcome.method != "no-contest" {
            let finish = [method, outcome.method == "decision" ? nil : roundText.map { "in \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
            headline = "\(winner) wins by \(finish)"
        } else {
            headline = [method, outcome.method == "decision" ? nil : roundText].compactMap { $0 }
                .joined(separator: " · ")
        }
        return StoryCardCopy(kicker: kicker, headline: headline, subline: hook)
    }

    static func methodPhrase(_ method: String) -> String {
        switch method.lowercased() {
        case "ko": "KO"
        case "tko": "TKO"
        case "submission": "submission"
        case "decision": "decision"
        case "draw": "Draw"
        case "no-contest": "No contest"
        default: method.isEmpty ? "Result" : method
        }
    }

    /// "jan-blachowicz" → "Jan Blachowicz" when no roster name is known.
    static func displayName(key: String) -> String? {
        let words = key.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func hookLine(_ research: FightResearchRecord?) -> String? {
        guard let story = research?.summary["story"] as? [String: Any],
              let hook = (story["hook_line"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hook.isEmpty else { return nil }
        return hook
    }

    /// Asks for the outcome card's copy as `{"kicker","headline","subline"}`.
    static func prompt(claimText: String, fightLabel: String, outcome: FightOutcome?,
                       research: FightResearchRecord?) -> String {
        var facts: [String] = []
        if !fightLabel.isEmpty { facts.append("Fight: \(fightLabel)") }
        if let outcome {
            var line = "Outcome: \(outcome.method)"
            if let winner = outcome.winnerKey { line += ", winner \(winner)" }
            if let loser = outcome.loserKey { line += ", loser \(loser)" }
            if let round = outcome.round { line += ", round \(round)" }
            if let event = outcome.event, !event.isEmpty { line += ", event \(event)" }
            facts.append(line)
        }
        if let research {
            if !research.event.isEmpty { facts.append("Event: \(research.event)") }
            if !research.fightDate.isEmpty { facts.append("Date: \(research.fightDate)") }
            if let story = research.summary["story"] as? [String: Any] {
                for key in ["angle", "arc", "hook_line"] {
                    if let value = story[key] as? String, !value.isEmpty { facts.append("Story \(key): \(value)") }
                }
            }
            if let sentiment = research.summary["sentiment"] as? String, !sentiment.isEmpty {
                facts.append("Fan sentiment: \(sentiment)")
            }
        }
        return """
            You write the closing card of a short fight video. The video opens with an interview claim, \
            shows the fight sequence, and ends on this card, which states what actually happened.

            Interview claim (verbatim transcript):
            "\(claimText)"

            Facts (use only these; do not invent results, rounds, or names):
            \(facts.isEmpty ? "(none)" : facts.map { "- " + $0 }.joined(separator: "\n"))

            Write:
            - kicker: 1 to 4 words, a label such as the event name.
            - headline: at most 7 words, the result, answering the claim.
            - subline: at most 10 words, optional context; empty string if none.

            Reply with JSON only: {"kicker": "...", "headline": "...", "subline": "..."}
            """
    }

    /// The card copy from a model reply; nil when the reply has no headline.
    static func parseCard(_ raw: String) -> StoryCardCopy? {
        guard let object = AIResponseParser.jsonObject(from: raw) else { return nil }
        func field(_ key: String) -> String {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let headline = field("headline")
        guard !headline.isEmpty else { return nil }
        let subline = field("subline")
        return StoryCardCopy(kicker: field("kicker"), headline: headline, subline: subline.isEmpty ? nil : subline)
    }
}
