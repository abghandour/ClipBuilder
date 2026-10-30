import SwiftUI

/// Review for a finished Text Look Wizard import: every created item with
/// its name ready to edit (first field focused, text selected), Save applies
/// the renames, Keep Names leaves the defaults.
struct TextLookNamesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let generation: Int
    let imported: TextLookImport

    @State private var names: [String] = []
    @State private var error: String?
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text(imported.items.count == 1 ? "Name the imported look" : "Name the imported looks")
                .font(.headline)
            Text("The wizard saved \(summary). Change any name, then Save.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.spaceM, verticalSpacing: Theme.spaceS) {
                ForEach(Array(imported.items.enumerated()), id: \.element.id) { index, item in
                    GridRow {
                        Text(item.kind.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        TextField("Name", text: binding(index))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: item.id)
                            .onSubmit(save)
                    }
                }
            }
            if !imported.missing.isEmpty {
                FormCaption("The model found no \(imported.missing.joined(separator: " or ")) in that file.", tone: .warning)
            }
            if let error { FormCaption(error, tone: .warning) }
            HStack {
                Spacer()
                Button("Keep Names") { store.jobs.markReviewed(jobID); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close and keep the names the wizard chose")
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    .help("Rename the imported looks")
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 440, idealWidth: 500)
        .modalCloseButton { dismiss() }
        .onAppear {
            names = imported.items.map(\.name)
            // Focus after the sheet is on screen: AppKit selects the whole
            // field when it becomes first responder, so the name is ready
            // to be typed over.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focused = imported.items.first?.id
            }
        }
    }

    private var summary: String {
        imported.items.map { "\($0.kind.label.lowercased()) “\($0.name)”" }.joined(separator: ", ")
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { index < names.count ? names[index] : "" },
                set: { if index < names.count { names[index] = $0 } })
    }

    private func save() {
        let items = zip(imported.items, names).map { item, name in
            var renamed = item
            renamed.name = name
            return renamed
        }
        if let failure = store.renameImportedTextLooks(items, generation: generation) {
            error = failure
            return
        }
        store.jobs.markReviewed(jobID)
        dismiss()
    }
}
