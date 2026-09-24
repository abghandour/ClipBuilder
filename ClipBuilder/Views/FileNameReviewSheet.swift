import SwiftUI

struct FileNameReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let suggestions: [RenameSuggestion]

    var body: some View {
        review(suggestions)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 440)
            .modalCloseButton { dismiss() }
    }

    @ViewBuilder
    private func review(_ suggestions: [RenameSuggestion]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(suggestions.count == 1
                         ? "Rename suggestion"
                         : "\(suggestions.count) rename suggestions")
                        .font(.headline)
                    if let provenance = suggestions.first?.provenance {
                        AIInfoButton(provenance: provenance, style: .full, role: "Named by")
                    }
                }
                Text("Edit any name, uncheck files you want to keep as they are, then Rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            RenameSuggestionEditor(suggestions: suggestions,
                                   onApplied: { store.jobs.markReviewed(jobID); dismiss() },
                                   onCancel: { dismiss() })
        }
    }

}
