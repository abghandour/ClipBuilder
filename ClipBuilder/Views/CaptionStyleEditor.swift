import SwiftUI

struct CaptionStyleEditor: View {
    @Binding var name: String
    @Binding var style: CaptionStyle
    let isDefault: Bool

    /// The shared asset/system font picker uses nil for the default sans face.
    private var fontFamily: Binding<String?> {
        Binding(get: {
            switch style.font {
            case "sans", "": nil
            case "serif": "Times New Roman"
            case "mono": "Menlo"
            default: style.font
            }
        }, set: { style.font = $0 ?? "sans" })
    }

    private var alignment: Binding<String> {
        Binding(get: { style.alignment ?? "center" }, set: { style.alignment = $0 == "center" ? nil : $0 })
    }

    var body: some View {
        Form {
            Section {
                FormGroupHeader(isDefault ? "Profile default" : "Caption style")
                TextField("Name", text: $name).disabled(isDefault)
                FontFamilyPicker(family: fontFamily)
                Picker("Alignment", selection: alignment) {
                    Text("Leading").lineLimit(1).fixedSize().tag("leading")
                    Text("Center").lineLimit(1).fixedSize().tag("center")
                    Text("Trailing").lineLimit(1).fixedSize().tag("trailing")
                }
                .pickerStyle(.segmented)
                ColorPicker("Text colour", selection: overlayColorBinding($style.color), supportsOpacity: false)
                Toggle("Background", isOn: $style.bgOn)
                if style.bgOn {
                    ColorPicker("Background colour", selection: overlayColorBinding($style.bgColor), supportsOpacity: false)
                }
                FormCaption(isDefault
                    ? "Used whenever a run selects Profile default. Changes save automatically."
                    : "Available in this profile’s Mini and full Wizard. Changes save automatically.")
            }
            Section {
                FormGroupHeader("Preview")
                CaptionStylePreview(style: style)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}
