import SwiftUI

/// Shared visible choices for Mini and the full Wizard's presentation card.
struct NameTagControls: View {
    @Binding var style: String?
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
        FormCaption("Each person's tag sits where their position below says: Auto keeps clear of faces, captions and the platform buttons. Drag a tag in the preview to place that person's tag by hand.")
        if people != nil || videoIDs != nil {
            MiniRow("People") {
                NameTagPeopleEditor(people: people, videoIDs: videoIDs, styleID: style, profile: profile)
            }
        }
    }
}
