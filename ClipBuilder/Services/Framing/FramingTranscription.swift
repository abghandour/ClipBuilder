import Foundation

/// Which transcription's speaker turns speaker focus reads. Stored feeds
/// (`podcast_tiles_json`) are measured against one transcription's turns and
/// their tile indices. Pairing them with another transcription's turns, or
/// dropping them for feeds rebuilt from portraits, can point focus at the
/// wrong person, so focus reads the turns its feeds came from whenever that
/// set still has turns. Anything else falls back to the active transcription.
nonisolated enum FramingTranscription {
    static func key(tilesKey: String?, hasStoredFeeds: Bool, keysWithTurns: Set<String>,
                    activeKey: String?) -> String? {
        if let tilesKey, hasStoredFeeds, keysWithTurns.contains(tilesKey) { return tilesKey }
        return activeKey
    }

    /// The turns with the lines the user attributed by hand laid over them:
    /// a line set to a person becomes that person's turn for its span, and a
    /// line set to Unknown leaves a gap. The transcript shows these
    /// attributions, so focus must follow them too. An attributed turn
    /// borrows the tile and side the person's own turns were placed in, so
    /// unnamed feeds and side-by-side halves still resolve (a named tile
    /// wins anyway), and it joins neighbouring turns of the same person so a
    /// run of short corrected lines is not dropped as interjections.
    static func attributed(_ turns: [SpeakerTurn], rows: [TranscriptRow]) -> [SpeakerTurn] {
        let overrides = rows.filter { !$0.isTranslation && $0.speakerKey != nil && $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard !overrides.isEmpty else { return turns }
        var result: [(turn: SpeakerTurn, attributed: Bool)] = []
        for turn in turns {
            var pieces = [turn]
            for row in overrides where row.endTime > turn.start && row.startTime < turn.end {
                pieces = pieces.flatMap { piece -> [SpeakerTurn] in
                    guard row.endTime > piece.start, row.startTime < piece.end else { return [piece] }
                    var kept: [SpeakerTurn] = []
                    if row.startTime > piece.start { var head = piece; head.end = row.startTime; kept.append(head) }
                    if row.endTime < piece.end { var tail = piece; tail.start = row.endTime; kept.append(tail) }
                    return kept
                }
            }
            result += pieces.filter { $0.end > $0.start }.map { ($0, false) }
        }
        let videoID = turns.first?.videoID ?? overrides[0].videoID
        for row in overrides {
            guard case .person(let key) = row.speaker else { continue }
            var turn = placement(of: key, in: turns)
                ?? SpeakerTurn(videoID: videoID, start: 0, end: 0,
                               cluster: turns.max { overlap($0, row) < overlap($1, row) }?.cluster ?? 0, confidence: 1)
            turn.id = 0
            turn.start = row.startTime
            turn.end = row.endTime
            turn.confidence = 1
            turn.personKey = key
            result.append((turn, true))
        }
        result.sort { $0.turn.start == $1.turn.start ? $0.turn.end < $1.turn.end : $0.turn.start < $1.turn.start }
        var merged: [(turn: SpeakerTurn, attributed: Bool)] = []
        for entry in result {
            if let last = merged.last, last.attributed || entry.attributed,
               last.turn.personKey == entry.turn.personKey, last.turn.tile == entry.turn.tile,
               last.turn.resolvedSide == entry.turn.resolvedSide,
               entry.turn.start - last.turn.end <= joinGap {
                merged[merged.count - 1].turn.end = max(last.turn.end, entry.turn.end)
                merged[merged.count - 1].attributed = true
            } else {
                merged.append(entry)
            }
        }
        return merged.map(\.turn)
    }

    /// Lines closer than this belong to one turn.
    static let joinGap = 0.5

    /// Where the person's own turns put them: the cluster, tile and sides
    /// carrying most of their speech.
    private static func placement(of key: String, in turns: [SpeakerTurn]) -> SpeakerTurn? {
        struct Place: Hashable { var cluster: Int; var tile: Int?; var resolved: PodcastSpeakerSide; var picture: PodcastSpeakerSide }
        var weights: [Place: Double] = [:]
        var sample: [Place: SpeakerTurn] = [:]
        for turn in turns where turn.personKey == key {
            let place = Place(cluster: turn.cluster, tile: turn.tile, resolved: turn.resolvedSide, picture: turn.pictureSide)
            weights[place, default: 0] += turn.end - turn.start
            sample[place] = sample[place] ?? turn
        }
        return weights.max { $0.value == $1.value ? $0.key.cluster > $1.key.cluster : $0.value < $1.value }
            .flatMap { sample[$0.key] }
    }

    private static func overlap(_ turn: SpeakerTurn, _ row: TranscriptRow) -> Double {
        max(0, min(turn.end, row.endTime) - max(turn.start, row.startTime))
    }
}

/// A video record and the speaker turns speaker focus should pair with it.
nonisolated struct FramingEvidence: Sendable {
    var video: VideoRecord
    var turns: [SpeakerTurn]
    var transcriptionKey: String?
}
