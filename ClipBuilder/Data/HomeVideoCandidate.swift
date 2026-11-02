import Foundation

/// Profile-wide facts; these must not come from the active project's lists.
nonisolated struct HomeVideoCandidate: Identifiable, Sendable {
    var video: VideoRecord
    var hasScenes: Bool
    var hasTranscript: Bool
    var projectIDs: [Int64]
    var projectNames: [String]

    var id: Int64 { video.id }

    struct Facts: Sendable, Equatable {
        var hasScenes = false
        var hasTranscript = false
        var projectIDs: [Int64] = []
    }
}

nonisolated enum HomeVideoFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case analyzed = "Analyzed"
    case transcribed = "Transcribed"
    case unassigned = "Unassigned"

    var id: Self { self }

    static func apply(_ filter: Self, search: String, to candidates: [HomeVideoCandidate]) -> [HomeVideoCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { candidate in
            let matchesFilter = switch filter {
            case .all: true
            case .analyzed: candidate.hasScenes
            case .transcribed: candidate.hasTranscript
            case .unassigned: candidate.projectIDs.isEmpty
            }
            return matchesFilter && (query.isEmpty || candidate.video.filename.localizedStandardContains(query))
        }
    }
}
