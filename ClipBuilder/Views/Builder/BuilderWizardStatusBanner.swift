import SwiftUI

struct BuilderWizardStatusBanner: View {
    let model: WizardSheetModel

    private var tint: Color {
        if model.failure != nil { return .red }
        switch model.phase {
        case .refused, .unrecognised: return .red
        case .preview, .applied, .found, .completed: return .green
        case .discarded, .idle: return .secondary
        case .awaitingPrerequisites, .awaitingReply: return .orange
        case .running, .applying: return .accentColor
        }
    }

    private var symbol: String {
        if model.failure != nil { return "exclamationmark.triangle" }
        switch model.phase {
        case .refused, .unrecognised, .awaitingPrerequisites: return "exclamationmark.triangle"
        case .preview, .found, .completed: return "checkmark.circle"
        case .applied: return "checkmark.seal"
        case .discarded: return "xmark.circle"
        case .running, .applying: return "clock"
        case .awaitingReply: return "questionmark.bubble"
        case .idle: return "info.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spaceS) {
            if model.busy {
                ProgressView().controlSize(.small).accessibilityLabel("Work in progress")
            } else {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                Text(model.statusText).fontWeight(.medium)
                ForEach(Array(model.reasons.filter { $0 != model.statusText }.enumerated()), id: \.offset) { _, reason in
                    Text(reason).font(.callout)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.spaceM)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: Theme.mediaRadius))
        .accessibilityElement(children: .combine)
    }
}
