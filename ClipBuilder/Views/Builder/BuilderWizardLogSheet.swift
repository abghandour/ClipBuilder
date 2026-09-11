import SwiftUI

struct BuilderWizardLogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            if let model = store.builderWizard {
                HStack(spacing: Theme.spaceS) {
                    Text("Builder Wizard Log").font(.headline)
                    if model.busy {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Wizard running")
                    }
                    Spacer()
                    LogActions(lines: model.log, clear: model.clearLog)
                    Menu("Log", systemImage: "doc.on.clipboard") {
                        Button("Copy Tool Outcomes") { copy(model, kind: .toolOutcomes) }
                            .disabled(model.agentEvents.isEmpty)
                            .help("Copy structured tool outcomes, reasons, byte counts, and durations.")
                    }
                    .fixedSize()
                    .help("Copy structured details of the Wizard run.")
                    Button("Copy Everything") { copy(model, kind: .everything) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Copy the request, status, timeline changes, Library work, outcomes, explanation, and log. ⌘⇧C.")
                }
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.spaceXS) {
                            if model.log.isEmpty {
                                Text("No log entries.").foregroundStyle(.secondary)
                            }
                            ForEach(model.log.indices, id: \.self) { index in
                                Text(model.log[index])
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(Theme.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                    .onChange(of: model.log, initial: true) { _, log in
                        if !log.isEmpty { proxy.scrollTo(log.count - 1, anchor: .bottom) }
                    }
                }
            } else {
                Text("The Wizard run has been closed.").foregroundStyle(.secondary)
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 340, idealHeight: 460)
        .modalCloseButton { dismiss() }
    }

    private func copy(_ model: WizardSheetModel, kind: WizardSheetModel.CopyKind) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyText(kind: kind), forType: .string)
    }
}
