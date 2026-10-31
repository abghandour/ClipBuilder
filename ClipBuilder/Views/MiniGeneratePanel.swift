import SwiftUI

/// The last step: what Generate will make, and the button. Pinned under the
/// preview, never collapsed, shown once footage is kept. The summary scrolls
/// when the pane is squeezed; the button is the pane's footer and stays put.
struct MiniGeneratePanel: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let run: MiniWizardRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { summaryCard.padding(Theme.spaceM) }
            Divider()
            Button {
                store.generateMiniVideosRecordingPicks(settings: settings, flow: flow, batchID: run.batchID)
            } label: {
                Text(flow.generateButtonTitle(keptCount: run.keptCount)).lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(run.keptCount == 0)
            .padding(Theme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            summary: flow.runSummaryCard(candidates: run.candidates, exchangeCount: run.keptCount, settings: effectiveSettings,
                profilePlatforms: store.activeProfile.defaultRenderSettings.platformSafeArea.platforms,
                brollCount: MiniBRollRules.pieces(run).reduce(0) { $0 + $1.cuts.count }),
            accessibilityText: flow.runSummary(candidates: run.candidates, exchangeCount: run.keptCount, settings: effectiveSettings))
    }
}
