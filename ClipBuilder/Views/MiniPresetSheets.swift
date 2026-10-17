import SwiftUI

enum MiniPresetSheet: String, Identifiable {
    case save, load
    var id: String { rawValue }
}

/// Name and save the current Express settings. The name defaults to the
/// last preset used, so repeated saves update the same entry.
struct MiniPresetSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let profileName: String
    let settings: MiniWizardSettings
    var onSaved: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var presets: [MiniWizardPreset] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Save Settings").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if !presets.isEmpty {
                FormCaption(replaces
                    ? "Replaces the saved settings named “\(MiniWizardPresetStore.cleaned(name))”."
                    : "Saved: " + presets.map(\.name).joined(separator: ", "))
                    .lineLimit(2)
            }
            if let error { FormCaption(error, tone: .warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replaces ? "Replace" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(MiniWizardPresetStore.cleaned(name).isEmpty)
            }
        }
        .padding(Theme.spaceXL)
        .frame(width: 380)
        .onAppear {
            presets = store.expressPresets(profileName: profileName)
            let lastUsed = UserDefaults.standard.string(forKey: MiniWizardPresetStore.lastUsedKey(profileName: profileName))
            name = MiniWizardPresetStore.suggestedName(lastUsed: lastUsed, presets: presets)
        }
    }

    private var replaces: Bool {
        MiniWizardPresetStore.preset(named: name, in: presets) != nil
    }

    private func save() {
        let cleaned = MiniWizardPresetStore.cleaned(name)
        guard !cleaned.isEmpty else { return }
        // Against the live collection, not the snapshot taken when the sheet
        // opened: a teammate's preset that synced in meanwhile must survive.
        let current = store.expressPresets(profileName: profileName)
        let updated = MiniWizardPresetStore.upsert(name: cleaned, settings: settings, into: current)
        guard store.saveExpressPresets(updated, profileName: profileName) else {
            error = "The profile changed; reopen Save to try again."
            return
        }
        MiniWizardPresetStore.rememberLoaded(.init(name: cleaned, settings: settings), profileName: profileName)
        onSaved(cleaned)
        dismiss()
    }
}

/// Pick saved Express settings to load; rename or delete entries in place.
struct MiniPresetLoadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let profileName: String
    let onLoad: (MiniWizardPreset) -> Void
    /// Called when a rename or delete touched the preset the card is tracking.
    var onChanged: () -> Void = {}

    @State private var presets: [MiniWizardPreset] = []
    @State private var selection: String?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var error: String?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Load Settings").font(.headline)
            if presets.isEmpty {
                FormCaption("No saved settings yet. Use Save… on the Settings card to keep a set.")
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                List(selection: $selection) {
                    ForEach(presets) { preset in
                        row(preset)
                            .tag(preset.id)
                            .contextMenu {
                                Button("Load") { load(preset) }
                                Button("Rename…") { beginRename(preset) }
                                Button("Delete", role: .destructive) { delete(preset) }
                            }
                    }
                }
                .frame(minHeight: 200, maxHeight: 320)
                FormCaption("Double-click to load. Each row has Rename and Delete.")
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

    private var selected: MiniWizardPreset? {
        presets.first { $0.id == selection }
    }

    @ViewBuilder
    private func row(_ preset: MiniWizardPreset) -> some View {
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

    private func summary(_ preset: MiniWizardPreset) -> String {
        let when = preset.savedAt.formatted(date: .abbreviated, time: .shortened)
        return when + " · " + MiniWizardFlow(outputMode: preset.settings.outputMode).settingsSummary(preset.settings)
    }

    private func reload() {
        presets = store.expressPresets(profileName: profileName)
        let lastUsed = UserDefaults.standard.string(forKey: MiniWizardPresetStore.lastUsedKey(profileName: profileName))
        selection = lastUsed.flatMap { MiniWizardPresetStore.preset(named: $0, in: presets)?.id } ?? presets.first?.id
    }

    private func load(_ preset: MiniWizardPreset) {
        MiniWizardPresetStore.rememberLoaded(.init(name: preset.name, settings: preset.settings), profileName: profileName)
        onLoad(preset)
        dismiss()
    }

    private func beginRename(_ preset: MiniWizardPreset) {
        renaming = preset.id
        renameText = preset.name
        renameFocused = true
    }

    private func commitRename(_ preset: MiniWizardPreset) {
        defer { renaming = nil }
        guard MiniWizardPresetStore.cleaned(renameText) != preset.name else { return }
        let current = store.expressPresets(profileName: profileName)
        guard let updated = MiniWizardPresetStore.rename(preset.name, to: renameText, in: current) else {
            error = "That name is empty or already used."
            return
        }
        persist(updated)
        if let newName = updated.first(where: { $0.settings == preset.settings && $0.savedAt == preset.savedAt })?.name {
            selection = newName.lowercased()
            if let tracked = MiniWizardPresetStore.loaded(profileName: profileName), tracked.name == preset.name {
                MiniWizardPresetStore.rememberLoaded(.init(name: newName, settings: tracked.settings), profileName: profileName)
                onChanged()
            }
        }
    }

    private func delete(_ preset: MiniWizardPreset) {
        persist(MiniWizardPresetStore.delete(preset.name, in: store.expressPresets(profileName: profileName)))
        if selection == preset.id { selection = presets.first?.id }
        if MiniWizardPresetStore.loaded(profileName: profileName)?.name == preset.name {
            MiniWizardPresetStore.rememberLoaded(nil, profileName: profileName)
            onChanged()
        }
    }

    private func persist(_ updated: [MiniWizardPreset]) {
        guard store.saveExpressPresets(updated, profileName: profileName) else {
            error = "The profile changed; reopen Load to try again."
            return
        }
        presets = MiniWizardPresetStore.sorted(updated)
        error = nil
    }
}
