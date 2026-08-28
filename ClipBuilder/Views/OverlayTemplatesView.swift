import SwiftUI

/// Source > Overlays: the saved overlay-design library. A template is a
/// composition of text and image items, each with its own look, timing, and
/// enter/exit effects. The editor shows a 9:16 preview that plays the
/// composition; in edit mode items are clickable and draggable to arrange.
/// Templates are inserted from the Builder's Text menu and offered to the AI
/// Wizard, which rewrites only texts marked dynamic.
struct OverlayTemplatesView: View {
    @State private var templates: [OverlayTemplate] = []
    @State private var selectedName: String?
    @State private var composition = OverlayComposition()
    @State private var watcher: FolderWatcher?
    @State private var saveTask: Task<Void, Never>?

    @State private var renamePrompt = false
    @State private var renameText = ""
    @State private var deleteTarget: String?
    @State private var showOverlayWizard = false
    @State private var operationError: String?

    var body: some View {
        Group {
            if templates.isEmpty {
                ContentUnavailableView {
                    Label("No Overlay Templates", systemImage: "character.textbox")
                } description: {
                    Text("Design an overlay once — texts and images with their own timing and effects — and reuse it everywhere: templates can be inserted in the Builder and picked by the AI Wizard.")
                } actions: {
                    Button("New Template", action: createTemplate)
                    Button("Overlay Wizard…") { showOverlayWizard = true }
                }
            } else {
                HSplitView {
                    templateList
                        .rememberedPaneWidth("pane.overlays.templates", min: 200, initial: 230, max: 300)
                        .frame(maxHeight: .infinity)
                    if let selectedName, templates.contains(where: { $0.name == selectedName }) {
                        OverlayTemplateEditor(name: selectedName, composition: $composition)
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a Template", systemImage: "character.textbox",
                                               description: Text("Choose a template from the list to edit it."))
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Overlays")
        .navigationSubtitle("\(templates.count) template\(templates.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItemGroup {
                Button("New Template", systemImage: "plus", action: createTemplate)
                    .help("Create an overlay template")
                Button("Overlay Wizard", systemImage: "wand.and.stars") {
                    showOverlayWizard = true
                }
                .help("Extract an overlay design from a reference image with AI")
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(OverlayTemplateStore.directory)
                }
                .help("Open the overlay templates folder in Finder")
            }
        }
        .sheet(isPresented: $showOverlayWizard) {
            OverlayWizardSheet { name in
                refresh()
                selectedName = name
            }
        }
        .alert("Rename Template", isPresented: $renamePrompt) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameSelected)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Error", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(
            "Move “\(deleteTarget ?? "template")” to the Trash?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Move to Trash", role: .destructive, action: deleteConfirmed)
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .onAppear {
            try? FileManager.default.createDirectory(at: OverlayTemplateStore.directory,
                                                     withIntermediateDirectories: true)
            refresh()
            let watcher = FolderWatcher { refresh() }
            watcher.watch(OverlayTemplateStore.directory)
            self.watcher = watcher
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            saveTask?.cancel()
        }
        .onChange(of: selectedName) { _, name in
            if let template = templates.first(where: { $0.name == name }) {
                composition = template.composition
            }
        }
        .onChange(of: composition) {
            scheduleSave()
        }
    }

    private var templateList: some View {
        List(templates, selection: $selectedName) { template in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                    Text(summary(of: template.composition))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let provenance = template.composition.provenance {
                    ProvenanceBadge(provenance: provenance, role: "Extracted by", size: 12)
                }
            }
            .tag(template.name)
            .contextMenu {
                Button("Rename…") {
                    renameText = template.name
                    selectedName = template.name
                    renamePrompt = true
                }
                Button("Duplicate") { duplicate(template) }
                Divider()
                Button("Move to Trash", role: .destructive) { deleteTarget = template.name }
            }
        }
        .listStyle(.inset)
    }

    private func summary(of composition: OverlayComposition) -> String {
        var parts: [String] = []
        if !composition.texts.isEmpty { parts.append("\(composition.texts.count) text\(composition.texts.count == 1 ? "" : "s")") }
        if !composition.images.isEmpty { parts.append("\(composition.images.count) image\(composition.images.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private func refresh() {
        templates = OverlayTemplateStore.list()
        if let selectedName, !templates.contains(where: { $0.name == selectedName }) {
            self.selectedName = nil
        }
    }

    private func createTemplate() {
        var text = TextOverlayItem(text: "Headline", startTime: 0, endTime: 3)
        text.xFrac = 0.5
        text.yFrac = 0.5
        text.isDynamic = true
        let name = OverlayTemplateStore.uniqueName(base: "Template")
        perform {
            try OverlayTemplateStore.save(OverlayTemplate(name: name,
                                                          composition: OverlayComposition(texts: [text])))
        }
        selectedName = name
    }

    private func duplicate(_ template: OverlayTemplate) {
        let name = OverlayTemplateStore.uniqueName(base: template.name)
        perform { try OverlayTemplateStore.save(OverlayTemplate(name: name, composition: template.composition)) }
    }

    private func renameSelected() {
        guard let selectedName else { return }
        perform {
            let final = try OverlayTemplateStore.rename(selectedName, to: renameText)
            self.selectedName = final
        }
    }

    private func deleteConfirmed() {
        if let deleteTarget {
            perform { try OverlayTemplateStore.delete(name: deleteTarget) }
        }
        deleteTarget = nil
    }

    /// Debounced auto-save: drags emit a change per mouse move, one write per
    /// pause is plenty (and keeps the folder watcher from thrashing).
    private func scheduleSave() {
        guard let selectedName,
              let current = templates.first(where: { $0.name == selectedName }),
              current.composition != composition else { return }
        let snapshot = OverlayTemplate(name: selectedName, composition: composition)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                try OverlayTemplateStore.save(snapshot)
                if let index = templates.firstIndex(where: { $0.name == snapshot.name }) {
                    templates[index].composition = snapshot.composition
                }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            refresh()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

/// Which composition item is selected in the editor/preview.
enum OverlayItemSelection: Equatable {
    case text(UUID)
    case image(UUID)
}

/// Editor for one template: animated 9:16 preview on the left (click to
/// select, drag to arrange, Play to watch the effects), item list + selected
/// item's controls on the right.
struct OverlayTemplateEditor: View {
    let name: String
    @Binding var composition: OverlayComposition

    @State private var selection: OverlayItemSelection?
    @State private var playbackStart: Date?
    @State private var showingImagePicker = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            previewColumn
                .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    itemsSection
                    Divider()
                    selectedItemForm
                }
                .padding()
                .frame(maxWidth: 440, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: name) {
            selection = nil
            playbackStart = nil
        }
    }

    // MARK: - Preview

    private var previewColumn: some View {
        VStack(spacing: 10) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
            Group {
                if let playbackStart {
                    // SwiftUI.TimelineView: the app has its own TimelineView
                    // (the Builder timeline), which shadows the name.
                    SwiftUI.TimelineView(.animation) { context in
                        let total = max(0.5, composition.duration)
                        let time = context.date.timeIntervalSince(playbackStart)
                            .truncatingRemainder(dividingBy: total)
                        OverlayPreviewCanvas(composition: $composition, selection: $selection,
                                             time: time)
                    }
                } else {
                    OverlayPreviewCanvas(composition: $composition, selection: $selection,
                                         time: nil)
                }
            }
            .frame(width: 270, height: 480)

            HStack {
                Button {
                    playbackStart = playbackStart == nil ? Date() : nil
                } label: {
                    Label(playbackStart == nil ? "Play" : "Stop",
                          systemImage: playbackStart == nil ? "play.fill" : "stop.fill")
                }
                .disabled(composition.isEmpty)
                Text(String(format: "%.1fs loop", composition.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(playbackStart == nil
                 ? "Click an item to select it; drag to reposition."
                 : "Playing the composition with its enter/exit effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 270)
        }
    }

    // MARK: - Item list

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Items")
                    .font(.headline)
                Spacer()
                Button("Add Text", systemImage: "textformat", action: addText)
                    .controlSize(.small)
                Button("Add Image", systemImage: "photo") {
                    showingImagePicker = true
                }
                .controlSize(.small)
                .sheet(isPresented: $showingImagePicker) {
                    ImagePickerSheet { urls in
                        for url in urls { addImage(path: url.path) }
                    }
                }
            }
            ForEach(composition.texts) { item in
                itemRow(icon: "textformat",
                        title: item.text.isEmpty ? "(empty text)" : item.text,
                        subtitle: timingLabel(item.startTime, item.endTime, unbounded: item.unbounded)
                            + (item.isDynamic ? " · AI text" : ""),
                        selected: selection == .text(item.uid)) {
                    selection = .text(item.uid)
                } onDelete: {
                    composition.texts.removeAll { $0.uid == item.uid }
                    if selection == .text(item.uid) { selection = nil }
                }
            }
            ForEach(composition.images) { item in
                itemRow(icon: "photo",
                        title: item.displayName,
                        subtitle: timingLabel(item.startTime, item.endTime, unbounded: item.unbounded),
                        selected: selection == .image(item.uid)) {
                    selection = .image(item.uid)
                } onDelete: {
                    composition.images.removeAll { $0.uid == item.uid }
                    if selection == .image(item.uid) { selection = nil }
                }
            }
            if composition.isEmpty {
                Text("Add texts and images to design this overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timingLabel(_ start: Double, _ end: Double, unbounded: Bool) -> String {
        unbounded ? String(format: "%.1fs–∞", start) : String(format: "%.1f–%.1fs", start, end)
    }

    private func itemRow(icon: String, title: String, subtitle: String, selected: Bool,
                         onSelect: @escaping () -> Void,
                         onDelete: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete", systemImage: "trash", action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    // MARK: - Selected item form

    @ViewBuilder
    private var selectedItemForm: some View {
        switch selection {
        case .text(let uid):
            if let index = composition.texts.firstIndex(where: { $0.uid == uid }) {
                let binding = $composition.texts[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text("Text Item")
                        .font(.headline)
                    timingControls(start: binding.startTime, end: binding.endTime,
                                   transIn: binding.transIn, transOut: binding.transOut,
                                   unbounded: binding.unbounded)
                    Toggle("AI Wizard may replace this text", isOn: binding.isDynamic)
                        .help("When on, the wizard writes its own copy into this text; static texts and images always render exactly as designed")
                    TextOverlayForm(item: binding)
                }
            }
        case .image(let uid):
            if let index = composition.images.firstIndex(where: { $0.uid == uid }) {
                let binding = $composition.images[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text("Image Item")
                        .font(.headline)
                    timingControls(start: binding.startTime, end: binding.endTime,
                                   transIn: binding.transIn, transOut: binding.transOut,
                                   unbounded: binding.unbounded)
                    ImageOverlayControls(item: binding, name: composition.images[index].displayName)
                }
            }
        case nil:
            Text("Select an item to edit its look, timing, and effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Timing on the composition's own clock (t=0 is when the overlay begins
    /// in the video), with the matching effect beside each field: the appear
    /// effect plays at Start, the disappear effect as the duration ends.
    private func timingControls(start: Binding<Double>, end: Binding<Double>,
                                transIn: Binding<String>, transOut: Binding<String>,
                                unbounded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Stepper(String(format: "Start: %.1fs", start.wrappedValue),
                        value: Binding(
                            get: { start.wrappedValue },
                            set: { newStart in
                                let duration = end.wrappedValue - start.wrappedValue
                                start.wrappedValue = max(0, newStart)
                                end.wrappedValue = start.wrappedValue + duration
                            }),
                        in: 0...120, step: 0.5)
                Spacer()
                effectPicker("Appear", selection: transIn)
            }
            HStack(spacing: 12) {
                if unbounded.wrappedValue {
                    Text("Duration: unbounded")
                } else {
                    Stepper(String(format: "Duration: %.1fs", end.wrappedValue - start.wrappedValue),
                            value: Binding(
                                get: { end.wrappedValue - start.wrappedValue },
                                set: { end.wrappedValue = start.wrappedValue + max(0.5, $0) }),
                            in: 0.5...120, step: 0.5)
                }
                Spacer()
                effectPicker("Disappear", selection: transOut)
            }
            Toggle("Unbounded — stays as long as the overlay is visible", isOn: unbounded)
                .font(.caption)
        }
        .font(.callout)
    }

    private func effectPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(TextOverlayItem.transitionChoices, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .fixedSize()
    }

    // MARK: - Add items

    private func addText() {
        var item = TextOverlayItem(text: "Text", startTime: 0,
                                   endTime: max(3, composition.duration))
        item.xFrac = 0.5
        item.yFrac = composition.texts.isEmpty ? 0.5 : 0.7
        composition.texts.append(item)
        selection = .text(item.uid)
    }

    private func addImage(path: String) {
        var item = ImageOverlayItem(path: path, startTime: 0,
                                    endTime: max(3, composition.duration))
        item.yFrac = 0.3
        composition.images.append(item)
        selection = .image(item.uid)
    }
}

// MARK: - Preview canvas

/// The 9:16 stage. `time == nil` is edit mode: every item is visible,
/// clickable, and draggable. With a time, items appear inside their windows
/// with fade/slide/pop enter and exit effects approximated from the renderer.
struct OverlayPreviewCanvas: View {
    @Binding var composition: OverlayComposition
    @Binding var selection: OverlayItemSelection?
    let time: Double?
    /// Draw the black stage + thirds grid. False when the canvas sits over
    /// live video (the curated wizard's overlay preview).
    var backdrop: Bool = true

    var body: some View {
        GeometryReader { geo in
            let frame = geo.size
            let total = composition.duration
            ZStack(alignment: .topLeading) {
                if backdrop {
                    Rectangle().fill(.black)
                    // Faint thirds grid to help placement.
                    Path { path in
                        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                            path.move(to: CGPoint(x: frame.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: frame.width * fraction, y: frame.height))
                            path.move(to: CGPoint(x: 0, y: frame.height * fraction))
                            path.addLine(to: CGPoint(x: frame.width, y: frame.height * fraction))
                        }
                    }
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                }

                ForEach($composition.images) { $item in
                    let end = item.unbounded ? max(total, item.startTime + 0.5) : item.endTime
                    if let effect = OverlayEffect.at(time: time, start: item.startTime,
                                                    end: end, transIn: item.transIn,
                                                    transOut: item.transOut, canvas: frame) {
                        PreviewImageLayer(item: $item, frame: frame,
                                          isSelected: selection == .image(item.uid),
                                          editable: time == nil,
                                          onSelect: { selection = .image(item.uid) })
                            .opacity(effect.opacity)
                            .offset(effect.offset)
                    }
                }
                ForEach($composition.texts) { $item in
                    let end = item.unbounded ? max(total, item.startTime + 0.5) : item.endTime
                    if let effect = OverlayEffect.at(time: time, start: item.startTime,
                                                    end: end, transIn: item.transIn,
                                                    transOut: item.transOut, canvas: frame) {
                        PreviewTextLayer(item: $item, frame: frame,
                                         isSelected: selection == .text(item.uid),
                                         editable: time == nil,
                                         onSelect: { selection = .text(item.uid) })
                            .opacity(effect.opacity)
                            .offset(effect.offset)
                    }
                }
            }
            .coordinateSpace(name: "overlayCanvas")
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

/// Corner handle that scales the selected item: drag distance from the item's
/// center sets the scale factor, applied by the owner (font size for texts,
/// width fraction for images).
private struct ResizeHandle: View {
    let center: CGPoint
    let onScale: (Double) -> Void

    var onEnd: () -> Void = {}

    @State private var startDistance: CGFloat?

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .contentShape(Circle().inset(by: -6))
            .gesture(
                DragGesture(coordinateSpace: .named("overlayCanvas"))
                    .onChanged { value in
                        let distance = hypot(value.location.x - center.x,
                                             value.location.y - center.y)
                        if startDistance == nil {
                            startDistance = hypot(value.startLocation.x - center.x,
                                                  value.startLocation.y - center.y)
                        }
                        guard let start = startDistance, start > 4 else { return }
                        onScale(distance / start)
                    }
                    .onEnded { _ in
                        startDistance = nil
                        onEnd()
                    }
            )
            .help("Drag to resize")
    }
}

/// Visibility + enter/exit transform of one item at a playback time,
/// mirroring the ffmpeg expressions (0.4s animation, fade = alpha ramp,
/// slide = from/to the frame edge, pop = rise-settle + fade).
private struct OverlayEffect {
    var opacity: Double = 1
    var offset: CGSize = .zero

    /// nil = hidden at this time. `time == nil` (edit mode) is always fully
    /// visible.
    static func at(time: Double?, start: Double, end: Double,
                   transIn: String, transOut: String, canvas: CGSize) -> OverlayEffect? {
        guard let time else { return OverlayEffect() }
        guard end > start, time >= start, time < end else { return nil }
        let anim = min(0.4, (end - start) / 3)
        var effect = OverlayEffect()
        if anim > 0, time - start < anim {
            effect.apply(transIn, remaining: 1 - (time - start) / anim, entering: true, canvas: canvas)
        } else if anim > 0, end - time < anim {
            effect.apply(transOut, remaining: 1 - (end - time) / anim, entering: false, canvas: canvas)
        }
        return effect
    }

    /// `remaining` runs 1 → 0 across an enter, 0 → 1 across an exit.
    private mutating func apply(_ transition: String, remaining: Double,
                                entering: Bool, canvas: CGSize) {
        switch transition {
        case "fade":
            opacity = 1 - remaining
        case "pop":
            opacity = 1 - remaining
            offset.height = canvas.height * 0.05 * pow(remaining, 3)
        case "slide_left":
            offset.width = (entering ? 1 : -1) * canvas.width * remaining
        case "slide_right":
            offset.width = (entering ? -1 : 1) * canvas.width * remaining
        case "slide_up":
            offset.height = (entering ? 1 : -1) * canvas.height * remaining
        case "slide_down":
            offset.height = (entering ? -1 : 1) * canvas.height * remaining
        default:
            break   // cut
        }
    }
}

/// A text item on the stage — the same SwiftUI approximation the Builder
/// preview uses (the render is the source of truth).
private struct PreviewTextLayer: View {
    @Binding var item: TextOverlayItem
    let frame: CGSize
    let isSelected: Bool
    let editable: Bool
    let onSelect: () -> Void

    @State private var dragStart: CGPoint?
    @State private var resizeBaseFontsize: Int?

    var body: some View {
        let (r, g, b) = TextOverlayRenderer.parseColor(item.fontcolor)
        let radius = (item.boxRadius ?? 4) * frame.width / 1080
        let center = CGPoint(x: frame.width * (item.xFrac ?? 0.5),
                             y: frame.height * (item.yFrac ?? 0.8))
        Text(item.text.isEmpty ? "Text" : item.text)
            .font(font)
            .bold(item.bold)
            .italic(item.italic)
            .foregroundStyle(Color(red: r, green: g, blue: b))
            .padding(4)
            .background(item.boxOpacity > 0 ? backgroundColor.opacity(item.boxOpacity) : .clear,
                        in: RoundedRectangle(cornerRadius: radius))
            .opacity(item.opacity)
            .overlay {
                if isSelected && editable {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected && editable {
                    ResizeHandle(center: center, onScale: { factor in
                        if resizeBaseFontsize == nil { resizeBaseFontsize = item.fontsize }
                        if let base = resizeBaseFontsize {
                            item.fontsize = min(200, max(10, Int((Double(base) * factor).rounded())))
                        }
                    }, onEnd: { resizeBaseFontsize = nil })
                        .offset(x: 6, y: 6)
                }
            }
            .position(center)
            .gesture(dragGesture, isEnabled: editable)
            .onTapGesture(perform: onSelect)
    }

    private var font: Font {
        let size = CGFloat(item.fontsize) * frame.width / 1080
        if let family = item.fontfamily, !family.isEmpty {
            return .custom(family, size: size)
        }
        return .system(size: size)
    }

    private var backgroundColor: Color {
        let (r, g, b) = TextOverlayRenderer.parseColor(item.bgcolor, fallback: (0, 0, 0))
        return Color(red: r, green: g, blue: b)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = CGPoint(x: item.xFrac ?? 0.5, y: item.yFrac ?? 0.8)
                    onSelect()
                }
                guard let start = dragStart else { return }
                item.xFrac = min(max(start.x + value.translation.width / frame.width, 0), 1)
                item.yFrac = min(max(start.y + value.translation.height / frame.height, 0), 1)
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// An image item on the stage.
private struct PreviewImageLayer: View {
    @Binding var item: ImageOverlayItem
    let frame: CGSize
    let isSelected: Bool
    let editable: Bool
    let onSelect: () -> Void

    @State private var image: NSImage?
    @State private var dragStart: CGPoint?
    @State private var resizeBaseWFrac: Double?

    var body: some View {
        let width = frame.width * item.wFrac
        let height = image.map { width * $0.size.height / max(1, $0.size.width) } ?? width
        let center = CGPoint(x: frame.width * item.xFrac, y: frame.height * item.yFrac)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .opacity(item.opacity)
        .overlay {
            if isSelected && editable {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected && editable {
                ResizeHandle(center: center, onScale: { factor in
                    if resizeBaseWFrac == nil { resizeBaseWFrac = item.wFrac }
                    if let base = resizeBaseWFrac {
                        item.wFrac = min(1, max(0.05, base * factor))
                    }
                }, onEnd: { resizeBaseWFrac = nil })
                    .offset(x: 6, y: 6)
            }
        }
        .position(center)
        .gesture(dragGesture, isEnabled: editable)
        .onTapGesture(perform: onSelect)
        .task(id: item.path) {
            image = NSImage(contentsOf: item.url)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = CGPoint(x: item.xFrac, y: item.yFrac)
                    onSelect()
                }
                guard let start = dragStart else { return }
                item.xFrac = min(max(start.x + value.translation.width / frame.width, 0), 1)
                item.yFrac = min(max(start.y + value.translation.height / frame.height, 0), 1)
            }
            .onEnded { _ in dragStart = nil }
    }
}
