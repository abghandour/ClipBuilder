import Foundation

/// Unrated rows retain their list selection; a verdict only changes its own row.
nonisolated struct PodcastHighlightScreeningState: Equatable {
    enum Verdict: Sendable { case approved, rejected }
    let candidateIDs: [UUID]
    private(set) var position = 0
    private(set) var verdicts: [UUID: Verdict] = [:]

    var currentID: UUID? { candidateIDs.indices.contains(position) ? candidateIDs[position] : nil }
    var isComplete: Bool { position == candidateIDs.count }
    var approved: Set<UUID> { Set(verdicts.filter { $0.value == .approved }.map(\.key)) }
    var rejectedCount: Int { verdicts.values.filter { $0 == .rejected }.count }
    var unratedCount: Int { candidateIDs.count - verdicts.count }

    mutating func rate(_ verdict: Verdict) {
        guard let currentID else { return }
        verdicts[currentID] = verdict
        next()
    }

    mutating func previous() { position = max(0, position - 1) }
    mutating func next() { position = min(candidateIDs.count, position + 1) }
    mutating func restart() { position = 0 }

    func selectionOnStop(previous: Set<UUID>) -> Set<UUID> {
        previous.subtracting(verdicts.keys).union(approved).intersection(candidateIDs)
    }
}
