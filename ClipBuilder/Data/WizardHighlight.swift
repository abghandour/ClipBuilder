import Foundation

/// Which wizard path produced a highlight-history row
/// (docs/Highlight-History-Plan.md). Stored by raw value; a row written by a
/// newer build keeps its string and reads as `nil` here.
nonisolated enum WizardHighlightFlow: String, Codable, CaseIterable, Sendable {
    case expressHighlights, expressQA, expressTranscript, expressFight
    case fullAutomatic, fullSelection

    init(footageKind: MiniWizardFlow.FootageKind) {
        switch footageKind {
        case .highlights: self = .expressHighlights
        case .qa: self = .expressQA
        case .transcript: self = .expressTranscript
        case .fightMetrics: self = .expressFight
        }
    }

    var isExpress: Bool {
        switch self {
        case .expressHighlights, .expressQA, .expressTranscript, .expressFight: true
        case .fullAutomatic, .fullSelection: false
        }
    }

    var footageKind: MiniWizardFlow.FootageKind? {
        switch self {
        case .expressHighlights: .highlights
        case .expressQA: .qa
        case .expressTranscript: .transcript
        case .expressFight: .fightMetrics
        case .fullAutomatic, .fullSelection: nil
        }
    }

    var label: String {
        switch self {
        case .expressHighlights: "Express highlights"
        case .expressQA: "Express Q&A"
        case .expressTranscript: "Express transcript"
        case .expressFight: "Express fight"
        case .fullAutomatic: "AI Wizard"
        case .fullSelection: "AI Wizard selection"
        }
    }
}

/// Footage identity that holds on every Mac: the source video's content hash
/// and the scene's source-time range. `sceneID` is the scene id on the Mac
/// that wrote the row, the key the row's local plan uses for this footage.
nonisolated struct HighlightFootageRef: Codable, Sendable, Hashable {
    var sceneID: Int64?
    var videoHash: String
    var start: Double
    var end: Double
}

/// One Express pick (transcript or fight) as it stood when the highlight was
/// made. `eventTimes` are the fight events' source times, not local ids.
nonisolated struct HighlightPickSnapshot: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case transcript, fight }
    var kind: Kind
    var videoHash: String
    var start: Double
    var end: Double
    var position: Int
    var eventTimes: [Double]?
}

/// Which provider and model each AI task was routed to. Credentials and
/// provider overrides are never copied.
nonisolated struct HighlightAIRouting: Codable, Sendable, Hashable {
    var tasks: [String: String]?
    var taskModels: [String: String]?

    init(tasks: [String: String]? = nil, taskModels: [String: String]? = nil) {
        self.tasks = tasks
        self.taskModels = taskModels
    }

    init(_ config: AIConfig) {
        tasks = config.tasks
        taskModels = config.taskModels
    }
}

/// `settings_json`: everything needed to generate the highlight again.
/// Every field but `options` is Optional so rows from older and newer builds
/// decode.
nonisolated struct WizardHighlightSettings: Codable, Sendable {
    var options: WizardOptions
    var mini: MiniWizardSettings?
    /// `MiniWizardFlow.Length` raw value.
    var length: String?
    /// `MiniWizardFlow.OutputMode` raw value.
    var outputMode: String?
    var picks: [HighlightPickSnapshot]?
    var qaKept: [HighlightFootageRef]?
    var aiRouting: HighlightAIRouting?
    var sourceProfile: String?
    /// The transcript set of the single source this was made on; nil for
    /// entries from before it was recorded and for several sources.
    var transcriptKey: String? = nil

    init(options: WizardOptions, mini: MiniWizardSettings? = nil, length: String? = nil,
         outputMode: String? = nil, picks: [HighlightPickSnapshot]? = nil,
         qaKept: [HighlightFootageRef]? = nil, aiRouting: HighlightAIRouting? = nil,
         sourceProfile: String? = nil) {
        self.options = options
        self.mini = mini
        self.length = length
        self.outputMode = outputMode
        self.picks = picks
        self.qaKept = qaKept
        self.aiRouting = aiRouting
        self.sourceProfile = sourceProfile
    }
}

/// One `wizard_highlights` row. JSON columns stay text here so the record is
/// Hashable and survives fields this build does not know; the typed views
/// decode on demand.
nonisolated struct WizardHighlightRecord: Identifiable, Codable, Sendable, Hashable {
    var id: Int64
    var projectID: Int64
    /// `WizardHighlightFlow` raw value.
    var flow: String
    var batchID: String?
    var parentID: Int64?
    /// Local-only links (never synced): this Mac's selection, take and render.
    var selectionID: Int64?
    var takeID: Int64?
    var generatedVideoID: Int64?
    var videoHashes: [String]?
    var footage: [HighlightFootageRef]?
    var settingsJSON: String?
    var planJSON: String?
    /// `[AIRole]` JSON: the models that answered.
    var provenanceJSON: String?
    var note: String?
    var author: String?
    var createdAt: String?

    var highlightFlow: WizardHighlightFlow? { WizardHighlightFlow(rawValue: flow) }

    var settings: WizardHighlightSettings? {
        settingsJSON.flatMap { try? JSONDecoder().decode(WizardHighlightSettings.self, from: Data($0.utf8)) }
    }

    var plan: WizardPlan? {
        planJSON.flatMap { try? JSONDecoder().decode(WizardPlan.self, from: Data($0.utf8)) }
    }

    var provenance: [AIRole] {
        provenanceJSON.flatMap { try? JSONDecoder().decode([AIRole].self, from: Data($0.utf8)) } ?? []
    }
}

/// What a capture point hands the database; the database adds the footage
/// snapshot from the plan's scenes and the video hashes.
nonisolated struct WizardHighlightDraft: Sendable {
    var projectID: Int64
    var flow: WizardHighlightFlow
    var batchID: String?
    var parentID: Int64?
    var selectionID: Int64?
    var takeID: Int64?
    var generatedVideoID: Int64?
    var settings: WizardHighlightSettings
    var plan: WizardPlan?
    var provenance: [AIRole] = []
    var note: String?
    var author: String?
}

/// Opening a highlight on this Mac: its plan with local scene ids, or the
/// hashes of the source videos this library lacks.
nonisolated struct WizardHighlightOpenResult: Sendable {
    var plan: WizardPlan?
    var missingVideoHashes: [String]
    /// `settings.qaKept` resolved to local scene ids, in order.
    var qaKeptSceneIDs: [Int64]
}

/// What a render's capture point knows before the reels exist; one history
/// row per rendered reel is written from it afterwards.
nonisolated struct WizardHighlightCapture: Sendable {
    var flow: WizardHighlightFlow
    var settings: WizardHighlightSettings
}
