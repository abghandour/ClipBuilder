import SwiftUI

/// Right-hand inspector: settings for the selected clip, sound block, or
/// text overlay (transitions, position, crop, mute, volume, captions, fonts).
struct BuilderInspector: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        ScrollView {
            switch model.selection {
            case .clip(let uid):
                if let clip = model.clip(uid) {
                    ClipInspector(clip: clip)
                } else {
                    placeholder
                }
            case .sound(let uid):
                if let index = model.soundIndex(uid) {
                    SoundInspector(item: model.document.soundTrack[index])
                } else {
                    placeholder
                }
            case .text(let uid):
                if let item = model.textItem(uid) {
                    TextInspector(item: item)
                } else {
                    placeholder
                }
            case .image(let uid):
                if let item = model.imageItem(uid) {
                    ImageInspector(item: item)
                } else {
                    placeholder
                }
            case .overlay(let uid):
                if let item = model.overlayBlock(uid) {
                    OverlayBlockInspector(item: item)
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a clip, music block, or text overlay to edit its settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// Transition picker choices: hard cut plus every xfade the engine supports.
private let transitionChoices = ["cut"] + RenderEngine.transitions

struct ClipInspector: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip

    var body: some View {
        let model = store.builder
        VStack(alignment: .leading, spacing: 12) {
            Text(model.scene(for: clip)?.videoFilename
                 ?? (clip.videoFile as NSString?)?.lastPathComponent ?? "Clip")
                .font(.headline)
                .lineLimit(1)

            LabeledContent("Start") {
                Text(clip.startTime.timecode).monospacedDigit()
            }
            LabeledContent("Duration") {
                Text(String(format: "%.1fs", clip.duration)).monospacedDigit()
            }

            Divider()

            Picker("Transition in", selection: transitionBinding(\.transIn)) {
                ForEach(transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Transition out", selection: transitionBinding(\.transOut)) {
                ForEach(transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            Divider()

            Toggle("Muted", isOn: binding(\.muted))
            Picker("Volume", selection: binding(\.volume)) {
                ForEach(1...5, id: \.self) { level in
                    Text("\(level)").tag(level)
                }
            }
            .pickerStyle(.segmented)

            Picker("Captions", selection: binding(\.captions)) {
                ForEach(TimelineClip.captionChoices, id: \.self) { choice in
                    Text(choice.capitalized).tag(choice)
                }
            }

            if clip.wide {
                Divider()
                Picker("Position", selection: Binding(
                    get: { clip.position ?? "layer" },
                    set: { value in
                        store.builder.updateClip(clip.uid) {
                            $0.position = value == "layer" ? nil : value
                        }
                    })) {
                    Text("Layer default").tag("layer")
                    Text("Top").tag("top")
                    Text("Center").tag("center")
                    Text("Bottom").tag("bottom")
                }
                Toggle("Crop to 9:16", isOn: Binding(
                    get: { clip.cropXFrac != nil },
                    set: { value in
                        store.builder.updateClip(clip.uid) { $0.cropXFrac = value ? 0.5 : nil }
                    }))
                if let crop = clip.cropXFrac {
                    // Crop window position over the wide frame (0 = left, 1 = right).
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: Binding(
                            get: { crop },
                            set: { value in
                                store.builder.updateClip(clip.uid) { $0.cropXFrac = value }
                            }), in: 0...1)
                        cropPreview(fraction: crop)
                    }
                }
                Stepper("Stack order: \(clip.stackOrder)", value: binding(\.stackOrder), in: 0...9)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Custom crops")
                    Spacer()
                    Button {
                        addCrop()
                    } label: {
                        Label("Add Crop", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .help("Add a crop rectangle; drag it in the preview to pick the region to show")
                }
                if let crops = clip.freeCrops, !crops.isEmpty {
                    ForEach(crops.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "crop")
                                .foregroundStyle(.secondary)
                            Text("Crop \(index + 1)")
                            Spacer()
                            Button {
                                removeCrop(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove this crop")
                        }
                        .font(.caption)
                    }
                    Text("Drag a rectangle in the preview to choose the part of the video to display; drag a corner to resize it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Duplicate") { model.duplicateClip(clip.uid) }
                Spacer()
                Button("Delete", role: .destructive) { model.removeClip(clip.uid) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    /// New crops start as the center half of the frame (staggered a little so
    /// stacked crops stay grabbable) and display in place: dst mirrors src
    /// until the user gives them different roles.
    private func addCrop() {
        let model = store.builder
        let count = clip.freeCrops?.count ?? 0
        let offset = min(0.1 * Double(count), 0.25)
        let rect = FreeCropRect(xFrac: 0.25 + offset, yFrac: 0.25 + offset,
                                wFrac: 0.5, hFrac: 0.5)
        model.updateClip(clip.uid) {
            var crops = $0.freeCrops ?? []
            crops.append(FreeCrop(src: rect, dst: rect, z: count))
            $0.freeCrops = crops
        }
        // Move the playhead into the clip so the preview shows the rectangle.
        if model.playhead < clip.startTime || model.playhead >= clip.startTime + clip.duration {
            model.playhead = clip.startTime
        }
    }

    private func removeCrop(at index: Int) {
        store.builder.updateClip(clip.uid) {
            guard var crops = $0.freeCrops, crops.indices.contains(index) else { return }
            crops.remove(at: index)
            $0.freeCrops = crops.isEmpty ? nil : crops
        }
    }

    private func cropPreview(fraction: Double) -> some View {
        let model = store.builder
        return Group {
            if let url = model.sourceURL(for: clip) {
                VideoThumbnail(url: url, time: clip.sourceStart ?? 0, cornerRadius: 4)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            let windowWidth = geo.size.height * 9 / 16
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .frame(width: windowWidth, height: geo.size.height)
                                .offset(x: (geo.size.width - windowWidth) * fraction)
                        }
                    }
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TimelineClip, T>) -> Binding<T> {
        let model = store.builder
        let uid = clip.uid
        let fallback = clip[keyPath: keyPath]
        return Binding(
            get: { model.clip(uid)?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateClip(uid) { $0[keyPath: keyPath] = value } })
    }

    private func transitionBinding(_ keyPath: WritableKeyPath<TimelineClip, String?>) -> Binding<String> {
        let model = store.builder
        let uid = clip.uid
        return Binding(
            get: { model.clip(uid)?[keyPath: keyPath] ?? "cut" },
            set: { value in model.updateClip(uid) { $0[keyPath: keyPath] = value == "cut" ? nil : value } })
    }
}

struct SoundInspector: View {
    @Environment(AppStore.self) private var store
    let item: SoundItem

    var body: some View {
        let model = store.builder
        VStack(alignment: .leading, spacing: 12) {
            Label(item.name, systemImage: "music.note")
                .font(.headline)
                .lineLimit(1)
            Picker("Volume", selection: Binding(
                get: { item.volume },
                set: { value in model.updateSound(item.uid) { $0.volume = value } })) {
                ForEach(1...5, id: \.self) { level in
                    Text("\(level)").tag(level)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Start") {
                Text(item.startTime.timecode).monospacedDigit()
            }
            Stepper(String(format: "Duration: %.1fs", item.duration),
                    value: Binding(
                        get: { item.duration },
                        set: { value in model.updateSound(item.uid) { $0.duration = value } }),
                    in: 0.5...600, step: 0.5)
            Divider()
            Button("Delete", role: .destructive) { model.removeSound(item.uid) }
                .controlSize(.small)
        }
        .padding(12)
    }
}

struct ImageInspector: View {
    @Environment(AppStore.self) private var store
    let item: ImageOverlayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image Overlay")
                .font(.headline)

            ImageOverlayControls(item: itemBinding, name: item.displayName)

            Picker("Enter", selection: itemBinding.transIn) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Exit", selection: itemBinding.transOut) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            LabeledContent("Timing") {
                Text("\(item.startTime.timecode)–\(item.endTime.timecode)").monospacedDigit()
            }

            Divider()
            Button("Delete", role: .destructive) { store.builder.removeImage(item.uid) }
                .controlSize(.small)
        }
        .padding(12)
    }

    /// Edits route through updateImage so undo registration and time clamping
    /// stay in one place.
    private var itemBinding: Binding<ImageOverlayItem> {
        let model = store.builder
        let uid = item.uid
        let fallback = item
        return Binding(
            get: { model.imageItem(uid) ?? fallback },
            set: { value in model.updateImage(uid) { $0 = value } })
    }
}

struct TextInspector: View {
    @Environment(AppStore.self) private var store
    let item: TextOverlayItem

    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Overlay")
                .font(.headline)

            TextOverlayForm(item: itemBinding)

            Picker("Enter", selection: itemBinding.transIn) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Picker("Exit", selection: itemBinding.transOut) {
                ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            LabeledContent("Timing") {
                Text("\(item.startTime.timecode)–\(item.endTime.timecode)").monospacedDigit()
            }

            Divider()
            HStack {
                Button("Save as Template…", action: promptForTemplateName)
                    .controlSize(.small)
                    .help("Save this overlay's look to the Overlays library for reuse in the Builder and AI Wizard")
                Spacer()
                Button("Delete", role: .destructive) { store.builder.removeText(item.uid) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .alert("Save as Template", isPresented: $savingTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save", action: saveTemplate)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Templates appear in the Overlays section and in the AI Wizard's style palette.")
        }
        .alert("Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Edits route through updateText so undo registration and time clamping
    /// stay in one place.
    private var itemBinding: Binding<TextOverlayItem> {
        let model = store.builder
        let uid = item.uid
        let fallback = item
        return Binding(
            get: { model.textItem(uid) ?? fallback },
            set: { value in model.updateText(uid) { $0 = value } })
    }

    private func promptForTemplateName() {
        let firstLine = item.text.components(separatedBy: .newlines).first ?? ""
        templateName = OverlayTemplateStore.uniqueName(base: firstLine.isEmpty ? "Template" : firstLine)
        savingTemplate = true
    }

    private func saveTemplate() {
        let name = OverlayTemplateStore.uniqueName(base: templateName)
        // Template timing is relative to the composition start, and a text
        // saved from the Builder is the headline the AI Wizard may rewrite.
        var text = item
        text.startTime = 0
        text.endTime = max(0.5, item.duration)
        text.isDynamic = true
        do {
            try OverlayTemplateStore.save(OverlayTemplate(name: name,
                                                          composition: OverlayComposition(texts: [text])))
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A placed overlay-template block: timing controls plus a summary of the
/// snapshot it renders. The design itself is edited in the Overlays section
/// (and re-added, since placed blocks are snapshots).
struct OverlayBlockInspector: View {
    @Environment(AppStore.self) private var store
    let item: OverlayBlockItem

    var body: some View {
        let model = store.builder
        VStack(alignment: .leading, spacing: 12) {
            Label(item.name, systemImage: "square.2.layers.3d")
                .font(.headline)
                .lineLimit(1)

            Text("\(item.composition.texts.count) text(s) · \(item.composition.images.count) image(s)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("Start") {
                Text(item.startTime.timecode).monospacedDigit()
            }
            Stepper(value: Binding(
                get: { item.duration },
                set: { value in model.updateOverlayBlock(item.uid) { $0.duration = max(0.5, value) } }),
                in: 0.5...600, step: 0.5) {
                LabeledContent("Duration") {
                    Text(String(format: "%.1fs", item.duration)).monospacedDigit()
                }
            }

            Divider()

            Text("This block is a snapshot of the template as it was when added. Edit the design in the Overlays section and re-add it to pick up changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Delete Overlay", role: .destructive) {
                model.removeOverlayBlock(item.uid)
            }
        }
        .padding(12)
    }
}
