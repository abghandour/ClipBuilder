import SwiftUI

/// The last step: the Generate, Preview and Edit buttons, pinned under the
/// preview, never collapsed, enabled while the reel has items, whatever
/// section is open. What Generate will make is `MiniGenerateSummary`, the
/// preview column's Summary tab.
struct MiniGeneratePanel: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let projectID: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.spaceS) {
                generateButton
                roughCutButton
                openInEditorButton
            }
            .padding(Theme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(store.isWizardRunning)
    }

    private var generateButton: some View {
        Button {
            store.generateMiniReel(settings: settings, flow: flow)
        } label: {
            Text(flow.generateButtonTitle(keptCount: store.miniReelItems.count)).lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.miniReelItems.isEmpty || store.isWizardBatchJobRunning(projectID: projectID))
    }

    /// The same reel as an editable Builder timeline, every setting applied.
    private var openInEditorButton: some View {
        Button {
            store.generateMiniReel(settings: settings, flow: flow, mode: .openInEditor)
        } label: {
            Label("Edit", systemImage: "hammer").lineLimit(1).fixedSize()
        }
        .disabled(store.miniReelItems.isEmpty || store.isWizardBatchJobRunning(projectID: projectID))
        .help("Edit: open this reel as a Builder timeline with every setting applied, without rendering it")
    }

    /// Preview, next to Generate: a small plain render of the same reel so
    /// framing and focus can be checked in motion before the final render.
    private var roughCutButton: some View {
        Button {
            store.generateMiniReel(settings: settings, flow: flow, mode: .roughCut)
        } label: {
            Text("Preview").lineLimit(1).fixedSize()
        }
        .disabled(store.miniReelItems.isEmpty || store.isWizardBatchJobRunning(projectID: projectID))
        .help("Preview: a quick small render of this reel to check framing and focus in motion, without \(WizardRoughCut.leftOut); nothing is saved")
    }

}

/// What Generate will make: the run summary card with the effective settings.
struct MiniGenerateSummary: View {
    @Environment(AppStore.self) private var store
    let settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let run: MiniWizardRun

    private var effectiveSettings: MiniWizardSettings {
        settings.effective(for: flow,
            introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
            outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) })
    }

    var body: some View {
        RunSummaryCard(
            summary: flow.runSummaryCard(candidates: run.candidates, exchangeCount: run.keptCount, settings: effectiveSettings,
                profilePlatforms: store.activeProfile.defaultRenderSettings.platformSafeArea.platforms,
                brollCount: MiniBRollRules.pieces(run).reduce(0) { $0 + $1.cuts.count },
                reelCount: store.miniReelItems.count),
            accessibilityText: flow.runSummary(candidates: run.candidates, exchangeCount: run.keptCount,
                                               settings: effectiveSettings, reelCount: store.miniReelItems.count))
    }
}

/// Start Over, in the preview column's top-right corner: back to an empty
/// Express page. Asks first when there is anything to lose.
struct MiniStartOverButton: View {
    @Environment(AppStore.self) private var store
    /// True when the page holds anything a fresh Express start would lose.
    let hasChanges: Bool
    /// Forget the source, footage and every setting and return to 1 Source.
    let startOver: () -> Void
    @State private var confirmStartOver = false

    var body: some View {
        Button {
            if hasChanges { confirmStartOver = true } else { startOver() }
        } label: {
            Label("Start Over", systemImage: "arrow.counterclockwise").lineLimit(1).fixedSize()
        }
        .disabled(store.isWizardRunning)
        .help("Start Over: clear the source, footage and every setting and go back to 1 Source")
        .confirmationDialog("Start over from Source?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The source, kept footage and every setting on this page go back to their defaults. Rendered videos and the highlight history are kept.")
        }
    }
}
