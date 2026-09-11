import SwiftUI

struct BuilderWizardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WizardSheetModel
    @State private var confirmRevert = false
    let openPicker: (BuilderTimelineModel.BRollRequest) -> Void

    init(store: AppStore, openPicker: @escaping (BuilderTimelineModel.BRollRequest) -> Void) {
        _model = State(initialValue: WizardSheetModel(store: store))
        self.openPicker = openPicker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Builder Wizard").font(.headline)
            Text("Preview a local editing request, review every change, then Apply.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("For example: remove clips with Alex", text: $model.request, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                #if DEBUG
                .help("Enter one supported request using names and tags from this profile. Times are timeline positions. Debug builds also accept JSON arrays of script steps.")
                #else
                .help("Enter one supported request using names and tags from this profile. Times are timeline positions.")
                #endif
            HStack(spacing: Theme.spaceM) {
                Menu("Recent Requests") {
                    ForEach(model.history, id: \.self) { request in
                        Button(request) { model.request = request }
                            .help("Use this request again against the current timeline.")
                    }
                }
                .disabled(model.history.isEmpty || model.busy)
                .help("The last ten distinct requests for this profile.")
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.phase == .running {
                    Button("Cancel run", action: model.cancelRun)
                        .help("Cancel and wait for active work to stop. No timeline changes are applied; saved Library work remains.")
                }
                Button(model.failure == .staleRevision ? "Run again" : "Run", action: model.beginRun)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run against a fresh timeline snapshot. ⌘Return. Replaces the previous preview.")
            }
            Text("B-roll chooses the first matching scene by ID; omit track to use the focused track. ‘Cover all areas’ targets the selected B-roll clip.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    if let message = model.failureMessage {
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(Array(model.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.phase == .unrecognised || model.phase == .idle {
                        Text("Supported requests").font(.subheadline.weight(.semibold))
                        ForEach(BuilderRequestParser.supportedRequests, id: \.self) { Text($0).font(.caption) }
                    }
                    if model.phase == .found {
                        BuilderWizardFindResults(model: model, openPicker: {
                            guard let request = model.pickerRequest() else { return }
                            openPicker(request)
                            dismiss()
                        })
                    }
                    if model.phase == .awaitingPrerequisites {
                        Text("Confirm Library work").font(.subheadline.weight(.semibold))
                        ForEach(model.prerequisiteDisclosures, id: \.self) { Text($0).textSelection(.enabled) }
                        Text("Library changes are saved immediately and survive a failed run, Discard, Undo and Revert. Timeline changes still require Apply.")
                            .font(.caption)
                        Button("Confirm Library work", action: model.beginConfirmedPrerequisites)
                            .help("Run the disclosed prerequisites once for this program, then preview its timeline edits.")
                    }
                    if !model.persistentEffects.isEmpty {
                        Text("Persistent Library effects").font(.subheadline.weight(.semibold))
                        Text("Already saved. Discard, Undo and Revert keep these changes.").font(.caption)
                        ForEach(Array(model.persistentEffects.enumerated()), id: \.offset) { _, effect in
                            Text("Video \(effect.videoID): \(effect.summary)").textSelection(.enabled)
                        }
                    }
                    if let diff = model.diff {
                        Text("Timeline changes").font(.subheadline.weight(.semibold))
                        ForEach(Array(model.diffLines.enumerated()), id: \.offset) { _, line in
                            Text(line).textSelection(.enabled)
                        }
                        DisclosureGroup("All changed fields (\(diff.changes.count))") {
                            ForEach(Array(diff.changes.enumerated()), id: \.offset) { _, change in
                                Text(BuilderWizardDiff.detail(change))
                                    .font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .help("Inspect all document changes, including indirect layout, framing, and lane changes.")
                    }
                    if !model.log.isEmpty {
                        Divider()
                        Text("Run log").font(.subheadline.weight(.semibold))
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            Divider()
            HStack(spacing: Theme.spaceM) {
                if model.beforeVersion != nil {
                    Button("Revert last run") { confirmRevert = true }
                        .disabled(model.busy)
                        .help("Restore the saved timeline from before the last applied Wizard run, including removing later manual edits.")
                }
                Spacer()
                Button(model.phase == .applied ? "Close" : "Discard") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .applying)
                    .help("Close and discard any unapplied preview; saved Library work remains. Escape.")
                if model.failure == .commitInProgress {
                    Button("Retry Apply") { Task { await model.retryApply() } }
                        .help("Retry committing the same preview after the other commit finishes.")
                } else if model.phase == .preview || model.phase == .applying {
                    Button("Apply") { Task { await model.apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canApply)
                        .help("Commit the complete preview as one undoable timeline edit.")
                }
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 620, idealHeight: 720)
        .interactiveDismissDisabled(model.phase == .applying)
        .task { await model.refreshBeforeVersion() }
        .onChange(of: model.identityMatches) { _, matches in if !matches { close() } }
        .onDisappear { model.dismiss() }
        .confirmationDialog("Revert ‘\(model.beforeVersion?.request ?? "last Wizard run")’?", isPresented: $confirmRevert) {
            Button("Revert last run", role: .destructive) { Task { await model.revert() } }
                .help("Restore the saved before-version and remove later manual edits.")
            Button("Cancel", role: .cancel) {}
                .help("Keep the current timeline.")
        } message: {
            Text("Restores the timeline saved before this request. All later manual edits will be lost. Saved duration: \((try? model.beforeVersion?.document().contentEnd.timecode) ?? "unavailable").")
        }
    }

    private func close() { model.dismiss(); dismiss() }
}
