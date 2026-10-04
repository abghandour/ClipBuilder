import SwiftUI

struct CaptionPositionPicker: View {
    @Binding var selection: String?

    var body: some View {
        Picker("Caption position", selection: $selection) {
            Text("Auto").lineLimit(1).fixedSize().tag(nil as String?)
            ForEach(["bottom", "middle", "top"], id: \.self) { position in
                Text(position.capitalized).lineLimit(1).fixedSize().tag(Optional(position))
            }
        }
    }
}
