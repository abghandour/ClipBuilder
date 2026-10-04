import SwiftUI

/// Profile-owned caption presets. The default is always present and cannot be deleted.
struct CaptionStylesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String? = "default"
    @State private var deleting = false

    private var selectedIndex: Int? {
        store.activeProfile.captionStyles?.firstIndex { $0.id.uuidString == selection }
    }

    private var name: Binding<String> {
        Binding(get: {
            guard let index = selectedIndex else { return "Profile default" }
            return store.activeProfile.captionStyles?[index].name ?? ""
        }, set: { value in
            guard let index = selectedIndex else { return }
            store.activeProfile.captionStyles?[index].name = value
            store.saveActiveProfile()
        })
    }

    private var style: Binding<CaptionStyle> {
        Binding(get: { store.activeProfile.captionStyle(id: selection) }, set: { value in
            if let index = selectedIndex {
                store.activeProfile.captionStyles?[index].style = value
            } else {
                store.activeProfile.captions = value
            }
            store.saveActiveProfile()
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captions").font(.headline).lineLimit(1).fixedSize()
                Spacer()
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .trailing) { actions }
                }
            }
            .padding(Theme.spaceM)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    Text("Profile default").lineLimit(1).tag("default")
                    ForEach(store.activeProfile.captionStyles ?? []) { named in
                        Text(named.name).lineLimit(1).truncationMode(.tail)
                            .tag(named.id.uuidString)
                    }
                }
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 300)
                CaptionStyleEditor(name: name, style: style, isDefault: selectedIndex == nil)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Delete this caption style?", isPresented: $deleting) {
            Button("Delete Style", role: .destructive, action: deleteStyle)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs using this style will use Profile default instead.")
        }
    }

    @ViewBuilder private var actions: some View {
        Button("New Style", systemImage: "plus") { addStyle(duplicate: false) }
            .lineLimit(1).fixedSize()
        Button("Duplicate", systemImage: "plus.square.on.square") { addStyle(duplicate: true) }
            .lineLimit(1).fixedSize()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
            .lineLimit(1).fixedSize().disabled(selectedIndex == nil)
    }

    private func addStyle(duplicate: Bool) {
        let named = NamedCaptionStyle(name: duplicate ? name.wrappedValue + " Copy" : "New Style",
                                      style: duplicate ? style.wrappedValue : store.activeProfile.captions)
        store.activeProfile.captionStyles = (store.activeProfile.captionStyles ?? []) + [named]
        selection = named.id.uuidString
        store.saveActiveProfile()
    }

    private func deleteStyle() {
        guard selectedIndex != nil else { return }
        store.activeProfile.captionStyles?.removeAll { $0.id.uuidString == selection }
        selection = "default"
        store.saveActiveProfile()
    }
}
