import Foundation

/// Run-local slots travel between footage through presets and remembered settings.
nonisolated enum CaptionSpeakerOrder {
    /// Concatenate each selected video's evidence in source order (the wizard
    /// uses ascending video IDs). Keep that order, rather than interleaving
    /// timestamps from separate recordings: the first video's speakers go first.
    /// Explicit original-row attribution wins over automatic turns at that time.
    static func ordinals(turns: [SpeakerTurn], rows: [TranscriptRow], roster: [String]) -> [String: Int] {
        var videos: [Int64] = []
        for id in turns.map(\.videoID) where !videos.contains(id) { videos.append(id) }
        var rowVideos: [Int64] = []
        for id in rows.map(\.videoID) where !rowVideos.contains(id) { rowVideos.append(id) }
        // A recording with only manually attributed rows has no turn entry.
        // Insert it before the next recording in the concatenated row evidence.
        for (index, id) in rowVideos.enumerated() where !videos.contains(id) {
            let next = rowVideos.dropFirst(index + 1).first { videos.contains($0) }
            let insertion = next.flatMap { videos.firstIndex(of: $0) } ?? videos.count
            videos.insert(id, at: insertion)
        }
        var result: [String: Int] = [:]
        func append(_ key: String?) {
            if let key, result[key] == nil { result[key] = result.count + 1 }
        }
        for video in videos {
            let videoTurns = turns.filter { $0.videoID == video }.sorted {
                $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
            }
            let videoRows = rows.filter { $0.videoID == video && !$0.isTranslation }.sorted {
                $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
            }
            let times = Set(videoTurns.map(\.start) + videoRows.flatMap { [$0.startTime, $0.endTime] }).sorted()
            for time in times {
                // Visit row starts as well as turn starts so a manual attribution
                // inside a long automatic turn gets its own speaking-order slot.
                let moment = TranscriptSegment(start: time, end: time.nextUp, text: "")
                if let row = videoRows.first(where: { $0.startTime <= time && time < $0.endTime }),
                   case .person(let key) = row.speaker {
                    append(key)
                } else {
                    append(CaptionSpeakerColors.personKey(CaptionSpeakerColors.speakerKey(
                        for: moment, turns: videoTurns, rows: videoRows)))
                }
            }
        }
        for key in roster.sorted() { append(key) }
        return result
    }

    /// Use the selected source pool, even when a saved take uses only a subset
    /// of its videos. Otherwise dropping the first video's clips renumbers all
    /// remaining speakers between the settings preview and export.
    static func sourceVideoIDs(scenes: [SceneRecord], options: WizardOptions) -> [Int64] {
        var pool = scenes.filter { !$0.excluded && !$0.ignored }
        if options.sourcesRestricted { pool = pool.filter { options.includesCopiedSource($0) } }
        if !options.selectedRunIDs.isEmpty {
            pool = pool.filter { $0.runID.map(options.selectedRunIDs.contains) == true }
        }
        pool = SceneStacks.tops(pool, level: .from(options.stackLevel))
        if options.favoritesOnly { pool = pool.filter(\.favorite) }
        if !options.sourcePeople.isEmpty {
            let tags = Set(options.sourcePeople.map { "person:\($0)" })
            pool = pool.filter { !tags.isDisjoint(with: $0.tags) }
        }
        if options.formatPreset == ReelRecipe.podcast.id { pool = WizardEngine.podcastScenes(pool, log: { _ in }) }
        let positivelyRated = pool.filter { !($0.gradeCount > 0 && ($0.gradeAverage ?? 5) <= 2) }
        if !positivelyRated.isEmpty { pool = positivelyRated }
        return Set(pool.map(\.videoID)).sorted()
    }

    static func slot(_ ordinal: Int) -> String { "speaker\(ordinal)" }

    static func ordinal(slot: String) -> Int? {
        guard slot.hasPrefix("speaker"), let value = Int(slot.dropFirst("speaker".count)),
              value > 0, self.slot(value) == slot else { return nil }
        return value
    }

    static func position(forPerson key: String?, ordinals: [String: Int],
                         positions: [String: String]?, runPosition: String) -> String {
        guard let key, let ordinal = ordinals[key], let position = positions?[slot(ordinal)],
              ["bottom", "middle", "top"].contains(position) || CustomPosition.isCustom(position)
        else { return runPosition }
        return position
    }
}
