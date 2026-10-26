import Foundation

/// Caption identities use the same roster naming as the transcript. Synthetic
/// dub voice keys are not people and must keep the run's caption choices.
nonisolated struct CaptionSpeakerEvidence: Sendable {
    var turns: [SpeakerTurn] = []
    var rows: [TranscriptRow] = []
    var roster: [VideoPersonRecord] = []

    var rosterKeys: [String] { roster.map(\.key) }
    var names: [String: String] {
        Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    @concurrent
    static func load(database: Database, videoID: Int64) async -> CaptionSpeakerEvidence {
        await load(database: database, videoID: videoID, transcriptionKey: nil)
    }

    /// The preview pins its turns to the transcription selected for its snapshot.
    @concurrent
    static func load(database: Database, videoID: Int64, transcriptionKey: String?) async -> CaptionSpeakerEvidence {
        let roster = (try? await database.fetchVideoPeople(videoID: videoID)) ?? []
        let turns = (try? await database.fetchSpeakerTurns(videoID: videoID, transcriptionKey: transcriptionKey)) ?? []
        let rows = (try? await database.fetchTranscripts(videoID: videoID)) ?? []
        let keys = Set(roster.map(\.key))
        let named = TranscriptSpeakers.named(turns, roster: roster).map { turn in
            var turn = turn
            if let key = turn.personKey, !keys.contains(key) { turn.personKey = nil }
            return turn
        }
        return CaptionSpeakerEvidence(turns: named, rows: rows, roster: roster)
    }

    /// Name each recording independently, then preserve the supplied source order.
    @concurrent
    static func load(database: Database, videoIDs: [Int64]) async -> CaptionSpeakerEvidence {
        var result = CaptionSpeakerEvidence()
        for videoID in videoIDs {
            let evidence = await load(database: database, videoID: videoID)
            result.turns += evidence.turns
            result.rows += evidence.rows
            result.roster += evidence.roster
        }
        return result
    }
}

/// One evidence load per video for a whole render: concurrent segment jobs
/// captioning the same recording share the first job's load.
actor CaptionSpeakerEvidenceMemo {
    private let database: Database
    private var loads: [Int64: Task<CaptionSpeakerEvidence, Never>] = [:]

    init(database: Database) {
        self.database = database
    }

    func evidence(videoID: Int64) async -> CaptionSpeakerEvidence {
        if let load = loads[videoID] { return await load.value }
        let database = database
        let load = Task { await CaptionSpeakerEvidence.load(database: database, videoID: videoID) }
        loads[videoID] = load
        return await load.value
    }
}
