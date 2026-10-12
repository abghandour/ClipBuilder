import SwiftUI

struct FightStatsCoverageCell: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    @State private var outcomeCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AnalysisCoverage.fightMessage(videoID: video.id, passes: store.analysisPasses,
                                               legacyEvents: store.fightEvents[video.id] ?? []))
                .font(.caption).lineLimit(1)
                .help(AnalysisCoverage.fightMessage(videoID: video.id, passes: store.analysisPasses,
                                                    legacyEvents: store.fightEvents[video.id] ?? []))
            HStack(spacing: 4) {
                Button("Re-score v2") { store.scoreFightAction(video: video) }
                    .controlSize(.small).lineLimit(1).fixedSize()
                    .disabled(store.fightScoringInFlight.contains(video.id) || !video.isPresent)
                    .help("Score attempt sequences and outcomes. Progress and Stop appear in the status bar.")
                if outcomeCheck {
                    Label("check", systemImage: "exclamationmark.triangle")
                        .font(.caption).help("A completed submission does not match the saved fight outcome.")
                }
            }
        }
        .task(id: store.fightEvents[video.id]) {
            let outcomes = (try? await store.database?.fetchOutcomes()) ?? []
            outcomeCheck = StrikeStatsSummary.pairs(events: store.fightEvents[video.id] ?? [], outcomes: outcomes)
                .contains { $0.outcomeCheck }
        }
    }
}
