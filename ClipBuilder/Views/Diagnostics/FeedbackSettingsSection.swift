import BugReporterKit
import SwiftUI

struct FeedbackSettingsSection: View {
    @AppStorage("qa.toolbarButton") private var showsQAButton = false

    var body: some View {
        Section("Feedback") {
            Button("Report a Bug…") { BugReporting.presentReport() }
            Button("My Reports…") { MyReportsWindowPresenter.show() }
            Toggle("Show the QA button in the toolbar", isOn: $showsQAButton)
                #if DEBUG
                .disabled(true)
                #endif
            #if DEBUG
            Text("Always on in development builds")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
            Button("Reveal Log Folder") { BugReporting.revealLogFolder() }
            if BugReporting.isConfigured {
                // Reading the observable revision refreshes the UUID after reset.
                let _ = BugReporterPresenter.shared.identityRevision
                LabeledContent("Install ID", value: String(BugReporter.installID.uuidString.prefix(8)))
                Button("Reset identity") { BugReporter.resetIdentity() }
            } else {
                Text(BugReporting.unavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
