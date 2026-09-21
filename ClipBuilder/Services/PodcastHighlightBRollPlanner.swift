import Foundation

/// Source and timeline bounds are decided before touching a Builder document.
nonisolated enum PodcastHighlightBRollPlanner {
    struct Placement: Codable, Sendable {
        var firstSentence: Int
        var lastSentence: Int
        var source: String
        var reason: String

        enum CodingKeys: String, CodingKey {
            case firstSentence = "first_sentence", lastSentence = "last_sentence", source, reason
        }
    }

    struct Cut: Sendable, Equatable {
        enum Source: Sendable, Equatable { case reaction(tile: Int), scene(Int64) }
        var source: Source
        var sourceStart: Double
        var start: Double
        var duration: Double
        var reason: String
    }

    /// Where a reel may cut away to: other moments of its own recordings, and
    /// recordings that show one of its people or someone it names. Footage
    /// outside this pool is out of context on screen, however well it scores,
    /// so neither the model nor the deterministic planner is ever offered it.
    struct Sources: Sendable, Hashable {
        /// The moments the reel shows, by recording. Same-recording B-roll must
        /// come from a moment the viewer is not already watching.
        var shown: [Int64: [ClosedRange<Double>]] = [:]
        /// People in the reel: its roster, whoever speaks, and its source scenes' tags.
        var people: Set<String> = []
        /// People the reel names in its speech.
        var mentioned: Set<String> = []

        init(videoID: Int64, range: ClosedRange<Double>? = nil, people: Set<String> = [], mentioned: Set<String> = []) {
            shown = [videoID: range.map { [$0] } ?? []]
            self.people = people
            self.mentioned = mentioned
        }

        /// One pool for a reel cut from several recordings.
        init(merging sources: [Sources]) {
            for source in sources {
                shown.merge(source.shown) { $0 + $1 }
                people.formUnion(source.people)
                mentioned.formUnion(source.mentioned)
            }
            mentioned.subtract(people)
        }

        var recordings: Set<Int64> { Set(shown.keys) }
        var allPeople: Set<String> { people.union(mentioned) }

        /// The reel's people this scene is tagged with.
        func peopleShown(in scene: SceneRecord) -> [String] {
            scene.tags.compactMap { tag in
                guard tag.hasPrefix("person:") else { return nil }
                let key = String(tag.dropFirst("person:".count))
                return allPeople.contains(key) ? key : nil
            }.sorted()
        }

        func isOwnRecording(_ scene: SceneRecord) -> Bool { shown[scene.videoID] != nil }

        /// A scene from the reel's own recording is in context unless it is one
        /// of the moments already on screen or another stretch of the same
        /// conversation (the podcast's exchanges and chapters are the talk
        /// itself, not footage of it); any other scene must show one of the
        /// reel's people or someone the reel names.
        func allows(_ scene: SceneRecord) -> Bool {
            if let ranges = shown[scene.videoID] {
                return !scene.tags.contains("podcast")
                    && !ranges.contains { scene.startTime < $0.upperBound && scene.endTime > $0.lowerBound }
            }
            return !peopleShown(in: scene).isEmpty
        }

        /// The short reason the model sees next to each offered scene.
        func label(for scene: SceneRecord, names: [String: String]) -> String {
            let shown = peopleShown(in: scene).map { names[$0] ?? $0 }
            if isOwnRecording(scene) {
                return shown.isEmpty ? "same recording, another moment"
                    : "same recording, another moment, shows \(shown.joined(separator: ", "))"
            }
            return "shows \(shown.joined(separator: ", "))"
        }
    }

    /// Display names for keys, leaving out generic keys ("person-2") so a
    /// nameless person can never match ordinary words.
    static func personNames(_ people: [PersonRecord], roster: [VideoPersonRecord] = []) -> [String: String] {
        var names: [String: String] = [:]
        for person in people {
            if let name = person.name.isEmpty ? person.keyName : Optional(person.name) { names[person.key] = name }
        }
        for member in roster where names[member.key] == nil {
            if let name = member.name.isEmpty ? PersonRecord.keyName(member.key) : Optional(member.name) { names[member.key] = name }
        }
        return names
    }

    /// People whose full name, or a name of four letters or more, is spoken.
    static func mentionedPeople(in text: String, names: [String: String]) -> Set<String> {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        guard !words.isEmpty else { return [] }
        var keys: Set<String> = []
        for (key, name) in names {
            let tokens = name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
            guard !tokens.isEmpty else { continue }
            if tokens.allSatisfy(words.contains) || tokens.contains(where: { $0.count >= 4 && words.contains($0) }) {
                keys.insert(key)
            }
        }
        return keys
    }

    /// The pool for one span of one recording: its roster, whoever speaks in
    /// the range, the people its own scenes are tagged with, and the people
    /// it names in speech.
    static func sources(videoID: Int64, range: ClosedRange<Double>, speakerKeys: [String] = [],
                        turns: [SpeakerTurn], roster: [VideoPersonRecord], scenes: [SceneRecord],
                        segments: [TranscriptSegment], people: [PersonRecord] = []) -> Sources {
        var keys = Set(roster.map(\.key)).union(speakerKeys)
        keys.formUnion(turns.filter { $0.end > range.lowerBound && $0.start < range.upperBound }.compactMap(\.personKey))
        for scene in scenes where scene.videoID == videoID && scene.startTime < range.upperBound && scene.endTime > range.lowerBound {
            keys.formUnion(scene.tags.filter { $0.hasPrefix("person:") }.map { String($0.dropFirst("person:".count)) })
        }
        let text = segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }.map(\.text).joined(separator: " ")
        let mentioned = mentionedPeople(in: text, names: personNames(people, roster: roster)).subtracting(keys)
        return Sources(videoID: videoID, range: range, people: keys, mentioned: mentioned)
    }

    /// A one-line account of the pool for the log.
    static func describe(_ sources: Sources, offered: [SceneRecord], names: [String: String]) -> String {
        let own = offered.filter(sources.isOwnRecording).count
        let mentioned = sources.mentioned.sorted().map { names[$0] ?? $0 }
        return "\(offered.count) in-context scene(s) offered (\(own) from the reel's own recording, "
            + "\(offered.count - own) showing its people)"
            + (mentioned.isEmpty ? "." : "; named in the reel: \(mentioned.joined(separator: ", ")).")
    }

    /// Footage of the reel's people from other recordings ranks above other
    /// moments of its own recording; within each, the analyzer's score decides.
    private static func ranked(_ scenes: [SceneRecord], sources: Sources) -> [SceneRecord] {
        scenes.sorted {
            let a = $0.score.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let b = $1.score.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let ownA = sources.isOwnRecording($0), ownB = sources.isOwnRecording($1)
            if ownA != ownB { return ownB }
            return a == b ? $0.id < $1.id : a > b
        }
    }

    /// The exact offered scene pool is also used by validation, so invented,
    /// stale or out-of-context IDs cannot enter the timeline.
    static func offeredScenes(sources: Sources, scenes: [SceneRecord], instructions: String) -> [SceneRecord] {
        let hints = instructions.lowercased()
        guard !hints.contains("no external"), !hints.contains("only reactions") else { return [] }
        return Array(ranked(scenes.filter {
            sources.allows($0) && !$0.ignored && !$0.excluded
                && $0.startTime.isFinite && $0.startTime >= 0 && $0.endTime.isFinite && $0.duration > 0.2
        }, sources: sources).prefix(60))
    }

    /// Convert sentence-index suggestions to bounded, non-overlapping cuts.
    /// A two-second breathing space also prevents adjacent suggestions from
    /// joining into a cutaway longer than three seconds over someone's words.
    static func validated(placements: [Placement], candidate: HighlightCandidate,
                          sentences: [TranscriptSegment], sources: Sources, turns: [SpeakerTurn],
                          tiles: [PodcastTile], scenes: [SceneRecord], instructions: String = "") -> [Cut] {
        guard candidate.sourceStart.isFinite, candidate.sourceEnd.isFinite, candidate.duration > 0 else { return [] }
        let offered = offeredScenes(sources: sources, scenes: scenes, instructions: instructions)
        var remaining = candidate.duration * 0.4
        var cuts: [Cut] = []
        for placement in placements.sorted(by: { $0.firstSentence < $1.firstSentence }) {
            guard sentences.indices.contains(placement.firstSentence), sentences.indices.contains(placement.lastSentence),
                  placement.firstSentence <= placement.lastSentence else { continue }
            let rows = sentences[placement.firstSentence...placement.lastSentence]
            guard rows.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
                  zip(rows, rows.dropFirst()).allSatisfy({ $0.end <= $1.start }),
                  let first = rows.first, let last = rows.last,
                  first.start >= candidate.sourceStart + 2, first.start < candidate.sourceEnd else { continue }
            let start = first.start - candidate.sourceStart
            var duration = min(3, remaining, min(last.end, candidate.sourceEnd) - first.start)
            let source: Cut.Source
            let sourceStart: Double
            if placement.source.hasPrefix("scene:"),
               let id = Int64(placement.source.dropFirst(6)), let scene = offered.first(where: { $0.id == id }) {
                source = .scene(id)
                sourceStart = scene.startTime
                duration = min(duration, scene.duration)
            } else if placement.source.hasPrefix("reaction:"), !instructions.lowercased().contains("no reaction"),
                      let tile = tiles.first(where: { $0.personKey == String(placement.source.dropFirst(9)) }) {
                // A reaction must remain a listener for the entire cutaway.
                let overlapping = turns.filter { $0.start < first.start + duration && $0.end > first.start }
                guard !overlapping.isEmpty,
                      overlapping.allSatisfy({ CropRecipePlanner.tile(for: $0, tiles: tiles).map { $0 != tile.index } ?? false }) else { continue }
                source = .reaction(tile: tile.index)
                sourceStart = first.start
            } else { continue }
            guard duration > 0.2,
                  !cuts.contains(where: { start < $0.start + $0.duration + 2 && $0.start < start + duration + 2 }) else { continue }
            cuts.append(Cut(source: source, sourceStart: sourceStart, start: start, duration: duration, reason: placement.reason))
            remaining -= duration
        }
        return cuts
    }

    /// In-context scenes the deterministic planner may cut to: the pool above,
    /// at or above the highlight threshold.
    static func matchingScenes(sources: Sources, scenes: [SceneRecord], threshold: Double) -> [SceneRecord] {
        ranked(scenes.filter {
            sources.allows($0) && !$0.ignored && !$0.excluded && $0.duration > 0.2
                && ($0.score.map { $0.isFinite && $0 >= threshold } ?? false)
        }, sources: sources)
    }

    static func plan(candidate: HighlightCandidate, sources: Sources, turns: [SpeakerTurn],
                     segments: [TranscriptSegment], tiles: [PodcastTile], scenes: [SceneRecord], threshold: Double, instructions: String = "") -> [Cut] {
        let lower = candidate.sourceStart + 2, upper = candidate.sourceEnd
        guard upper > lower else { return [] }
        let hints = instructions.lowercased()
        let allowReactions = !hints.contains("no reaction")
        let otherScenes = hints.contains("no external") || hints.contains("only reactions") ? [] : matchingScenes(sources: sources, scenes: scenes, threshold: threshold)
        let activeTurns = turns.filter { $0.end > candidate.sourceStart && $0.start < upper }.sorted { $0.start < $1.start }
        let durations = Dictionary(grouping: activeTurns, by: SpeakerTurnCleanup.identity).mapValues {
            $0.reduce(0.0) { $0 + max(0, min($1.end, upper) - max($1.start, candidate.sourceStart)) }
        }
        let dominant = durations.keys.sorted().max { (durations[$0] ?? 0) < (durations[$1] ?? 0) }
        let boundaries = Set([lower, upper] + activeTurns.flatMap { [$0.start, $0.end] }
            + segments.flatMap { [$0.start, $0.end] }).filter { $0 >= lower && $0 <= upper }.sorted()
        var windows: [(start: Double, end: Double, priority: Int, turn: SpeakerTurn?)] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end - start > 0.2 {
            let mid = (start + end) / 2
            let turn = activeTurns.first { $0.start <= mid && mid < $0.end }
            let speaking = segments.contains { $0.start <= mid && mid < $0.end }
            let listener = turn.map { SpeakerTurnCleanup.identity($0) != dominant } ?? false
            windows.append((start, end, !speaking ? 0 : listener ? 1 : 2, turn))
        }
        windows.sort { $0.priority == $1.priority ? $0.start < $1.start : $0.priority < $1.priority }
        // Reserve the best windows first, then choose footage chronologically so
        // the earliest cutaway is a reaction whenever that window has one.
        var selected: [(start: Double, end: Double, priority: Int, turn: SpeakerTurn?)] = []
        for window in windows {
            let end = min(window.end, window.start + 3)
            guard !selected.contains(where: { window.start < $0.end + 2 && $0.start < end + 2 }) else { continue }
            selected.append((window.start, end, window.priority, window.turn))
        }
        var cuts: [Cut] = []
        var sceneIndex = 0
        var lastReactionTile: Int?
        var remaining = candidate.duration * 0.4
        for window in selected.sorted(by: { $0.start < $1.start }) {
            let start = window.start - candidate.sourceStart
            let duration = min(window.end - window.start, remaining)
            guard duration > 0.2 else { break }
            let reactionTurn = window.turn ?? activeTurns.last { $0.end <= window.start } ?? activeTurns.first
            let activeTile = reactionTurn.flatMap { CropRecipePlanner.tile(for: $0, tiles: tiles) }
            let reactions = !allowReactions ? [] : activeTile.map { active in tiles.filter { $0.index != active }.sorted { $0.index < $1.index } } ?? []
            let reaction = reactions.first { $0.index > (lastReactionTile ?? -1) } ?? reactions.first
            let reason = window.priority == 0 ? "Pause" : window.priority == 1 ? "Listener's turn" : "Brief reaction over speech"
            // Start with a reaction, then alternate related footage and listeners.
            let cut: Cut
            if !otherScenes.isEmpty && (reaction == nil || !cuts.count.isMultiple(of: 2)) {
                let scene = otherScenes[sceneIndex % otherScenes.count]
                sceneIndex += 1
                cut = Cut(source: .scene(scene.id), sourceStart: scene.startTime, start: start,
                          duration: min(duration, scene.duration), reason: reason + " · Related footage")
            } else if let reaction {
                lastReactionTile = reaction.index
                cut = Cut(source: .reaction(tile: reaction.index), sourceStart: window.start,
                          start: start, duration: duration, reason: reason)
            } else { continue }
            cuts.append(cut)
            remaining -= cut.duration
        }
        return cuts.sorted { $0.start < $1.start }
    }
}
