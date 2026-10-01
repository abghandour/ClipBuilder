import Foundation

nonisolated enum CriticExemplars {
    struct Candidate: Sendable, Hashable {
        var id: String
        var path: String
        var date: String
        var duration: Double
        var favorite = false
        var percentile: Int?
        var reference = false
        var batchID: String?
        var traits: ReelTraits?

        var tier: Int {
            if favorite && (percentile ?? 0) >= 75 { return 0 }
            if favorite { return 1 }
            if (percentile ?? 0) >= 75 { return 2 }
            return reference ? 3 : 4
        }
        var why: String {
            if favorite, let percentile, percentile >= 75 {
                return "starred + top \(max(1, 100 - percentile))% of account"
            }
            if favorite { return "starred" }
            return reference ? "studied account" : "top quartile"
        }
    }

    struct Exclusion: Sendable {
        var ids: Set<String> = []
        var batchIDs: Set<String> = []
        var paths: Set<String> = []

        func contains(_ row: Candidate) -> Bool {
            ids.contains(row.id) || paths.contains(row.path)
                || row.batchID.map { batchIDs.contains($0) } == true
        }
    }

    struct Selection: Sendable {
        var exemplars: [Candidate]
        var reason: String?
        var missingPaths: [String]
    }

    /// Pure policy: file availability is supplied by the caller, never read here.
    static func select(rows: [Candidate], excluding: Exclusion = .init(),
                       existingPaths: Set<String>, limit: Int = 6) -> Selection {
        var paths: Set<String> = []
        var ids: Set<String> = []
        var missing: Set<String> = []
        let ordered = rows.filter { $0.tier < 4 && !excluding.contains($0) }.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
        let eligible = ordered.filter { row in
            guard existingPaths.contains(row.path) else { missing.insert(row.path); return false }
            guard !paths.contains(row.path), !ids.contains(row.id) else { return false }
            paths.insert(row.path)
            ids.insert(row.id)
            return true
        }
        let pool = Array(eligible.prefix(max(0, limit)))
        let reason = pool.count < 2
            ? "Critic brief: \(pool.count) exemplar\(pool.count == 1 ? "" : "s"), need 2. Star a generated reel or import reference reels."
            : nil
        return Selection(exemplars: reason == nil ? pool : [], reason: reason, missingPaths: missing.sorted())
    }

    static func select(database: Database, profile: BrandProfile, excluding: Exclusion = .init(),
                       limit: Int = 6, emit: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Selection {
        // A Database is owned by one profile. Never mix pools across database handles.
        let rows = try await database.criticExemplarCandidates()
        let selection = try await AppJobWork.run {
            let existing = Set(rows.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path))
            return select(rows: rows, excluding: excluding, existingPaths: existing, limit: limit)
        }
        if !selection.missingPaths.isEmpty {
            emit("Critic brief: skipped \(selection.missingPaths.count) missing exemplar file(s).")
        }
        if let reason = selection.reason { emit(reason) }
        return selection
    }
}
