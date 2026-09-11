import SwiftUI

/// Observe the model at the window level even when the Builder is not visible.
struct WizardStatusInset: View {
    @Environment(AppStore.self) private var store
    @State private var dismissed = false
    @State private var showLog = false

    var body: some View {
        Group {
            if let model = store.builderWizard, model.hasStatus, !dismissed {
                VStack(spacing: 0) {
                    Divider()
                    BuilderWizardStatusBar(model: model, openLog: { showLog = true },
                                           dismiss: { dismissed = true })
                }
            }
        }
        .sheet(isPresented: $showLog) { BuilderWizardLogSheet() }
        .onChange(of: store.builderWizard.map { ObjectIdentifier($0) }) { _, _ in
            dismissed = false
            showLog = false
        }
        .onChange(of: store.builderWizard?.busy) { _, busy in
            if busy == true { dismissed = false }
        }
        .onChange(of: store.builderWizard?.identityMatches) { _, matches in
            if matches == false, let model = store.builderWizard, !model.identityMatches { model.dismiss() }
        }
    }
}
