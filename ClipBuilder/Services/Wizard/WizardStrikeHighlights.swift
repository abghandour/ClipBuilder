import Foundation

/// Only source footage owns strike marks; decorations and cutaways never do.
nonisolated enum WizardStrikeHighlights {
    /// Tests replace only Vision; source selection, claims and snapshots stay real.
    @TaskLocal static var finder: StrikeHighlightMarker.Finder = StrikeHighlightMarker.find

    static func sourcePaths(in documents: [TimelineDocument]) -> Set<String> {
        Set(documents.flatMap { $0.videoTrack }
            .filter { $0.strikeHighlights == true }.compactMap(\.videoFile))
    }

    static func sources(for paths: Set<String>, videos: [VideoRecord]) -> [VideoRecord] {
        videos.filter { $0.type == .fight && paths.contains($0.url.path) }
    }

    nonisolated struct SavedStatus: Sendable, Equatable {
        var hasFightEvents: Bool
        var hasStrikes: Bool
        var hasSavedRows: Bool
    }

    static func missingMarksMessage(filename: String, status: SavedStatus?, readError: String? = nil) -> String {
        if let readError { return "Strike highlights: could not read saved highlights for \(filename) — \(readError)" }
        guard let status else { return "Strike highlights: could not check saved highlights for \(filename)" }
        if !status.hasFightEvents { return "Strike highlights: none saved for \(filename); score the fight first" }
        if status.hasSavedRows || !status.hasStrikes { return "Strike highlights: no drawable strike highlights saved for \(filename)" }
        return "Strike highlights: strikes are not marked yet for \(filename); use Sources → Mark strikes"
    }

    static func apply(to document: inout TimelineDocument, enabled: Bool?, style: String? = nil, sourceTypes: [String: VideoType]) {
        for index in document.videoTrack.indices {
            let clip = document.videoTrack[index]
            let fight = clip.videoFile.flatMap { sourceTypes[$0] } == .fight
            document.videoTrack[index].strikeHighlights = enabled == true && fight
                && !clip.bumper && !clip.isCutaway
                && !WizardEngine.isWizardCard(clip.videoFile ?? "") ? true : nil
            document.videoTrack[index].strikeHighlightStyle = document.videoTrack[index].strikeHighlights == true ? style : nil
        }
    }

    /// Current saved rows include negative matches. A failed pose read has no
    /// row, so it remains eligible next time. The database filters generations
    /// and rules versions before passing the saved rows here.
    static func missingStrikes(events: [FightEventRecord], saved: [StrikeHighlightRecord]) -> [FightEventRecord] {
        StrikeStatsSummary.deduplicatedStrikes(events).filter { strike in
            !saved.contains { $0.videoID == strike.videoID && $0.matches(time: strike.time, fighterKey: strike.fighterKey) }
        }
    }
}
