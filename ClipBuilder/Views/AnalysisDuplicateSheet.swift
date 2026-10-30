import SwiftUI

struct AnalysisDuplicateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let prompt: AnalysisDuplicatePrompt

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            Text("This video already has an up-to-date analysis with the same settings")
                .font(.headline)
            Text(prompt.video.filename).foregroundStyle(.secondary)
            Text(prompt.missingPasses.isEmpty ? "All requested passes are complete."
                 : "Missing passes: " + prompt.missingPasses.map { $0 == "fightScore" ? "fight score" : $0 }.joined(separator: ", "))
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run missing passes only") { run(.missingOnly) }
                    .disabled(prompt.missingPasses.isEmpty)
                Button("Run anyway") { run(.runAnyway) }.keyboardShortcut(.defaultAction)
            }
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .padding(Theme.spaceL)
        .frame(width: 620)
        .modalCloseButton { dismiss() }
    }

    private func run(_ policy: AnalysisDuplicatePolicy) {
        dismiss()
        store.pendingAnalysisDuplicate = nil
        store.analyze(videos: [prompt.video], capturedRequests: [prompt.video.id: prompt.request], duplicatePolicy: policy)
    }
}
