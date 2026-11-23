import SwiftUI

struct StrikeHighlightStylePicker: View {
    @Binding var selection: String
    var enabled: Bool

    var body: some View {
        Picker("Highlight style", selection: $selection) {
            Text("Outline").lineLimit(1).fixedSize().tag("outline")
            Text("Solid").lineLimit(1).fixedSize().tag("solid")
        }
        .pickerStyle(.menu).lineLimit(1).fixedSize()
        .disabled(!enabled)
        .help("Solid fills the striking limb in red. It needs the HD outline for that strike; without one the strike keeps the plain band.")
    }
}
