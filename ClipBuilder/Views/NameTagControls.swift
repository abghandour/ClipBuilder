import SwiftUI

/// Shared visible choices for Mini and the full Wizard's presentation card.
struct NameTagControls: View {
    @Binding var style: String?
    @Binding var position: String?
    let profile: BrandProfile
    /// The people the tags will label, editable in place (name and the
    /// style's description line). Either list them, or name the videos
    /// whose rosters hold them; nil for both shows no editor.
    var people: [PersonRecord]? = nil
    var videoIDs: [Int64]? = nil

    private var resolvedStyle: Binding<String?> {
        Binding(get: {
            profile.tagStyles?.contains { $0.id.uuidString == style } == true ? style : nil
        }, set: { style = $0 })
    }

    var body: some View {
        MiniRow("Name tag style") {
            Picker("Name tag style", selection: resolvedStyle) {
                Text("Profile default").lineLimit(1).fixedSize().tag(nil as String?)
                ForEach(profile.tagStyles ?? []) { named in
                    Text(named.name).lineLimit(1).fixedSize().tag(Optional(named.id.uuidString))
                }
            }
            .pickerStyle(.menu)
        }
        MiniRow("Name tag position") {
            Picker("Name tag position", selection: $position) {
                Text("Auto").lineLimit(1).fixedSize().tag(nil as String?)
                Text("Top left").lineLimit(1).fixedSize().tag("topLeading" as String?)
                Text("Top right").lineLimit(1).fixedSize().tag("topTrailing" as String?)
                Text("Bottom left").lineLimit(1).fixedSize().tag("bottomLeading" as String?)
                Text("Bottom right").lineLimit(1).fixedSize().tag("bottomTrailing" as String?)
                // Set by dragging a tag in the preview; any other choice clears it.
                if let custom = position, CustomPosition.isCustom(custom) {
                    Text("Custom (dragged)").lineLimit(1).fixedSize().tag(Optional(custom))
                }
            }
            .pickerStyle(.menu)
        }
        FormCaption(CustomPosition.isCustom(position)
            ? "Placed where you dragged it in the preview. A person's own Name tag position still wins."
            : "Auto keeps clear of the platform buttons. Safe area only also keeps chosen corners clear. Drag a tag in the preview to place it by hand.")
            .onAppear {
                if position == "auto" { position = nil }
            }
        if people != nil || videoIDs != nil {
            MiniRow("People") {
                NameTagPeopleEditor(people: people, videoIDs: videoIDs, styleID: style, profile: profile)
            }
        }
    }
}
