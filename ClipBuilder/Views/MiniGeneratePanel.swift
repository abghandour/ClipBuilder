import SwiftUI

/// The last step: what Generate will make, and the button. Its own panel
/// under the three cards, never collapsed, shown once footage is kept.
struct MiniGeneratePanel: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let run: MiniWizardRun

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            summaryCard
            Button {
                store.generateMiniVideosRecordingPicks(settings: settings, flow: flow, batchID: run.batchID)
            } label: {
                Text(flow.generateButtonTitle(keptCount: run.keptCount)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(run.keptCount == 0)
        }
        .disabled(store.isWizardRunning)
    }

    private var effectiveSettings: MiniWizardSettings {
        settings.effective(for: flow,
            introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
            outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) })
    }

    private var summaryCard: some View {
        RunSummaryCard(
            summary: flow.runSummaryCard(candidates: run.candidates, exchangeCount: run.keptCount, settings: effectiveSettings),
            accessibilityText: flow.runSummary(candidates: run.candidates, exchangeCount: run.keptCount, settings: effectiveSettings))
    }
}
