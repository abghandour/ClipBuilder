import AppKit
import SwiftUI

struct AIInfoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entries: [AIInfoEntry]
    @State private var selected = 0
    @State private var copying = false
    @State private var scopes = Set(AISettingsScope.allCases)
    @State private var copied = false
    @State private var replaceBuilder = false
    @State private var showingQuality = false
    private var entry: AIInfoEntry { entries[min(selected, entries.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI details").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if entries.count > 1 {
                Picker("Run", selection: $selected) {
                    ForEach(entries.indices, id: \.self) { Text(entries[$0].name).tag($0) }
                }
            } else {
                Text(entry.name)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Models").font(.headline)
                    ForEach(Array(entry.roles.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            ProviderLogo(brand: item.provenance.brand, size: 18)
                            VStack(alignment: .leading) {
                                Text(item.role).bold()
                                Text(item.provenance.shortLabel)
                                Text(
                                    item.provenance.at?.formatted(
                                        date: .abbreviated, time: .shortened)
                                        ?? "Date not recorded"
                                )
                                .foregroundStyle(.secondary)
                                if let took = item.provenance.durationLabel {
                                    Text("Took \(took)").foregroundStyle(.secondary)
                                        .help("Wall-clock time of the AI call, including any failover attempts.")
                                }
                                if let technique = item.provenance.technique {
                                    Text("Technique: \(technique)").foregroundStyle(.secondary)
                                }
                                if item.provenance.fellBack {
                                    Text("Fallback model").foregroundStyle(.secondary)
                                }
                            }
                        }.font(.caption)
                    }
                    Text("Settings").font(.headline)
                    if let settings = entry.settings {
                        if case .object(let prompts) = settings["modelPrompts"], !prompts.isEmpty {
                            DisclosureGroup("Prompt previews (informational)") {
                                ForEach(prompts.keys.sorted(), id: \.self) { key in
                                    if let prompt = AISettingsJSON.decode(
                                        AIPromptPreview.self, AISettingsJSON.encode(prompts[key]))
                                    {
                                        VStack(alignment: .leading) {
                                            Text(
                                                "\(key) · \(prompt.characterCount) characters\(prompt.truncated ? " (truncated)" : "")"
                                            )
                                            .font(.caption.bold())
                                            ScrollView {
                                                Text(prompt.preview).textSelection(.enabled)
                                            }.frame(maxHeight: 140)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach([AISettingsScope.prompts, .options, .sources], id: \.self) {
                            scope in
                            DisclosureGroup(scope.label) {
                                let keys = AISettingsEnvelope.keys(scope, kind: entry.kind).union(
                                    scope == .options ? ["builderDocumentJSON"] : [])
                                ForEach(settings.keys.filter(keys.contains).sorted(), id: \.self) {
                                    key in
                                    VStack(alignment: .leading) {
                                        Text(readable(key)).font(.caption.bold())
                                        let value = settings[key]!
                                        let text =
                                            value.string ?? AISettingsJSON.encode(value) ?? "—"
                                        ScrollView {
                                            Text(text).textSelection(.enabled).frame(
                                                maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 140)
                                        if scope == .prompts {
                                            Button("Copy") {
                                                AISettingsPasteboard.writeText(text)
                                            }
                                        }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    } else {
                        Text(AIInfoEntry.notRecorded).foregroundStyle(.secondary)
                    }
                    if entry.output?.qualityReport != nil {
                        Button("View quality report") { showingQuality = true }
                    }
                    if !entry.notes.isEmpty {
                        DisclosureGroup("Result notes") {
                            Text(entry.notes).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(copied ? "Copied" : "Copy Settings…") { copying.toggle() }.disabled(
                    entry.settings == nil
                )
                .popover(isPresented: $copying) {
                    VStack(alignment: .leading) {
                        Toggle(
                            "Everything",
                            isOn: Binding(
                                get: { scopes.count == AISettingsScope.allCases.count },
                                set: { scopes = $0 ? Set(AISettingsScope.allCases) : [] }))
                        ForEach(AISettingsScope.allCases, id: \.self) { scope in
                            Toggle(
                                scope.label,
                                isOn: Binding(
                                    get: { scopes.contains(scope) },
                                    set: {
                                        if $0 { scopes.insert(scope) } else { scopes.remove(scope) }
                                    }))
                        }
                        Button("Copy") {
                            guard let settings = entry.settings else { return }
                            AISettingsPasteboard.write(
                                AISettingsEnvelope(
                                    kind: entry.kind, sourceName: entry.name, scopes: scopes,
                                    settings: settings))
                            copying = false
                            copied = true
                        }.disabled(scopes.isEmpty)
                    }.padding().toggleStyle(.checkbox)
                }
                Spacer()
                if let output = entry.output {
                    Button("Open in Builder") {
                        if store.builder.document.videoTrack.isEmpty {
                            store.openInBuilder(output)
                            dismiss()
                        } else {
                            replaceBuilder = true
                        }
                    }
                }
            }
        }.padding(20).frame(width: 560, height: 620)
            .confirmationDialog(
                "Replace the current Builder timeline?", isPresented: $replaceBuilder
            ) {
                Button("Open in Builder", role: .destructive) {
                    if let output = entry.output {
                        store.openInBuilder(output)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingQuality) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.output?.qualityReport?.summary ?? "Quality report").font(.headline)
                    ScrollView { Text(entry.output?.qualityJSON ?? "").textSelection(.enabled) }
                    Button("Done") { showingQuality = false }
                }.padding().frame(width: 500, height: 450)
            }
            .task(id: copied) {
                guard copied else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    copied = false
                } catch {}
            }
    }
    private func readable(_ key: String) -> String {
        key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
}
