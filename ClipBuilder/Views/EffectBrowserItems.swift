import SwiftUI

/// The same item navigation and compact-width fallback on both resource pages.
struct EffectBrowserItems: View {
    let page: EffectSamplePicker.Page
    let tab: String
    @Binding var selection: String

    private var selected: String { page.selectedItem(selection, for: tab) ?? "" }

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            ViewThatFits(in: .horizontal) {
                picker
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                picker
                    .pickerStyle(.menu)
            }
            Spacer(minLength: 0)
            Button("Previous \(page.itemLabel)", systemImage: "chevron.left") {
                selection = page.previousItem(selected, for: tab) ?? ""
            }
            .disabled(page.previousItem(selected, for: tab) == selected || selected.isEmpty)
            Button("Next \(page.itemLabel)", systemImage: "chevron.right") {
                selection = page.nextItem(selected, for: tab) ?? ""
            }
            .disabled(page.nextItem(selected, for: tab) == selected || selected.isEmpty)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
    }

    private var picker: some View {
        Picker("Select \(page.itemLabel)", selection: Binding(
            get: { selected }, set: { selection = $0 })) {
            ForEach(page.items(for: tab)) { item in
                Text(item.title).lineLimit(1).fixedSize().tag(item.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Select \(page.itemLabel)")
    }
}
