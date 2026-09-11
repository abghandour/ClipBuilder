import SwiftUI

struct BuilderWizardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WizardSheetModel
    @State private var confirmRevert = false
    let openPicker: (BuilderWizardPickerRequest) -> Void

    init(store: AppStore, model: WizardSheetModel? = nil, openPicker: @escaping (BuilderWizardPickerRequest) -> Void) {
        _model = State(initialValue: model ?? WizardSheetModel(store: store))
        self.openPicker = openPicker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Builder Wizard").font(.headline)
            Text("Preview an editing request, review every change, then Apply.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("For example: " + (model.examples.first ?? "remove the selected clip"), text: $model.request, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disabled(model.busy)
                #if DEBUG
                .help("Enter one supported request using names and tags from this profile. Times are timeline positions. Debug builds also accept JSON arrays of script steps.")
                #else
                .help("Enter one supported request using names and tags from this profile. Times are timeline positions.")
                #endif
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                Text("Try one request").font(.caption).foregroundStyle(.secondary)
                ForEach(model.examples.prefix(4), id: \.self) { example in
                    Button(example) { model.request = example }
                        .buttonStyle(.link)
                        .disabled(model.busy || model.phase == .awaitingPrerequisites)
                        .help("Fill the request field with this example. Review it before running.")
                }
            }
            Picker("Provider", selection: $model.provider) {
                ForEach(BuilderAgentProvider.allCases) { provider in
                    Text(provider.label).tag(provider).disabled(provider.disabledReason != nil)
                }
            }
            .disabled(model.busy || model.phase == .awaitingPrerequisites)
            .onChange(of: model.provider) { _, _ in model.saveProviderPreference() }
            .help("Local works without a provider. Claude uses only Builder tools. Codex and Gemini await confinement and credential validation.")
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
            Text("B-roll chooses the first matching scene by ID; omit track to use the focused track. Clip numbers count visible clips on the track from left to right, including B-roll. ‘Cover all areas’ targets the selected B-roll clip.")
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
                        ForEach(model.examples, id: \.self) { example in
                            Button(example) { model.request = example }
                                .buttonStyle(.link)
                                .help("Use this supported request with the current timeline.")
                        }
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
                    if !model.agentEvents.isEmpty {
                        Text("Tool outcomes").font(.subheadline.weight(.semibold))
                        ForEach(model.agentEvents) { event in
                            Text("\(event.sequence). \(event.toolName ?? "run") · \(event.outcome.rawValue) · \(event.argumentBytes) B in / \(event.resultBytes) B out · \(Int(event.duration * 1000)) ms")
                                .font(.caption).monospacedDigit().textSelection(.enabled)
                                .help("Request \(event.requestID ?? "none"). \(event.sanitizedArguments ?? "")")
                        }
                    }
                    if !model.agentSummary.isEmpty {
                        Text("Agent explanation").font(.subheadline.weight(.semibold))
                        Text(model.agentSummary).textSelection(.enabled)
                        Text("This explanation is not evidence of success. Review tool outcomes and the diff.").font(.caption)
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
        .task { await model.refreshExamples(); await model.refreshBeforeVersion() }
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
