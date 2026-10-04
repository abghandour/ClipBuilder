import SwiftUI

/// Shared visible choices for Mini and the full Wizard's presentation card.
struct NameTagControls: View {
    @Binding var content: String?
    @Binding var style: String?
    @Binding var position: String?
    @State private var templates: [String] = []

    var body: some View {
        MiniRow("Tag shows") {
            Picker("Tag shows", selection: $content) {
                Text("Name").lineLimit(1).fixedSize().tag(nil as String?)
                Text("Name and role").lineLimit(1).fixedSize().tag("nameAndRole" as String?)
            }
            .pickerStyle(.segmented)
        }
        MiniRow("Tag style") {
            Picker("Tag style", selection: $style) {
                Text("Default").lineLimit(1).fixedSize().tag(nil as String?)
                ForEach(templates, id: \.self) { name in
                    Text(name).lineLimit(1).fixedSize().tag(name as String?)
                }
            }
            .pickerStyle(.menu)
        }
        MiniRow("Tag position") {
            Picker("Tag position", selection: $position) {
                Text("Auto").lineLimit(1).fixedSize().tag(nil as String?)
                Text("Top left").lineLimit(1).fixedSize().tag("topLeading" as String?)
                Text("Top right").lineLimit(1).fixedSize().tag("topTrailing" as String?)
                Text("Bottom left").lineLimit(1).fixedSize().tag("bottomLeading" as String?)
                Text("Bottom right").lineLimit(1).fixedSize().tag("bottomTrailing" as String?)
            }
            .pickerStyle(.menu)
        }
        FormCaption("Auto keeps clear of the platform buttons; the other choices use the corner of the person's area.")
            .task { templates = OverlayTemplateStore.list().map(\.name) }
            .onAppear {
                if content == "name" { content = nil }
                if position == "auto" { position = nil }
            }
    }
}
