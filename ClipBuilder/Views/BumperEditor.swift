import SwiftUI

struct BumperEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let bumper: BumperAsset
    @State private var displayName: String
    @State private var intro: Bool
    @State private var outro: Bool
    @State private var anywhere: Bool
    @State private var saving = false

    init(bumper: BumperAsset) {
        self.bumper = bumper
        _displayName = State(initialValue: bumper.displayName)
        _intro = State(initialValue: bumper.placements.contains(.intro))
        _outro = State(initialValue: bumper.placements.contains(.outro))
        _anywhere = State(initialValue: bumper.placements.contains(.anywhere))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Bumper").font(.headline)
            TextField("Display name", text: $displayName)
            Text("Allow the AI Wizard to use this video as:").font(.subheadline)
            Toggle("Intro", isOn: $intro)
            Toggle("Outro", isOn: $outro)
            Toggle("Anywhere (mid-roll)", isOn: $anywhere)
            Text("Bumpers always fill the canvas with the whole video visible. Other tracks, crops, captions, and overlays are hidden while they play.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || store.database == nil)
            }
        }.padding(24).frame(width: 400)
    }

    private func save() {
        guard let database = store.database else { return }
        saving = true
        let placements = Set([intro ? BumperPlacement.intro : nil,
                              outro ? .outro : nil, anywhere ? .anywhere : nil].compactMap { $0 })
        Task {
            do {
                try await database.saveBumper(path: bumper.path, displayName: displayName, placements: placements)
                store.refreshBumpers()
                dismiss()
            } catch {
                saving = false
                store.presentError("Could not save bumper", error)
            }
        }
    }
}
