import SwiftUI

/// The studio's profile and preset library. Add always makes an independent copy.
struct TextLooksList: View {
    struct Entry: Identifiable {
        var id: String
        var name: String
        var decor: TextDecor
        var fontFamily: String?
        var base: String
        var runs: Int = 0
    }
    let entries: [Entry]
    let presets: [Entry]
    @Binding var selection: String?
    let addPreset: (String) -> Void
    let add: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    let canDelete: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Profile") {
                    ForEach(entries) { entry in row(entry).tag(entry.id) }
                }
                if !presets.isEmpty {
                    Section("Presets") {
                        ForEach(presets) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                row(entry)
                                Button("Add", systemImage: "plus") { addPreset(entry.id) }
                                    .lineLimit(1).fixedSize().help("Add an editable copy of \(entry.name)")
                            }
                        }
                    }
                }
            }
            ControlGroup {
                Button("New", systemImage: "plus", action: add)
                    .help("Add a style")
                Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
                    .disabled(selection == nil)
                    .help("Duplicate the selected style")
                Button("Delete", systemImage: "trash", role: .destructive, action: remove)
                    .disabled(!canDelete)
                    .help("Delete the selected style")
            }.labelStyle(.iconOnly).padding(Theme.spaceS)
        }
    }

    private func row(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                LookCard(name: entry.name, decor: entry.decor, fontFamily: entry.fontFamily, showsName: false)
                Spacer(minLength: 0)
                Text("\(entry.runs)").font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                    .padding(4).background(.quaternary, in: .capsule)
                    .help("\(entry.runs) Wizard runs reference this style")
            }
            Text(entry.name).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Text(entry.base).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
}
