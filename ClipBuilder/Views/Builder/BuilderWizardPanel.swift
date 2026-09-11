import SwiftUI

struct BuilderWizardPanel: View {
    let model: WizardSheetModel
    let hide: () -> Void
    let discard: () -> Void
    @State private var confirmRevert = false
    let openPicker: (BuilderWizardPickerRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            BuilderWizardRequestHeader(model: model, hide: hide)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    BuilderWizardStatusBanner(model: model)
                    if model.phase == .found {
                        BuilderWizardFindResults(model: model, openPicker: {
                            guard let request = model.pickerRequest() else { return }
                            openPicker(request)
                        })
                    }
                    BuilderWizardResults(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Theme.spaceS) {
                Spacer()
                if model.beforeVersion != nil {
                    Button("Revert last run") { confirmRevert = true }
                        .disabled(model.busy)
                        .help("Restore the saved timeline from before the last applied Wizard run, including removing later manual edits.")
                }
                Button("Discard", action: discard)
                    .disabled(model.phase == .applying)
                    .help("Discard the preview and close the panel; saved Library work remains.")
                if model.failure == .commitInProgress {
                    Button("Retry Apply") { Task { await model.retryApply() } }
                        .buttonStyle(.borderedProminent)
                        .help("Retry committing the same preview after the other commit finishes.")
                } else if model.phase == .preview || model.phase == .applying {
                    Button("Apply") { Task { await model.apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canApply)
                        .help("Commit the complete preview as one undoable timeline edit.")
                }
            }
        }
        .controlSize(.small)
        .padding(Theme.spaceS)
        .confirmationDialog("Revert ‘\(model.beforeVersion?.request ?? "last Wizard run")’?", isPresented: $confirmRevert) {
            Button("Revert last run", role: .destructive) { Task { await model.revert() } }
                .help("Restore the saved before-version and remove later manual edits.")
            Button("Cancel", role: .cancel) {}
                .help("Keep the current timeline.")
        } message: {
            Text("Restores the timeline saved before this request. All later manual edits will be lost. Saved duration: \((try? model.beforeVersion?.document().contentEnd.timecode) ?? "unavailable").")
        }
    }
}
