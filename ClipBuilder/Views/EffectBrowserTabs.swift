import SwiftUI

struct EffectBrowserTabs: View {
    let page: EffectSamplePicker.Page
    @Binding var selection: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
            picker
                .pickerStyle(.menu)
        }
    }

    private var picker: some View {
        Picker("\(page.rawValue.capitalized) section", selection: Binding(
            get: { page.selectedTab(selection) }, set: { selection = $0 })) {
            ForEach(page.tabs) { tab in
                Text(tab.title).lineLimit(1).fixedSize().tag(tab.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel("\(page.rawValue.capitalized) section")
    }
}
