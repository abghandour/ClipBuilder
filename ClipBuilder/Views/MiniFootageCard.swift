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
            ForEach(run.candidates) { candidate in
                candidateCard(candidate)
            }
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

    private func candidateCard(_ candidate: MiniWizardCandidate) -> some View {
        let selected = run.selectedSelectionID == candidate.id
        let plan = WizardSelectionRules.resolvedPlan(candidate.take.plan, scenes: store.scenes)
        return VStack(alignment: .leading, spacing: Theme.spaceM) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    selectButton(candidate, selected: selected)
                    Spacer(minLength: Theme.spaceS)
                    keepToggle(candidate)
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    selectButton(candidate, selected: selected)
                    keepToggle(candidate)
                }
            }
            Button {
                store.miniRun?.selectedSelectionID = candidate.id
            } label: {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.spaceS) {
                        ForEach(Array(candidate.take.plan.clips.enumerated()), id: \.offset) { _, clip in
                            if let path = candidate.take.plan.footage?.first(where: { $0.sceneID == clip.sceneID })?.videoPath {
                                VideoThumbnail(url: URL(fileURLWithPath: path), time: clip.start,
                                               cornerRadius: Theme.mediaRadius)
                                    .frame(width: 112, height: 63)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review \(candidate.selection.name)")
            FormCaption("\(WizardSelectionRules.duration(candidate.take.plan).formatted(.number.precision(.fractionLength(1)))) s · Take \(candidate.take.ordinal)")
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            FormCaption(candidate.take.plan.rationale)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                .help(candidate.take.plan.rationale)
            ViewThatFits(in: .horizontal) {
                HStack {
                    noteField(candidate).frame(minWidth: 160)
                    regenerateButton(candidate)
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    noteField(candidate)
                    regenerateButton(candidate)
                }
            }
            if selected {
                if let plan {
                    ProposedCutsEditor(plan: plan,
                        sceneMap: Dictionary(store.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })) { edited in
                        store.saveMiniCandidatePlan(edited, selectionID: candidate.id, takeID: candidate.take.id)
                    }
                    .id("\(candidate.take.id):\(store.scenesVersion)")
                    .frame(maxWidth: .infinity)
                    .frame(height: max(440, pageHeight - 320))
                    .padding(.horizontal, -Theme.spaceS)
                    .disabled(store.isWizardRunning)
                } else {
                    FormCaption("Footage changed. Regenerate this candidate to use the current analysis.", tone: .warning)
                }
            }
        }
        .padding(.vertical, Theme.spaceS)
    }

    private func selectButton(_ candidate: MiniWizardCandidate, selected: Bool) -> some View {
        Button {
            store.miniRun?.selectedSelectionID = candidate.id
        } label: {
            Label(candidate.take.plan.headline ?? candidate.selection.name,
                  systemImage: selected ? "play.circle.fill" : "play.circle")
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .font(.headline)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Review and trim this candidate")
    }

    private func keepToggle(_ candidate: MiniWizardCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { candidate.kept },
            set: { kept in
                guard store.miniRun?.batchID == run.batchID,
                      let index = store.miniRun?.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
                store.miniRun?.candidates[index].kept = kept
            })) {
                Text("Keep").lineLimit(1).fixedSize()
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .disabled(store.isWizardRunning)
            .accessibilityLabel("Keep \(candidate.selection.name)")
    }

    private func noteField(_ candidate: MiniWizardCandidate) -> some View {
        TextField("What should change?", text: Binding(
            get: { candidate.note },
            set: { note in
                guard store.miniRun?.batchID == run.batchID,
                      let index = store.miniRun?.candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
                store.miniRun?.candidates[index].note = note
            }))
            .textFieldStyle(.roundedBorder)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .disabled(store.isWizardRunning)
            .onSubmit { store.regenerateMiniCandidate(selectionID: candidate.id, note: candidate.note) }
            .accessibilityLabel("What should change in \(candidate.selection.name)?")
    }

    private func regenerateButton(_ candidate: MiniWizardCandidate) -> some View {
        Button {
            store.regenerateMiniCandidate(selectionID: candidate.id, note: candidate.note)
        } label: {
            Text("Regenerate").lineLimit(1).fixedSize()
        }
        .accessibilityLabel("Regenerate \(candidate.selection.name)")
        .disabled(store.isWizardRunning)
    }
}
