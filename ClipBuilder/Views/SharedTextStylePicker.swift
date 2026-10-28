import SwiftUI

struct SharedTextStylePicker: View {
    @Binding var selection: String?
    @Environment(AppStore.self) private var store

    var body: some View {
        Picker(selection: $selection) {
            Text("None").lineLimit(1).fixedSize().tag(String?.none)
            ForEach(store.activeProfile.textStyles ?? []) { style in
                Text(style.name).lineLimit(1).fixedSize().tag(Optional(style.id.uuidString))
            }
            if let selection, !(store.activeProfile.textStyles ?? []).contains(where: { $0.id.uuidString == selection }) {
                Text("Unavailable style").lineLimit(1).fixedSize().tag(Optional(selection))
            }
        } label: { Text("Shared style").lineLimit(1).fixedSize() }
        .help(WizardFieldHelp.textDecor["sharedStyle"]!.tooltip)
    }
}
