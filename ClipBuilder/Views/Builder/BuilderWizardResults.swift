import SwiftUI

struct BuilderWizardResults: View {
    let model: WizardSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
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
            if !model.agentEvents.isEmpty {
                GroupBox("Tool outcomes") {
                    Grid(alignment: .leading, horizontalSpacing: Theme.spaceS, verticalSpacing: Theme.spaceS) {
                        ForEach(model.agentEvents) { event in
                            GridRow(alignment: .top) {
                                Image(systemName: outcomeSymbol(event.outcome))
                                    .foregroundStyle(outcomeColor(event.outcome))
                                    .accessibilityLabel(event.outcome.rawValue)
                                Text(event.toolName ?? "run").fontWeight(.medium)
                                Text(event.message ?? event.outcome.rawValue)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                                Text("\(event.argumentBytes)/\(event.resultBytes) B · \(Int(event.duration * 1000)) ms")
                                    .monospaced().foregroundStyle(.secondary)
                                    .fixedSize()
                                    .gridColumnAlignment(.trailing)
                                    .help("\(event.argumentBytes) input bytes, \(event.resultBytes) output bytes. Request \(event.requestID ?? "none"). \(event.sanitizedArguments ?? "")")
                            }
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.agentSummary.isEmpty {
                GroupBox("Agent explanation") {
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Text(model.explanationText).textSelection(.enabled)
                        Text("This explanation is not evidence of success. Review tool outcomes and the diff.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func outcomeSymbol(_ outcome: BuilderRunEvent.Outcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle.fill"
        case .refused, .failed: "xmark.circle.fill"
        case .cancelled: "clock"
        }
    }

    private func outcomeColor(_ outcome: BuilderRunEvent.Outcome) -> Color {
        switch outcome {
        case .completed: .green
        case .refused, .failed: .red
        case .cancelled: .secondary
        }
    }
}
