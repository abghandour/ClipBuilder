import SwiftUI

/// Inline review of a Mini batch; long work uses the shared Wizard status and Stop.
struct MiniFootageCard: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    let pageHeight: CGFloat
    @State private var showTranscript = false

    var body: some View {
        FormCaption(run.summary)
        if run.footageKind == .qa {
            qaReview
        } else {
            MiniHighlightReviewView(run: run)
                .id(run.batchID)
                .frame(maxWidth: .infinity)
                .frame(height: max(560, pageHeight - 220))
                .padding(.horizontal, -Theme.spaceS)
                .disabled(store.isWizardRunning)
        }
        Button {
            if run.footageKind == .qa { store.recordMiniQASelections() }
            else { store.miniRun?.requestedCard = .settings }
        } label: {
            Text("Video Generation Settings").lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .disabled(run.keptCount == 0 || store.isWizardRunning)
    }

    @ViewBuilder
    private var qaReview: some View {
        if let qa = run.qa, !qa.sections.isEmpty {
            // The view sizes its own columns to the card; no sideways scrolling.
            TranscriptQAView(video: run.video, sections: qa.sections, rows: qa.rows, labels: qa.labels,
                kept: Binding(
                    get: { store.miniRun?.batchID == run.batchID ? store.miniRun?.qa?.kept ?? [] : [] },
                    set: { kept in
                        guard store.miniRun?.batchID == run.batchID else { return }
                        store.miniRun?.qa?.kept = kept
                    }), preferredTranslationLanguage: store.activeProfile.captionLanguages.first) { scene, start, end in
                        store.setSceneEditRange(scene, start: start, end: end)
                    }
                .id(run.batchID)
                .frame(maxWidth: .infinity)
                .frame(height: max(560, pageHeight - 220))
                // Keep 644 pt for the columns even in a 700 pt detail pane:
                // 700 - 2 * spaceXL - 2 * spaceL + 2 * spaceS.
                .padding(.horizontal, -Theme.spaceS)
                .disabled(store.isWizardRunning)
        } else {
            FormCaption("No Q&A found in this video")
            Button { showTranscript = true } label: {
                Text("Open Transcript").lineLimit(1).fixedSize()
            }
            .disabled(store.isWizardRunning)
            .sheet(isPresented: $showTranscript) { TranscriptSheet(video: run.video) }
        }
    }
}
