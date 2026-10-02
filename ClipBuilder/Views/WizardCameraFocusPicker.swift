import SwiftUI

struct WizardCameraFocusPicker: View {
    @Binding var selection: String
    let allowsOriginal: Bool

    var body: some View {
        Picker("Camera focus", selection: $selection) {
            Text("Let AI choose the best").tag("")
            ForEach(CropRecipe.Kind.allCases, id: \.rawValue) { kind in
                Text(kind.name).tag(kind.rawValue)
            }
            if allowsOriginal {
                Text("Original framing").tag(WizardCameraFocus.original)
            }
        }
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        FormCaption(WizardCameraFocus.summary(selection))
    }
}
