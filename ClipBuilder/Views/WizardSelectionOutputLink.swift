import SwiftUI

/// Outputs retain the exact take even when the selection's best changes later.
struct WizardSelectionOutputLink: View {
    @Environment(AppStore.self) private var store
    let takeID: Int64
    @State private var take: WizardSelectionTake?

    var body: some View {
        Group {
            if let take {
                Button("Take \(take.ordinal)", systemImage: "rectangle.stack") {
                    store.openWizardSelection(take.selectionID, takeID: take.id)
                }
                .buttonStyle(.link).font(.caption)
                .lineLimit(1).fixedSize()
                .disabled(store.isWizardRunning)
                .help("Open the selection this reel came from")
            }
        }
        .task(id: "\(store.profileGeneration):\(takeID)") {
            take = nil
            guard let database = store.database else { return }
            let saved = try? await database.wizardSelectionTake(id: takeID)
            guard !Task.isCancelled else { return }
            take = saved
        }
    }
}
