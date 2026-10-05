import SwiftUI

struct TagStyleEditor: View {
    @Binding var name: String
    @Binding var style: TagStyle
    let isDefault: Bool
    @State private var selectedImage: UUID?
    @State private var showingImages = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            previewColumn
                .padding()
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            settings
                .frame(width: 360)
                .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showingImages) {
            ImagePickerSheet { urls in
                for url in urls {
                    let image = TagImage(path: url.path)
                    style.images.append(image)
                    selectedImage = image.id
                }
            }
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 10) {
            Text(name).font(.headline).lineLimit(1)
            TagStylePreview(style: $style, selection: $selectedImage)
                .frame(maxWidth: 640)
            Text("Sample text. Click an image to select it; drag to reposition, or use its corner handle to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        Form {
            Section {
                FormGroupHeader("Tag style")
                TextField("Name", text: $name).disabled(isDefault)
                Picker("Alignment", selection: $style.alignment) {
                    Text("Leading").lineLimit(1).fixedSize().tag("leading")
                    Text("Center").lineLimit(1).fixedSize().tag("center")
                    Text("Trailing").lineLimit(1).fixedSize().tag("trailing")
                }
                .pickerStyle(.segmented)
                Toggle("Background", isOn: $style.bgOn)
                if style.bgOn {
                    ColorPicker("Background colour", selection: overlayColorBinding($style.bgColor), supportsOpacity: false)
                        .formDependent()
                    Slider(value: $style.bgOpacity, in: 0...1) {
                        Text("Opacity").lineLimit(1).fixedSize()
                    }.formDependent()
                    Slider(value: $style.cornerRadius, in: 0...80) {
                        Text("Corner radius").lineLimit(1).fixedSize()
                    }.formDependent()
                }
                FormCaption("Available in this profile’s Express and full Wizard. Changes save automatically.")
            }
            Section {
                FormGroupHeader("Name line")
                LabeledContent("Field", value: "Name")
                TagLineControls(style: $style.name)
            }
            Section {
                FormGroupHeader("Description line")
                HStack {
                    TextField("Field", text: $style.description.field)
                    Menu("Suggestions") {
                        ForEach(["Role", "Profession", "MMA record", "Team", "Nationality"], id: \.self) { field in
                            Button(field) { style.description.field = field }
                        }
                    }.lineLimit(1).fixedSize()
                }
                FormCaption("Shows what People has saved for this field. For people without it, AI fills the field from the reel’s context; edit it in People.")
                TagLineControls(style: $style.description)
            }
            Section {
                FormGroupHeader("Images")
                Button("Add Image", systemImage: "photo") { showingImages = true }
                    .lineLimit(1).fixedSize()
                if style.images.isEmpty {
                    FormCaption("Add an image from the Images library, then drag or resize it on the preview.")
                }
                ForEach($style.images) { $image in
                    TagImageControls(image: $image, selected: selectedImage == image.id,
                        select: { selectedImage = image.id }, remove: {
                            let id = image.id
                            style.images.removeAll { $0.id == id }
                            if selectedImage == id { selectedImage = nil }
                        })
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TagLineControls: View {
    @Binding var style: TagLineStyle

    var body: some View {
        FontFamilyPicker(family: $style.font)
        Slider(value: $style.scale, in: 0.3...2) {
            Text("Size").lineLimit(1).fixedSize()
        }
        ColorPicker("Text colour", selection: overlayColorBinding($style.color), supportsOpacity: false)
        Toggle("Bold", isOn: $style.bold)
        Toggle("Italic", isOn: $style.italic)
        Toggle("Caps", isOn: $style.uppercase)
        Toggle("Underline", isOn: $style.underline)
        if style.underline {
            Toggle("Use text colour", isOn: Binding(get: { style.underlineColor == nil }, set: {
                style.underlineColor = $0 ? nil : style.color
            })).formDependent()
            if style.underlineColor != nil {
                ColorPicker("Underline colour", selection: overlayColorBinding(Binding(
                    get: { style.underlineColor ?? style.color }, set: { style.underlineColor = $0 })), supportsOpacity: false)
                    .formDependent()
            }
            Slider(value: $style.underlineThickness, in: 0.02...0.2) {
                Text("Thickness").lineLimit(1).fixedSize()
            }.formDependent()
        }
    }
}

private struct TagImageControls: View {
    @Binding var image: TagImage
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Button(action: select) {
                    Label(URL(fileURLWithPath: image.path).lastPathComponent,
                          systemImage: selected ? "checkmark.circle.fill" : "photo")
                        .lineLimit(1)
                }.buttonStyle(.plain)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly).fixedSize()
            }
            Slider(value: $image.opacity, in: 0...1) {
                Text("Opacity").lineLimit(1).fixedSize()
            }
            Picker("Layer", selection: $image.behindText) {
                Text("Behind text").lineLimit(1).fixedSize().tag(true)
                Text("In front").lineLimit(1).fixedSize().tag(false)
            }.pickerStyle(.segmented)
            HStack {
                TextField("X", value: $image.x, format: .number).accessibilityLabel("Image horizontal position")
                TextField("Y", value: $image.y, format: .number).accessibilityLabel("Image vertical position")
            }
            Slider(value: $image.width, in: 0.05...2) {
                Text("Width").lineLimit(1).fixedSize()
            }
        }
    }
}
