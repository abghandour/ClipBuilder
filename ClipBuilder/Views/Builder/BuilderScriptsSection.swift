import SwiftUI
import UniformTypeIdentifiers

struct BuilderScriptsSection: View {
    @Bindable var wizard: WizardSheetModel
    @Bindable var model: ScriptLibraryModel
    @State private var showingSheet = false
    @State private var editing = false
    @State private var opening = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Text("Scripts").font(.subheadline).fontWeight(.semibold)
                Spacer(minLength: 0)
                Button("Import", systemImage: "square.and.arrow.down", action: importScript)
                    .labelStyle(.iconOnly)
                    .help("Import a JavaScript file as a new script in this profile.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceS) { creationButtons }
                VStack(alignment: .leading, spacing: Theme.spaceS) { creationButtons }
            }
            if model.scripts.isEmpty {
                Text("Save reusable edits here. Every run previews changes before Apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.scripts) { script in
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Button { model.selectedID = script.id } label: {
                        VStack(alignment: .leading, spacing: Theme.spaceXS) {
                            Text(script.name).fontWeight(.medium)
                            Text(script.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(lastRun(script)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Select \(script.name). ⌘R opens its run parameters.")
                    HStack(spacing: Theme.spaceM) {
                        Button("Run…", systemImage: "play") { open(script, editing: false) }
                            .help("Run \(script.name) with parameters and a manual preview.")
                        Button("Edit", systemImage: "pencil") { open(script, editing: true) }
                            .help("Edit and validate \(script.name).")
                        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(script) } }
                            .help("Make a new copy of \(script.name).")
                        Button("Export", systemImage: "square.and.arrow.up") { exportScript(script) }
                            .help("Export \(script.name) with its header as a JavaScript file.")
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(script) } }
                            .help("Delete \(script.name) from this profile.")
                    }
                    .labelStyle(.iconOnly)
                }
                .padding(Theme.spaceS)
                .background(model.selectedID == script.id ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: .rect(cornerRadius: Theme.spaceXS))
            }
            if !model.message.isEmpty, !showingSheet {
                Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button("Run selected script") {
                if let selected = model.selected { open(selected, editing: false) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Run the selected script. ⌘R.")
            .hidden().frame(height: 0).accessibilityHidden(true)
        }
        .disabled(wizard.busy || wizard.phase == .awaitingPrerequisites || opening || !wizard.identityMatches)
        .task { await model.refresh() }
        .onChange(of: wizard.scriptRevision) { _, _ in model.invalidate() }
        .onChange(of: wizard.identityMatches) { _, matches in if !matches { model.invalidate() } }
        .sheet(isPresented: $wizard.showingAuthoredScript) {
            BuilderScriptEditor(model: model, editing: true, run: wizard.runLibraryScript)
        }
        .sheet(isPresented: $showingSheet) {
            BuilderScriptEditor(model: model, editing: editing, run: wizard.runLibraryScript)
        }
    }

    @ViewBuilder
    private var creationButtons: some View {
        Button("New Script", systemImage: "plus") { open(nil, editing: true) }
            .help("Create a reusable script in this profile.")
        Button("Write with AI…", systemImage: "sparkles", action: wizard.beginAuthoring)
            .help("Use the request field to write a script with an AI provider, then review it in the editor.")
    }

    private func lastRun(_ record: BuilderScriptRecord) -> String {
        guard let timestamp = record.lastRunAt, let date = try? Date(timestamp, strategy: .iso8601) else { return "Never run" }
        return "\(record.lastRunStatus ?? "Run") · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func open(_ script: BuilderScriptRecord?, editing: Bool) {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                let capture = try await wizard.captureForScript()
                model.open(script, capture: capture)
                model.selectedID = script?.id
                self.editing = editing; showingSheet = true
            } catch { model.fail(error) }
        }
    }

    private func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.importFile(url) }
        }
    }

    private func exportScript(_ script: BuilderScriptRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.javaScript]; panel.nameFieldStringValue = "Script.js"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.export(script, to: url) }
        }
    }
}
