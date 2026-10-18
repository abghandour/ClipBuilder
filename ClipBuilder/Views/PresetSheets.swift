import SwiftUI

enum PresetSheet: String, Identifiable {
    case save, load
    var id: String { rawValue }
}

/// Name and save a set of answers. The name defaults to the last preset
/// used, so repeated saves update the same entry. Shared by Express and the
/// AI Wizard; the caller supplies the list, the persistence and the preset.
struct PresetSaveSheet<P: NamedPreset>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let lastUsed: String?
    let presets: () -> [P]
    /// Build the preset to store under the cleaned name.
    let make: (String) -> P
    /// Persist the new list; false when the profile changed underneath.
    let persist: ([P]) -> Bool
    var onSaved: (P) -> Void = { _ in }

    @State private var name = ""
    @State private var existing: [P] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if !existing.isEmpty {
                FormCaption(replaces
                    ? "Replaces the saved settings named “\(NamedPresets.cleaned(name))”."
                    : "Saved: " + existing.map(\.name).joined(separator: ", "))
                    .lineLimit(2)
            }
            if let error { FormCaption(error, tone: .warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replaces ? "Replace" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(NamedPresets.cleaned(name).isEmpty)
            }
        }
        .padding(Theme.spaceXL)
        .frame(width: 380)
        .onAppear {
            existing = presets()
            name = NamedPresets.suggestedName(lastUsed: lastUsed, presets: existing)
        }
    }

    private var replaces: Bool { NamedPresets.preset(named: name, in: existing) != nil }

    private func save() {
        let cleaned = NamedPresets.cleaned(name)
        guard !cleaned.isEmpty else { return }
        // Against the live collection, not the snapshot taken when the sheet
        // opened: a teammate's preset that synced in meanwhile must survive.
        let preset = make(cleaned)
        guard persist(NamedPresets.upsert(preset, into: presets())) else {
            error = "The profile changed; reopen Save to try again."
            return
        }
        onSaved(preset)
        dismiss()
    }
}

/// Pick a saved preset to load; rename or delete entries in place.
struct PresetLoadSheet<P: NamedPreset>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let lastUsed: String?
    let presets: () -> [P]
    let persist: ([P]) -> Bool
    let summary: (P) -> String
    let onLoad: (P) -> Void
    /// A rename of the tracked preset: (old name, new name). nil new name = deleted.
    var onRenamed: (String, String?) -> Void = { _, _ in }
    /// Presets saved on the other wizard page, converted; load only.
    var imports: (label: String, presets: [P])? = nil

    @State private var list: [P] = []
    @State private var selection: P.ID?
    @State private var renaming: P.ID?
    @State private var renameText = ""
    @State private var error: String?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text(title).font(.headline)
            if list.isEmpty, imports?.presets.isEmpty != false {
                FormCaption("No saved settings yet. Use Save… on the Settings card to keep a set.")
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                List(selection: $selection) {
                    ForEach(list) { preset in
                        row(preset)
                            .tag(preset.id)
                            .contextMenu {
                                Button("Load") { load(preset) }
                                Button("Rename…") { beginRename(preset) }
                                Button("Delete", role: .destructive) { delete(preset) }
                            }
                    }
                    if let imports, !imports.presets.isEmpty {
                        Section(imports.label) {
                            ForEach(imports.presets) { preset in
                                importedRow(preset)
                                    .tag(preset.id)
                                    .contextMenu { Button("Load") { load(preset) } }
                            }
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 320)
                FormCaption(imports?.presets.isEmpty == false
                    ? "Double-click to load. Each row has Rename and Delete; the other page's presets load here and save as a copy."
                    : "Double-click to load. Each row has Rename and Delete.")
            }
            if let error { FormCaption(error, tone: .warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Load") { if let preset = selected { load(preset) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || renaming != nil)
            }
        }
        .padding(Theme.spaceXL)
        .frame(width: 460)
        .onAppear(perform: reload)
    }

    private var selected: P? {
        list.first { $0.id == selection } ?? imports?.presets.first { $0.id == selection }
    }

    private func importedRow(_ preset: P) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(preset.name).lineLimit(1)
            Text(summary(preset))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { load(preset) }
    }

    @ViewBuilder
    private func row(_ preset: P) -> some View {
        HStack(spacing: Theme.spaceS) {
            if renaming == preset.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { commitRename(preset) }
                    .onExitCommand { renaming = nil }
                Button("Done") { commitRename(preset) }.controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).lineLimit(1)
                    Text(summary(preset))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: Theme.spaceS)
                Button("Rename", systemImage: "pencil") { beginRename(preset) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                    .help("Rename")
                Button("Delete", systemImage: "trash") { delete(preset) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                    .help("Delete")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if renaming == nil { load(preset) } }
    }

    private func reload() {
        list = presets()
        selection = lastUsed.flatMap { NamedPresets.preset(named: $0, in: list)?.id } ?? list.first?.id
    }

    private func load(_ preset: P) {
        onLoad(preset)
        dismiss()
    }

    private func beginRename(_ preset: P) {
        renaming = preset.id
        renameText = preset.name
        renameFocused = true
    }

    private func commitRename(_ preset: P) {
        defer { renaming = nil }
        let target = NamedPresets.cleaned(renameText)
        guard target != preset.name else { return }
        guard let updated = NamedPresets.rename(preset.name, to: renameText, in: presets()) else {
            error = "That name is empty or already used."
            return
        }
        guard save(updated) else { return }
        if let renamed = updated.first(where: { $0.name == target }) {
            selection = renamed.id
            onRenamed(preset.name, target)
        }
    }

    private func delete(_ preset: P) {
        guard save(NamedPresets.delete(preset.name, in: presets())) else { return }
        if selection == preset.id { selection = list.first?.id }
        onRenamed(preset.name, nil)
    }

    private func save(_ updated: [P]) -> Bool {
        guard persist(updated) else {
            error = "The profile changed; reopen Load to try again."
            return false
        }
        list = NamedPresets.sorted(updated)
        error = nil
        return true
    }
}
