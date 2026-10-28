import SwiftUI

struct NamedTextStylesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var selected: Binding<NamedTextStyle>? {
        guard let index = store.activeProfile.textStyles?.firstIndex(where: { $0.id == selection }) else { return nil }
        return Binding(get: { store.activeProfile.textStyles![index] }, set: {
            store.activeProfile.textStyles?[index] = $0
            store.scheduleActiveProfileSave()
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack {
                    List(selection: $selection) {
                        ForEach(store.activeProfile.textStyles ?? []) { style in
                            Text(style.name).lineLimit(1).tag(style.id)
                        }
                    }
                    HStack {
                        Button("New", systemImage: "plus", action: add).lineLimit(1).fixedSize()
                        Button("Delete", systemImage: "trash", role: .destructive, action: remove)
                            .lineLimit(1).fixedSize().disabled(selected == nil)
                    }.padding()
                }
                .frame(minWidth: 180, idealWidth: 220, maxHeight: .infinity)
                Group {
                    if let selected {
                        Form {
                            TextField("Name", text: selected.name).help(WizardFieldHelp.textDecor["name"]!.tooltip)
                            TextDecorControls(decor: Binding(get: { selected.wrappedValue.decor }, set: { selected.wrappedValue.decor = $0 ?? TextDecor() }),
                                              fontFamily: selected.fontFamily, sourceLabel: "named style")
                        }.formStyle(.grouped)
                    } else {
                        ContentUnavailableView("Named Text Styles", systemImage: "textformat", description: Text("Create a look to share across captions, name tags and overlays."))
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.lineLimit(1).fixedSize() }.padding()
        }
        .frame(width: 760, height: 620)
    }

    private func add() {
        let style = NamedTextStyle(name: "New text style", decor: TextDecor())
        store.activeProfile.textStyles = (store.activeProfile.textStyles ?? []) + [style]
        selection = style.id
        store.saveActiveProfile()
    }

    private func remove() {
        store.activeProfile.textStyles?.removeAll { $0.id == selection }
        selection = nil
        store.saveActiveProfile()
    }
}
