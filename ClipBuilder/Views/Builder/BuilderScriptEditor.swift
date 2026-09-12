import SwiftUI

struct BuilderScriptEditor: View {
    @Bindable var model: ScriptLibraryModel
    let editing: Bool
    let run: () throws -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text(editing ? "Script editor" : "Run “\(model.header?.name ?? "script")”").font(.headline)
            if editing {
                TextEditor(text: $model.source)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .border(.separator)
                    .help("JavaScript source, including its authoritative clipbuilder-script JSON header.")
                    .onChange(of: model.source) { _, _ in model.parse() }
            } else {
                Text(model.header?.description ?? "").font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    if !(model.header?.params.isEmpty ?? true) {
                        Text(editing ? "Sample values for Validate and Run" : "Parameters").font(.subheadline)
                        BuilderScriptParameterForm(model: model)
                    }
                    if !model.message.isEmpty {
                        Text(model.message).font(.caption).textSelection(.enabled)
                    }
                    if let diagnostic = model.diagnostic {
                        Text("\(diagnostic.code) · line \(diagnostic.line ?? 1), column \(diagnostic.column ?? 1)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this sheet.")
                Spacer()
                if editing {
                    Button("Validate") { Task { await model.validate() } }
                        .disabled(model.busy || model.capture == nil)
                        .help("Validate in an isolated session with these sample values. Library work is never executed.")
                    Button("Save") { Task { do { try await model.save() } catch { model.fail(error) } } }
                        .disabled(model.busy || model.header == nil)
                        .help("Reparse the header and save this script in the current profile.")
                }
                Button("Run", action: startRun)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.capture == nil || model.header == nil)
                    .help("Validate parameters, then disclose any Library work before running a preview.")
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 420, idealWidth: 580, minHeight: editing ? 480 : 260)
    }

    private func startRun() {
        do { try run(); dismiss() }
        catch { model.fail(error) }
    }
}
