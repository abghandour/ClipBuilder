import SwiftUI

/// The last step: what Generate will make, and the button. Pinned under the
/// preview, never collapsed, shown once footage is kept. The summary scrolls
/// when the pane is squeezed; the button is the pane's footer and stays put.
struct MiniGeneratePanel: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let run: MiniWizardRun
    /// True when the page holds anything a fresh Express start would lose.
    let hasChanges: Bool
    /// Forget the source, footage and every setting and return to 1 Source.
    let startOver: () -> Void
    @State private var confirmStartOver = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { summaryCard.padding(Theme.spaceM) }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) {
                    generateButton
                    openInEditorButton
                    roughCutButton
                    Spacer(minLength: 0)
                    resetButton
                }
                HStack(spacing: Theme.spaceS) {
                    generateButton
                    openInEditorButton
                    roughCutButton
                    resetButton
                }
            }
            .padding(Theme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(store.isWizardRunning)
        .confirmationDialog("Start over from Source?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The source, kept footage and every setting on this page go back to their defaults. Rendered videos and the highlight history are kept.")
        }
    }

    /// Back to an empty Express page; asks first when there is anything to lose.
    private var resetButton: some View {
        Button {
            if hasChanges { confirmStartOver = true } else { startOver() }
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .labelStyle(.iconOnly)
        .help("Reset: clear the source, footage and every setting and start over from 1 Source")
    }

    private var generateButton: some View {
        Button {
            store.generateMiniVideosRecordingPicks(settings: settings, flow: flow, batchID: run.batchID)
        } label: {
            Text(flow.generateButtonTitle(keptCount: run.keptCount)).lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .disabled(run.keptCount == 0 || store.isWizardBatchJobRunning(projectID: run.projectID))
    }

    /// The same reel as an editable Builder timeline, every setting applied.
    private var openInEditorButton: some View {
        Button {
            store.generateMiniVideosRecordingPicks(settings: settings, flow: flow, batchID: run.batchID,
                                                   mode: .openInEditor)
        } label: {
            Label("Open in Editor", systemImage: "hammer")
        }
        .labelStyle(.iconOnly)
        .disabled(run.keptCount == 0 || store.isWizardBatchJobRunning(projectID: run.projectID))
        .help("Open in Editor: build this reel as a Builder timeline with every setting applied, without rendering it")
    }

    /// A small plain render of the same reel: framing and focus in motion,
    /// before the final render. The result opens in a player sheet.
    private var roughCutButton: some View {
        Button {
            store.generateMiniVideosRecordingPicks(settings: settings, flow: flow, batchID: run.batchID,
                                                   mode: .roughCut)
        } label: {
            Label("Rough cut", systemImage: "viewfinder")
        }
        .labelStyle(.iconOnly)
        .disabled(run.keptCount == 0 || store.isWizardBatchJobRunning(projectID: run.projectID))
        .help("Rough cut: a quick small render of this reel to check framing and focus in motion, without \(WizardRoughCut.leftOut); nothing is saved")
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
