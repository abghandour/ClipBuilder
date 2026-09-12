import SwiftUI

struct GenerationFailureNotice: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let failure = store.wizardFailureMessage { failureCard(failure) }
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Label("Generation failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Report…") {
                    BugReporting.presentReport(title: "Generation failed", details: message)
                }
                .controlSize(.small)
                Button("Try Again") {
                    store.wizardFailureMessage = nil
                    store.retryWizard()
                }
                .controlSize(.small)
                Spacer()
                Button("Dismiss") {
                    store.wizardFailureMessage = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(Theme.cardPadding)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

}
