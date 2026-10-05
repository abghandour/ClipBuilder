import SwiftUI

/// Profile-owned tag presets. The default is always present and cannot be deleted.
struct TagStylesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String? = "default"
    @State private var deleting = false

    private var selectedIndex: Int? {
        store.activeProfile.tagStyles?.firstIndex { $0.id.uuidString == selection }
    }

    private var name: Binding<String> {
        Binding(get: {
            guard let index = selectedIndex else { return "Profile default" }
            return store.activeProfile.tagStyles?[index].name ?? ""
        }, set: { value in
            guard let index = selectedIndex else { return }
            store.activeProfile.tagStyles?[index].name = value
            store.saveActiveProfile()
        })
    }

    private var style: Binding<TagStyle> {
        Binding(get: { store.activeProfile.tagStyle(id: selection) }, set: { value in
            if let index = selectedIndex {
                store.activeProfile.tagStyles?[index].style = value
            } else {
                store.activeProfile.tagStyle = value
            }
            store.saveActiveProfile()
        })
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Text("Profile default").lineLimit(1).tag("default")
                ForEach(store.activeProfile.tagStyles ?? []) { named in
                    Text(named.name).lineLimit(1).truncationMode(.tail)
                        .tag(named.id.uuidString)
                }
            }
            .listStyle(.inset)
            .rememberedPaneWidth("pane.tags.styles", min: 200, initial: 230, max: 300)
            .frame(maxHeight: .infinity)
            TagStyleEditor(name: name, style: style, isDefault: selectedIndex == nil)
                .id(selection)
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenTitle("Tags", subtitle: "\(styleCount) style\(styleCount == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup {
                Button("New Style", systemImage: "plus") { addStyle(duplicate: false) }
                    .help("Create a tag style")
                Button("Duplicate", systemImage: "plus.square.on.square") { addStyle(duplicate: true) }
                    .help("Duplicate the selected tag style")
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                    .help("Delete the selected tag style")
                    .disabled(selectedIndex == nil)
            }
        }
        .confirmationDialog("Delete this tag style?", isPresented: $deleting) {
            Button("Delete Style", role: .destructive, action: deleteStyle)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs using this style will use Profile default instead.")
        }
    }

    private var styleCount: Int { (store.activeProfile.tagStyles?.count ?? 0) + 1 }

    private func addStyle(duplicate: Bool) {
        let named = NamedTagStyle(name: duplicate ? name.wrappedValue + " Copy" : "New Style",
                                      style: duplicate ? style.wrappedValue : store.activeProfile.tagStyle(id: nil))
        store.activeProfile.tagStyles = (store.activeProfile.tagStyles ?? []) + [named]
        selection = named.id.uuidString
        store.saveActiveProfile()
    }

    private func deleteStyle() {
        guard selectedIndex != nil else { return }
        store.activeProfile.tagStyles?.removeAll { $0.id.uuidString == selection }
        selection = "default"
        store.saveActiveProfile()
    }
}
