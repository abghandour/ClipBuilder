import SwiftUI

struct GapReportReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let sections: [GapReporter.Section]
    let provenance: AIProvenance?

    var body: some View {
        report(sections)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 440)
            .modalCloseButton { dismiss() }
    }

    @ViewBuilder
    private func report(_ sections: [GapReporter.Section]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Content Gaps")
                    .font(.headline)
                if let provenance {
                    AIInfoButton(provenance: provenance, style: .full, role: "Written by")
                }
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.callout.bold())
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            }

            HStack {
                Button("Copy Report", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(GapReporter.plainText(sections),
                                                   forType: .string)
                }
                Spacer()
                Button("Done") { store.jobs.markReviewed(jobID); dismiss() }
                    .help("Close the report and clear it from the status bar")
                Button("Open AI Wizard") {
                    store.requestedSection = .wizard
                    store.jobs.markReviewed(jobID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Jump to the Wizard to act on the report")
            }
            .padding()
        }
    }

}
