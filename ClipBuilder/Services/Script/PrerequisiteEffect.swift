import Foundation

nonisolated enum BuilderPrerequisiteKind: String, Codable, Sendable, CaseIterable {
    case transcript, people, analysis

    var disclosure: String {
        switch self {
        case .transcript:
            "Transcription may replace matching language/translation rows, regenerate transcript features and silence, filler, false-start and noise proposals. Matching decisions are preserved."
        case .people:
            "People detection may replace this video's roster and detection provenance, and update shared identities."
        case .analysis:
            "Analysis creates another batch and may update classification, people, scenes and associated analysis data."
        }
    }
}

nonisolated enum PrerequisiteOutcome: Codable, Sendable, Equatable {
    case unavailable(reason: String)
    case running(jobID: String)
    case failed(reason: String)
    case completedEmpty
    case completedWithData(dataVersion: String)

    var isComplete: Bool {
        switch self {
        case .completedEmpty, .completedWithData: true
        default: false
        }
    }

    var summary: String {
        switch self {
        case .unavailable(let reason): "Unavailable: \(reason)"
        case .running(let id): "Running (\(id))"
        case .failed(let reason): "Failed: \(reason)"
        case .completedEmpty: "Completed with no data"
        case .completedWithData(let version): "Completed with data (\(version))"
        }
    }
}

/// Persistent Library effects are separate from TimelineDiff. They are never
/// rolled back by failed runs, Discard, timeline Undo, or persisted Revert.
nonisolated struct PrerequisiteEffect: Codable, Sendable, Equatable {
    var kind: BuilderPrerequisiteKind
    var videoID: Int64
    var scope: String
    var beforeCount: Int
    var afterCount: Int
    var summary: String
}

nonisolated struct PrerequisiteReport: Sendable, Equatable {
    var outcome: PrerequisiteOutcome
    var effects: [PrerequisiteEffect] = []
}

/// Private row fingerprints, never shown in logs (transcript/identity text can
/// be sensitive). Comparing values catches replacements with unchanged counts.
nonisolated struct PrerequisiteInventory: Sendable {
    var rows: [String: [String]] = [:]

    func effects(since before: Self, kind: BuilderPrerequisiteKind, videoID: Int64) -> [PrerequisiteEffect] {
        Set(rows.keys).union(before.rows.keys).sorted().compactMap { scope in
            let old = before.rows[scope] ?? []
            let new = rows[scope] ?? []
            guard old != new else { return nil }
            return PrerequisiteEffect(kind: kind, videoID: videoID, scope: scope,
                                      beforeCount: old.count, afterCount: new.count,
                                      summary: "\(scope): persistent rows changed (\(old.count) → \(new.count)).")
        }
    }
}
