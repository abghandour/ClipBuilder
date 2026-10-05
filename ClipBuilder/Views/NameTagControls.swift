import SwiftUI

/// Shared visible choices for Mini and the full Wizard's presentation card.
struct NameTagControls: View {
    @Binding var style: String?
    @Binding var position: String?
    let profile: BrandProfile

    private var resolvedStyle: Binding<String?> {
        Binding(get: {
            profile.tagStyles?.contains { $0.id.uuidString == style } == true ? style : nil
        }, set: { style = $0 })
    }

    var body: some View {
        MiniRow("Tag style") {
            Picker("Tag style", selection: resolvedStyle) {
                Text("Profile default").lineLimit(1).fixedSize().tag(nil as String?)
                ForEach(profile.tagStyles ?? []) { named in
                    Text(named.name).lineLimit(1).fixedSize().tag(Optional(named.id.uuidString))
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
            .onAppear {
                if position == "auto" { position = nil }
            }
    }
}
