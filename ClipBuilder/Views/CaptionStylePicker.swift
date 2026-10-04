import SwiftUI

struct CaptionStylePicker: View {
    @Binding var selection: String?
    let profile: BrandProfile

    private var resolvedSelection: Binding<String?> {
        Binding(get: {
            profile.captionStyles?.contains { $0.id.uuidString == selection } == true ? selection : nil
        }, set: { selection = $0 })
    }

    var body: some View {
        Picker("Caption style", selection: resolvedSelection) {
            Text("Profile default").lineLimit(1).tag(nil as String?)
            ForEach(profile.captionStyles ?? []) { style in
                Text(style.name).lineLimit(1).truncationMode(.tail).tag(Optional(style.id.uuidString))
            }
        }
        .pickerStyle(.menu)
        .lineLimit(1)
    }
}
