import SwiftUI

struct CaptionPositionPicker: View {
    @Binding var selection: String?

    var body: some View {
        Picker("Caption position", selection: $selection) {
            Text("Auto").lineLimit(1).fixedSize().tag(nil as String?)
            ForEach(["bottom", "middle", "top"], id: \.self) { position in
                Text(position.capitalized).lineLimit(1).fixedSize().tag(Optional(position))
            }
            // Set by dragging the caption in the preview; any other choice clears it.
            if let custom = selection, CustomPosition.isCustom(custom) {
                Text("Custom (dragged)").lineLimit(1).fixedSize().tag(Optional(custom))
            }
        }
    }
}
