import SwiftUI

struct BuilderWizardStatusBar: View {
    let model: WizardSheetModel
    let openLog: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Theme.createTint)
                .accessibilityHidden(true)
            Text(model.statusText)
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(1)
            if let line = model.latestLogLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if model.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Wizard running")
            } else {
                Button("Dismiss", action: dismiss)
                    .controlSize(.small)
                    .help("Hide the Wizard status bar. The request, preview, and log are kept.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openLog)
        .accessibilityAction(named: Text("Open Wizard log")) { openLog() }
        .help("Double-click for the full Builder Wizard log, copy, and clear controls.")
    }
}
