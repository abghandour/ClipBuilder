import SwiftUI

/// Source > Overlays: the saved overlay-design library. A template is a
/// composition of text and image items, each with its own look, timing, and
/// enter/exit effects. The editor shows a 9:16 preview that plays the
/// composition; in edit mode items are clickable and draggable to arrange.
/// Templates are inserted from the Builder's Text menu and offered to the AI
/// Wizard, which rewrites only texts marked dynamic.
struct OverlayTemplatesView: View {
    var runCounts: [String: Int] = [:]
    @Environment(AppStore.self) private var store
    @Environment(\.workspacePageVisible) private var pageVisible
    @State private var templates: [OverlayTemplate] = []
    @State private var selectedName: String?
    @State private var itemSelection: OverlayItemSelection?
    @State private var composition = OverlayComposition()
    @State private var watcher: FolderWatcher?
    @State private var saveTask: Task<Void, Never>?
    @State private var pendingSave: OverlayTemplate?
    @State private var isSaving = false

    @State private var renamePrompt = false
    @State private var renameText = ""
    @State private var deleteTarget: String?
    @State private var showOverlayWizard = false
    @State private var operationError: String?

    var body: some View {
        Group {
            if templates.isEmpty {
                ContentUnavailableView(
                    "No Overlay Templates",
                    systemImage: "square.on.square",
                    description: Text("Create a starter template, then add text and images only when you need them. Use the toolbar to create a template or extract one from an image."))
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        templateList
                        ControlGroup {
                            Button("Rename", systemImage: "pencil") {
                                renameText = selectedName ?? ""; renamePrompt = true
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                if let template = templates.first(where: { $0.name == selectedName }) { duplicate(template) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = selectedName }
                        }.labelStyle(.iconOnly).disabled(selectedName == nil).padding(8)
                        Divider()
                        if selectedName != nil {
                            OverlayTemplateItems(composition: $composition, selection: $itemSelection)
                                .frame(maxHeight: 300)
                        }
                    }
                        .rememberedPaneWidth("pane.textLooks.list", min: 200, initial: 232, max: 300)
                        .frame(maxHeight: .infinity)
                    if let selectedName, templates.contains(where: { $0.name == selectedName }) {
                        OverlayTemplateEditor(name: selectedName, composition: $composition, selection: $itemSelection)
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a Template", systemImage: "square.on.square",
                                               description: Text("Choose a template from the list to edit it."))
                            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        .toolbar { if pageVisible { overlayToolbarContent } }
        .sheet(isPresented: $showOverlayWizard) {
            OverlayWizardSheet()
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
        .onChange(of: store.createdOverlayName) { _, name in
            refresh()
            selectedName = name
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
            flushPendingSave()
            watcher?.stop()
            watcher = nil
            saveTask?.cancel()
        }
        .onChange(of: selectedName) { _, name in
            flushPendingSave()
            itemSelection = nil
            loadComposition(named: name)
        }
        .onChange(of: composition) {
            scheduleSave()
        }
    }

    private var templateList: some View {
        List(templates, selection: $selectedName) { template in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if let text = template.composition.texts.first {
                            LookCard(name: template.name, decor: text.applyingSharedStyle(store.activeProfile.textStyles ?? []).resolvedTextDecor,
                                     fontFamily: text.fontOverride, showsName: false)
                        }
                        Spacer(minLength: 0)
                        Text("\(runCounts[template.name] ?? 0)").font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                            .help("Wizard runs referencing this template")
                    }
                    Text(template.name).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    Text(summary(of: template.composition))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let provenance = template.composition.provenance {
                    AIInfoButton(provenance: provenance, role: "Extracted by", size: 12)
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

    @ToolbarContentBuilder
    private var overlayToolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: createTemplate) { ToolbarBubbleLabel(text: "New Template", systemImage: "plus") }
                .help("Create an overlay template")
            if selectedName != nil {
                    Label(isSaving ? "Saving…" : "Saved",
                          systemImage: isSaving ? "arrow.triangle.2.circlepath" : "checkmark")
                        .font(.caption)
                    .foregroundStyle(isSaving ? Color.secondary : Color.green)
            }
            Button {
                showOverlayWizard = true
            } label: {
                ToolbarBubbleLabel(text: "Create from Image…", systemImage: "wand.and.stars")
            }
            .help("Build an overlay template from a reference image")
            Button {
                NSWorkspace.shared.open(OverlayTemplateStore.directory)
            } label: {
                ToolbarBubbleLabel(text: "Show in Finder", systemImage: "folder")
            }
            .help("Reveal the template files in Finder")
        }
    }

    private func summary(of composition: OverlayComposition) -> String {
        var parts: [String] = []
        if !composition.texts.isEmpty { parts.append("\(composition.texts.count) text\(composition.texts.count == 1 ? "" : "s")") }
        if !composition.images.isEmpty { parts.append("\(composition.images.count) image\(composition.images.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private func refresh() {
        OverlayTemplateStore.invalidateCache()
        templates = OverlayTemplateStore.list()
        if let selectedName, !templates.contains(where: { $0.name == selectedName }) {
            self.selectedName = nil
        }
    }

    private func loadComposition(named name: String?) {
        guard let name else { return }
        for template in templates where template.name == name {
            composition = template.composition
            return
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
              let current = templates.first(where: { $0.name == selectedName }) else { return }
        guard current.composition != composition else {
            // Back to the saved value: drop any queued intermediate edit
            // instead of letting the debounce write it.
            if pendingSave?.name == selectedName {
                saveTask?.cancel()
                saveTask = nil
                pendingSave = nil
                isSaving = false
            }
            return
        }
        let snapshot = OverlayTemplate(name: selectedName, composition: composition)
        saveTask?.cancel()
        pendingSave = snapshot
        isSaving = true
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            pendingSave = nil
            do {
                try OverlayTemplateStore.save(snapshot)
                if let index = templates.firstIndex(where: { $0.name == snapshot.name }) {
                    templates[index].composition = snapshot.composition
                }
            } catch {
                operationError = error.localizedDescription
            }
            isSaving = false
        }
    }

    /// Navigation can happen before the debounce fires. Persist the latest
    /// snapshot instead of silently dropping the user's final adjustment.
    private func flushPendingSave() {
        guard let snapshot = pendingSave else { return }
        saveTask?.cancel()
        pendingSave = nil
        isSaving = false
        do {
            try OverlayTemplateStore.save(snapshot)
            if let index = templates.firstIndex(where: { $0.name == snapshot.name }) {
                templates[index].composition = snapshot.composition
            }
        } catch {
            operationError = error.localizedDescription
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
    @Binding var selection: OverlayItemSelection?

    var body: some View {
        HSplitView {
            TextLooksStage(composition: $composition, selection: $selection)
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            TextLooksOverlayInspector(composition: $composition, selection: $selection)
                .frame(width: 320).frame(maxHeight: .infinity)
        }
        .id(name)
    }
}

/// The item list stays beside the template library, leaving the preview pinned.
private struct OverlayTemplateItems: View {
    @Binding var composition: OverlayComposition
    @Binding var selection: OverlayItemSelection?
    @State private var showingImagePicker = false

    var body: some View { ScrollView { itemsSection.padding(8) } }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Items")
                    .font(.headline)
                Button("Add Text", systemImage: "textformat", action: addText)
                    .controlSize(.small).lineLimit(1).fixedSize()
                Button("Add Image", systemImage: "photo") {
                    showingImagePicker = true
                }
                .controlSize(.small).lineLimit(1).fixedSize()
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
                Text(title).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).lineLimit(1).fixedSize(horizontal: false, vertical: true)
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
    /// Draw the stage backdrop + thirds grid. False when the canvas sits over
    /// live video (the manual build's overlay preview).
    var backdrop: Bool = true
    /// Solid stage colour; a source frame draws over it when set, so text
    /// can be judged against real footage instead of black.
    var backdropColor: Color = .black
    var backdropFrame: OverlayStageBackdrop.Frame? = nil
    var dimUnselected = false

    var body: some View {
        GeometryReader { geo in
            let frame = geo.size
            let total = composition.duration
            ZStack(alignment: .topLeading) {
                if backdrop {
                    Rectangle().fill(backdropColor)
                    if let backdropFrame {
                        VideoThumbnail(url: backdropFrame.url, time: backdropFrame.time, cornerRadius: 0)
                            .frame(width: frame.width, height: frame.height)
                            .allowsHitTesting(false)
                    }
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
                            .opacity(effect.opacity * (dimUnselected && time == nil && selection != nil && selection != .image(item.uid) ? 0.35 : 1))
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
                            .opacity(effect.opacity * (dimUnselected && time == nil && selection != nil && selection != .text(item.uid) ? 0.35 : 1))
                            .offset(effect.offset)
                    }
                }
            }
            .coordinateSpace(name: "overlayCanvas")
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

/// Corner handle that scales the selected item: drag distance from the item's
/// center sets the scale factor, applied by the owner (font size for texts,
/// width fraction for images).
struct ResizeHandle: View {
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
    @Environment(AppStore.self) private var store
    @Binding var item: TextOverlayItem
    let frame: CGSize
    let isSelected: Bool
    let editable: Bool
    let onSelect: () -> Void

    @State private var dragStart: CGPoint?
    @State private var resizeBaseFontsize: Int?
    /// The box the export renderer drew (canvas pixels) and the item's
    /// fractional position at that render. The frame and raster follow the
    /// item live between renders by the position delta, so a drag never
    /// waits on the preview debounce.
    @State private var rendered: (box: CGRect?, position: CGPoint)?

    private var position: CGPoint { CGPoint(x: item.xFrac ?? 0.5, y: item.yFrac ?? 0.8) }

    private var center: CGPoint {
        CGPoint(x: frame.width * position.x, y: frame.height * position.y)
    }

    private var radius: CGFloat { (item.boxRadius ?? 4) * frame.width / 1080 }

    /// Stage-point offset of the current position from the rendered one.
    private var liveShift: CGSize {
        guard let rendered else { return .zero }
        return CGSize(width: (position.x - rendered.position.x) * frame.width,
                      height: (position.y - rendered.position.y) * frame.height)
    }

    var body: some View {
        if item.usesTextDecor { rasterBody } else { legacyBody }
    }

    /// Export-faithful raster with the selection frame on the drawn box, so
    /// the outline matches the text and a click on the text selects it.
    private var rasterBody: some View {
        let fallback = CGRect(x: center.x - frame.width * (item.wFrac ?? 0.6) / 2,
                              y: center.y - frame.height * (item.hFrac ?? 0.1) / 2,
                              width: frame.width * (item.wFrac ?? 0.6), height: frame.height * (item.hFrac ?? 0.1))
        let scale = frame.width / 1080
        let shift = liveShift
        let box = rendered?.box.map {
            CGRect(x: $0.minX * scale + shift.width, y: $0.minY * scale + shift.height,
                   width: $0.width * scale, height: $0.height * scale)
        } ?? fallback
        return ZStack(alignment: .topLeading) {
            TextOverlayRasterPreview(item: item, canvas: CGSize(width: 1080, height: 1080 * frame.height / max(1, frame.width)),
                                     onBox: { box in rendered = (box, position) })
                .frame(width: frame.width, height: frame.height)
                .offset(shift)
                .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(8, box.width), height: max(8, box.height))
                .overlay {
                    if isSelected && editable {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected && editable {
                        resizeHandle.offset(x: 6, y: 6)
                    }
                }
                .position(x: box.midX, y: box.midY)
                .gesture(dragGesture, isEnabled: editable)
                .onTapGesture(perform: onSelect)
                .contextMenu { styleClipboardMenu }
        }
        .frame(width: frame.width, height: frame.height)
    }

    /// Copy Style / Paste Style straight from the stage, same payload as the inspector.
    @ViewBuilder private var styleClipboardMenu: some View {
        Button("Copy Style") {
            TextStyleClipboard.write(TextStyleClipboard.payload(
                stored: item.decor, inherited: item.applyingSharedStyle(store.activeProfile.textStyles ?? []).resolvedTextDecor,
                fontFamily: item.fontOverride, sharedStyleID: item.sharedStyleID, source: "overlay"))
        }
        Button("Paste Style") {
            guard let payload = TextStyleClipboard.read() else { return }
            let pasted = TextStyleClipboard.pasted(payload, onto: item.decor, linkShared: true)
            item.decor = pasted.decor
            item.sharedStyleID = pasted.sharedStyleID ?? item.sharedStyleID
            item.fontOverride = pasted.fontFamily
        }
        .disabled(TextStyleClipboard.read() == nil)
    }

    private var legacyBody: some View {
        let (r, g, b) = TextOverlayRenderer.parseColor(item.fontcolor)
        return Text(item.text.isEmpty ? "Text" : item.text)
            .font(font)
            .bold(item.bold)
            .italic(item.italic)
            .underline(item.resolvedUnderline)
            .strikethrough(item.resolvedStrikethrough)
            .foregroundStyle(Color(red: r, green: g, blue: b))
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: item.wFrac.map { frame.width * $0 }, alignment: frameAlignment)
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
                    resizeHandle.offset(x: 6, y: 6)
                }
            }
            .position(center)
            .gesture(dragGesture, isEnabled: editable)
            .onTapGesture(perform: onSelect)
    }

    private var resizeHandle: some View {
        ResizeHandle(center: center, onScale: { factor in
            if resizeBaseFontsize == nil { resizeBaseFontsize = item.fontsize }
            if let base = resizeBaseFontsize {
                item.fontsize = min(200, max(10, Int((Double(base) * factor).rounded())))
            }
        }, onEnd: { resizeBaseFontsize = nil })
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

    private var textAlignment: TextAlignment {
        switch item.alignment {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
    }

    private var frameAlignment: Alignment {
        switch item.alignment {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
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
            image = await ImageCache.image(for: item.url, maxPixel: 960)
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
