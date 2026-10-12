import SwiftUI

/// Status cell for fight footage: a badge when scoring data exists (press to
/// show it in the inspector), the scoring state otherwise, and Re-score.
struct FightStatsCoverageCell: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    /// Selects the video and reveals the Fight Action section in the inspector.
    let onShowStats: () -> Void
    @State private var outcomeCheck = false

    private var events: [FightEventRecord] { store.fightEvents[video.id] ?? [] }
    private var message: String {
        AnalysisCoverage.fightMessage(videoID: video.id, passes: store.analysisPasses, legacyEvents: events)
    }

    var body: some View {
        HStack(spacing: 6) {
            if events.isEmpty {
                Text(message).font(.caption).lineLimit(1).fixedSize().foregroundStyle(.secondary).help(message)
            } else {
                Button {
                    onShowStats()
                } label: {
                    Label("\(FightScoreDigest.totalActions(events: events))", systemImage: "chart.bar.xaxis")
                        .font(.caption).lineLimit(1).fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Show fight stats")
                .help(([message] + FightScoreDigest.fighters(events: events).map { fighter in
                    FightScoreDigest.line(fighter, name: store.people.first { $0.key == fighter.key }?.displayName
                                          ?? (fighter.key.isEmpty ? "Unattributed" : fighter.key))
                }).joined(separator: "\n"))
            }
            Button("Re-score v2") { store.scoreFightAction(video: video) }
                .controlSize(.small).lineLimit(1).fixedSize()
                .disabled(store.fightScoringInFlight.contains(video.id) || !video.isPresent)
                .help("Score attempt sequences and outcomes. Progress and Stop appear in the status bar.")
            if outcomeCheck {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel("Outcome check")
                    .help("A completed submission does not match the saved fight outcome.")
            }
        }
        .task(id: store.fightEvents[video.id]) {
            let outcomes = (try? await store.database?.fetchOutcomes()) ?? []
            outcomeCheck = StrikeStatsSummary.pairs(events: events, outcomes: outcomes).contains { $0.outcomeCheck }
        }
    }
}
