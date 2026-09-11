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
            BuilderWizardRequestHeader(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    BuilderWizardStatusBanner(model: model)
                    if model.phase == .found {
                        BuilderWizardFindResults(model: model, openPicker: {
                            guard let request = model.pickerRequest() else { return }
                            openPicker(request)
                            dismiss()
                        })
                    }
                    BuilderWizardResults(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
