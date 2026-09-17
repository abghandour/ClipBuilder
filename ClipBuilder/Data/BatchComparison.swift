import Foundation

/// Two or more analyze batches of one video, side by side: what each found,
/// where they agree, and how the user's grades fall — the material for
/// deciding which batch to keep. Pure arithmetic over scenes already in
/// memory; no model call.
nonisolated struct BatchComparison: Sendable {
    struct Metrics: Sendable, Equatable {
        var runID: Int64
        var sceneCount = 0
        /// Share of the video's length that at least one scene covers.
        var coverage = 0.0
        var averageLength = 0.0
        var tagCount = 0
        var peopleCount = 0
        /// Mean entertainment score over the scenes that have one.
        var averageScore: Double?
        var favorites = 0
        /// Scenes only this batch found (no other batch has the moment).
        var uniqueCount = 0
        /// Scenes every compared batch found.
        var sharedCount = 0
        var gradedCount = 0
        var goodCount = 0

        /// Share of graded scenes graded good; nil until something is graded.
        var goodShare: Double? {
            gradedCount > 0 ? Double(goodCount) / Double(gradedCount) : nil
        }
    }

    /// One moment as the batches saw it: the members of a stack keyed by
    /// the batch that produced each.
    struct Moment: Sendable, Identifiable {
        var id: Int64 { members[0].id }
        var members: [SceneRecord]
        var runIDs: Set<Int64>
        var start: Double { members.map(\.startTime).min() ?? 0 }
        var end: Double { members.map(\.endTime).max() ?? 0 }
    }

    var runIDs: [Int64]
    var metrics: [Int64: Metrics]
    var moments: [Moment]

    /// Moments every batch found.
    var shared: [Moment] { moments.filter { $0.runIDs.count == runIDs.count } }
    /// Moments only one batch found, by that batch.
    func unique(to runID: Int64) -> [SceneRecord] {
        moments.filter { $0.runIDs == [runID] }.flatMap(\.members)
    }
    /// Every scene only one batch found, for blind grading.
    var allUnique: [SceneRecord] {
        moments.filter { $0.runIDs.count == 1 }.flatMap(\.members)
    }

    /// A grade of 3 or better is "good" (the screen grades 5 or 1).
    static let goodGrade = 3.0

    /// Which takes count as one moment. Matching is the comparison's own,
    /// not the grid's display choice: stacking Off would call every scene
    /// unique, and chapters must match their counterparts in other batches.
    static let matchLevel = SceneStackLevel.standard

    static func compare(runIDs: [Int64], scenes: [SceneRecord], duration: Double) -> BatchComparison {
        let considered = scenes
            .filter { scene in scene.runID.map(runIDs.contains) == true && !scene.ignored }
            .sorted { ($0.startTime, $0.endTime) < ($1.startTime, $1.endTime) }
        let moments = SceneStacks.group(considered, level: matchLevel, matchChapters: true).map { members in
            Moment(members: members, runIDs: Set(members.compactMap(\.runID)))
        }
        var metrics: [Int64: Metrics] = [:]
        for runID in runIDs {
            let own = considered.filter { $0.runID == runID }
            var m = Metrics(runID: runID)
            m.sceneCount = own.count
            m.coverage = duration > 0 ? coveredSeconds(own) / duration : 0
            m.averageLength = own.isEmpty ? 0 : own.reduce(0) { $0 + $1.duration } / Double(own.count)
            let tags = Set(own.flatMap(\.tags))
            m.tagCount = tags.filter { !$0.hasPrefix("person:") && !$0.hasPrefix("vip:") && $0 != "auto-hidden" }.count
            m.peopleCount = tags.filter { $0.hasPrefix("person:") }.count
            let scored = own.compactMap(\.score)
            m.averageScore = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
            m.favorites = own.count { $0.favorite }
            m.uniqueCount = moments.filter { $0.runIDs == [runID] }.reduce(0) { $0 + $1.members.count }
            m.sharedCount = moments.filter { $0.runIDs.count == runIDs.count }
                .reduce(0) { $0 + $1.members.count { $0.runID == runID } }
            let graded = own.filter { $0.gradeCount > 0 }
            m.gradedCount = graded.count
            m.goodCount = graded.count { ($0.gradeAverage ?? 0) >= goodGrade }
            metrics[runID] = m
        }
        return BatchComparison(runIDs: runIDs, metrics: metrics, moments: moments)
    }

    /// Seconds covered by the union of the scenes' ranges.
    static func coveredSeconds(_ scenes: [SceneRecord]) -> Double {
        var total = 0.0
        var currentStart: Double?
        var currentEnd = 0.0
        for scene in scenes.sorted(by: { $0.startTime < $1.startTime }) {
            if let start = currentStart, scene.startTime <= currentEnd {
                currentEnd = max(currentEnd, scene.endTime)
                _ = start
            } else {
                if let start = currentStart { total += currentEnd - start }
                currentStart = scene.startTime
                currentEnd = scene.endTime
            }
        }
        if let start = currentStart { total += currentEnd - start }
        return total
    }
}
