import Foundation

/// Where an analysis of one video got to before it stopped — a Stop, a
/// crash, a dropped connection — so the next Analyze can carry on from
/// there instead of paying for every model call again. One row per video
/// in `analysis_checkpoints`, written as the run advances and deleted when
/// the video finishes. Everything a phase produced is kept verbatim, so a
/// resumed run lands the same scenes the uninterrupted one would have.
nonisolated struct AnalysisCheckpoint: Codable, Sendable, Equatable {
    var videoID: Int64
    var startedAt: Date
    var updatedAt: Date
    /// The analyze batch name the run was given, kept so the resumed run
    /// lands in the batch the user saw start.
    var runName: String
    /// The last stage the run reported ("mapping section 12 of 30").
    var stage: String = ""
    /// The last per-video progress fraction reported.
    var fraction: Double = 0
    /// What stopped the run, for the resume prompt; nil for a plain Stop.
    var lastError: String?
    /// The options the run started with — a resumed run keeps them.
    var plan: Plan
    /// The visual pass's finished pieces (non-podcast footage).
    var visual: VisualState?
    /// The podcast pass's finished pieces.
    var podcast: PodcastState?
    /// Set once the analyze batch is saved: the later stages only.
    var runID: Int64?
    var newPeople: [DetectedNewPerson] = []
    var suggestedFilename: String?
    var transcriptDone = false
    var fightScoringDone = false

    var percent: Int { Int((fraction * 100).rounded()) }

    /// The run's settings, as the dispatch plan handed them over.
    struct Plan: Codable, Sendable, Equatable {
        var instructions = ""
        var sampleInterval: Double?
        var detectPeople = true
        var autoZoomUnframed = false
        var breakdownTags: [String] = []
        var trimRange: [Double]?
        var requiredPeopleKeys: [String] = []
        var pastedNotes: [AnalysisRunNote]?
        var smartSampling = true
        var includeTranscript = false
        var includeFightScoring = true
        var provider: String?
        var model: String?
    }

    struct Range: Codable, Sendable, Equatable {
        var start: Double
        var end: Double

        init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
        init(_ range: (start: Double, end: Double)) { start = range.start; end = range.end }
        var tuple: (start: Double, end: Double) { (start, end) }

        func matches(_ other: (start: Double, end: Double)) -> Bool {
            abs(start - other.start) < 0.01 && abs(end - other.end) < 0.01
        }
    }

    struct Sequence: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var narrative: String
        var score: Double
    }

    struct Moment: Codable, Sendable, Equatable {
        var at: Double
        var note: String
        var dialog: String?
    }

    struct Person: Codable, Sendable, Equatable {
        var key: String
        var description: String
        var suggestedName: String?
        var correctedName: String?
        var firstSeen: Range
    }

    struct Outcome: Codable, Sendable, Equatable {
        var method: String
        var winner: String?
        var loser: String?
        var event: String?
        var round: Int?
    }

    /// The classic whole-video call's answer.
    struct Wide: Codable, Sendable, Equatable {
        var tags: [String: [Range]] = [:]
        var moments: [Moment] = []
        var sequences: [Sequence] = []
        var people: [Person] = []
        var outcome: Outcome?
        var suggestedFilename: String?
        var inferredType: String?
        /// The provider and model that actually answered.
        var provider: String?
        var model: String?
    }

    /// One Smart Sampling window's answer (coarse map or dense breakdown).
    struct WindowResult: Codable, Sendable, Equatable {
        var window: Range
        var tags: [String: [Range]] = [:]
        var sequences: [Sequence] = []
        var moments: [Moment] = []
        var activity = 0.0
    }

    struct VisualState: Codable, Sendable, Equatable {
        var wide: Wide?
        var coarse: [WindowResult] = []
        var dense: [WindowResult] = []

        func coarseResult(for window: (start: Double, end: Double)) -> WindowResult? {
            coarse.first { $0.window.matches(window) }
        }

        func denseResult(for window: (start: Double, end: Double)) -> WindowResult? {
            dense.first { $0.window.matches(window) }
        }
    }

    struct PodcastState: Codable, Sendable, Equatable {
        /// The people pass finished: the roster is in `video_people`.
        var peopleDone = false
        var newPeople: [DetectedNewPerson] = []
        var suggestedFilename: String?
        var exchanges: [PodcastExchange]?
        var exchangesProvider: String?
        var exchangesModel: String?
    }
}

// MARK: - Tuple bridges

/// The analyzer works in tuples; the checkpoint stores the same values.
nonisolated extension AnalysisCheckpoint.Range {
    static func encode(_ ranges: [String: [(start: Double, end: Double)]]) -> [String: [AnalysisCheckpoint.Range]] {
        ranges.mapValues { $0.map(AnalysisCheckpoint.Range.init) }
    }

    static func decode(_ ranges: [String: [AnalysisCheckpoint.Range]]) -> [String: [(start: Double, end: Double)]] {
        ranges.mapValues { $0.map(\.tuple) }
    }
}

nonisolated extension AnalysisCheckpoint.Sequence {
    init(_ sequence: (start: Double, end: Double, narrative: String, score: Double)) {
        self.init(start: sequence.start, end: sequence.end, narrative: sequence.narrative, score: sequence.score)
    }
    var tuple: (start: Double, end: Double, narrative: String, score: Double) { (start, end, narrative, score) }
}

nonisolated extension AnalysisCheckpoint.Moment {
    init(_ moment: (at: Double, note: String, dialog: String?)) {
        self.init(at: moment.at, note: moment.note, dialog: moment.dialog)
    }
    var tuple: (at: Double, note: String, dialog: String?) { (at, note, dialog) }
}

/// What the analyzer is handed to pick up an interrupted visual pass and
/// to report every finished piece as it lands.
nonisolated struct AnalysisCheckpointing: Sendable {
    var resume: AnalysisCheckpoint.VisualState?
    var save: @Sendable (AnalysisCheckpoint.VisualState) async -> Void
}

/// The podcast pass's counterpart.
nonisolated struct PodcastCheckpointing: Sendable {
    var resume: AnalysisCheckpoint.PodcastState?
    var save: @Sendable (AnalysisCheckpoint.PodcastState) async -> Void
}

/// Serializes checkpoint updates from parallel windows: each mutation is
/// applied and written before the next, so a later save never overwrites
/// an earlier one with an older snapshot.
actor AnalysisCheckpointRecorder<State: Sendable> {
    private(set) var state: State
    private let save: @Sendable (State) async -> Void

    init(state: State, save: @escaping @Sendable (State) async -> Void) {
        self.state = state
        self.save = save
    }

    func record(_ mutate: @Sendable (inout State) -> Void) async {
        mutate(&state)
        await save(state)
    }
}
