import SwiftUI

struct BuilderWizardResults: View {
    let model: WizardSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            if !model.saveReplayMessage.isEmpty {
                Text(model.saveReplayMessage).font(.caption).textSelection(.enabled)
            }
            if model.offersSaveScript {
                ViewThatFits(in: .horizontal) {
                    HStack { savePrompt }
                    VStack(alignment: .leading) { savePrompt }
                }
            }
            if model.phase == .preview || model.phase == .applied {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Button("Save as script…") { Task { await model.saveReplay() } }
                        .disabled(model.replayExport.source == nil || model.verifyingReplay || model.savingReplay)
                        .help(model.replayExport.reason ?? "Save this verified replay as a reusable script in the current profile.")
                    if let reason = model.replayExport.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let diff = model.diff {
                GroupBox("Timeline changes") {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.prerequisiteDisclosures.isEmpty || !model.persistentEffects.isEmpty {
                GroupBox("Library work") {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        ForEach(model.prerequisiteDisclosures, id: \.self) { Text($0).textSelection(.enabled) }
                        if model.phase == .awaitingPrerequisites {
                            Text("Library changes are saved immediately and survive a failed run, Discard, Undo and Revert. Timeline changes still require Apply.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Confirm Library work", action: model.beginConfirmedPrerequisites)
                                .help("Run the disclosed prerequisites once for this program, then preview its timeline edits.")
                        }
                        if !model.persistentEffects.isEmpty {
                            Text("Already saved. Discard, Undo and Revert keep these changes.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(model.persistentEffects.enumerated()), id: \.offset) { _, effect in
                                Text("Video \(effect.videoID): \(effect.summary)").textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.agentSummary.isEmpty && model.phase != .awaitingReply {
                GroupBox("Agent explanation") {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Text(model.explanationText).textSelection(.enabled)
                        Text("This explanation is not evidence of success. Review the diff; each tool call is in the log.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var savePrompt: some View {
        Text("Save this as a reusable script?").font(.caption)
        Button("Save") { Task { await model.saveReplay() } }
            .disabled(model.savingReplay)
            .help("Save the verified script with a name based on your request.")
        Button("Not now", action: model.declineSaveScript)
            .help("Dismiss this suggestion for the current timeline revision.")
    }
}
