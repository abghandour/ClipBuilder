import SwiftUI
import UniformTypeIdentifiers

/// Clip Builder: scene browser on the left; preview + inspector above the
/// multi-track timeline on the right; Generate renders through the
/// multitrack pipeline into the Library.
struct BuilderView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    @State private var playingClip: TimelineClip?
    @State private var showLog = false
    @State private var showPreview = false
    @State private var showScenePicker = false
    @State private var showBRollPicker = false
    @AppStorage("builder.browserTab") private var browserTab = "scenes"
    @State private var pickerFind: BuilderWizardPickerRequest?
    @State private var wizardModel: WizardSheetModel?
    @State private var pendingPickerPreview: WizardSheetModel?
    @State private var showImagePicker = false
    @State private var confirmClear = false
    #if DEBUG
    @State private var showScriptPreview = false
    #endif

    var body: some View {
        let model = store.builder
        HSplitView {
            ClipBrowserPane(selectedTab: $browserTab, wizardModel: wizardModel,
                            discardWizard: discardWizard, openWizardPicker: openWizardPicker)
                .rememberedPaneWidth("pane.builder.browser", min: 250, initial: 300, max: 480)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                HSplitView {
                    BuilderWorkspacePreview(onOpenPreview: { showPreview = true },
                                            onAddClip: { showScenePicker = true })
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    BuilderInspector()
                        .rememberedPaneWidth("pane.builder.inspector", min: 240, initial: 310, max: 460)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                Divider()
                controlsBar
                if let result = store.builderPlanResult, result.matches(store: store) {
                    HStack {
                        Text("Plan ready").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Fix with Wizard…", systemImage: "wand.and.stars") {
                            if let preview = result.makeWizard(store: store) { showWizard(preview) }
                        }
                        .labelStyle(.iconOnly)
                        .help("Fix with Wizard… Preview an editing request on this planned timeline, then Apply manually.")
                    }
                    .padding(.horizontal, Theme.spaceM)
                    .padding(.bottom, Theme.spaceS)
                }
                Divider()

                TimelineView(onPlayClip: { playingClip = $0 })
                    .frame(minHeight: 200, idealHeight: 260, maxHeight: 340)
                    .layoutPriority(2)

                if renderLogVisible {
                    Divider()
                    logDrawer
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Button("Show Wizard") {
                browserTab = "wizard"
                ensureWizard()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .help("Switch to the Wizard tab. ⇧⌘W.")
            .disabled(store.openTimelineID == nil)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .overlay {
            if store.isPlanningIntoBuilder {
                PrefillProgressOverlay()
            }
        }
        .screenTitle(store.openTimeline?.name ?? "Timeline", subtitle: "\(store.activeProject?.name ?? "Project") · \(model.document.videoTrack.count) clips · \(model.totalDuration.timecode)")
        .toolbar {
            // The open timeline's name is the switcher: every timeline in the
            // project is one click away, the same way the sidebar header
            // switches projects.
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(store.switchableTimelines) { timeline in
                        Button {
                            store.switchTimeline(to: timeline)
                        } label: {
                            if timeline.id == store.openTimelineID {
                                Label(timeline.name, systemImage: "checkmark")
                            } else {
                                Text(timeline.name)
                            }
                        }
                    }
                    Divider()
                    Button("New Timeline", systemImage: "plus") {
                        store.createTimeline()
                    }
                    if let timeline = store.openTimeline {
                        Button("Duplicate This Timeline", systemImage: "plus.square.on.square") {
                            store.duplicateTimeline(timeline, openCopy: true)
                        }
                    }
                    Divider()
                    #if DEBUG
                    Button("Run JavaScript File…", systemImage: "curlybraces") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.javaScript]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            let wizard = WizardSheetModel(store: store)
                            showWizard(wizard)
                            do {
                                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                                guard data.count <= 256 * 1024, let source = String(data: data, encoding: .utf8) else {
                                    throw ScriptError.invalid("Expected a UTF-8 JavaScript file of at most 256 KiB.")
                                }
                                wizard.beginJavaScript(source: source)
                            } catch { wizard.refuseJavaScriptFile(error) }
                        }
                    }
                    .help("Run a JavaScript file with header defaults, then review and Apply manually.")
                    Button("Preview JSON Script…", systemImage: "curlybraces") {
                        showScriptPreview = true
                    }
                    .help("Run a JSON script in an isolated session and inspect its diff.")
                    #endif
                    Button("All Timelines…", systemImage: "list.bullet") {
                        store.closeTimeline()
                    }
                } label: {
                    Label(store.openTimeline?.name ?? "Timeline", systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Switch to another timeline in this project, or create one. ⌥⌘[ and ⌥⌘] cycle.")
            }
            ToolbarItem {
                Button {
                    showLog.toggle()
                } label: {
                    ToolbarBubbleLabel(text: "Log", systemImage: "text.alignleft")
                }
                .help("Show the render log")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    ToolbarBubbleLabel(text: "Clear", systemImage: "trash")
                }
                .disabled(model.document.isEmpty)
                .help("Remove everything from the timeline")
            }
            ToolbarItem(placement: .primaryAction) {
                if store.isBuilderRendering {
                    Button {
                        store.cancelBuilderRender()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            ToolbarBubbleLabel(text: "Stop", systemImage: "stop.circle")
                        }
                    }
                    .help("Stop the render")
                } else {
                    Button {
                        showLog = true
                        store.renderBuilderTimeline()
                    } label: {
                        ToolbarBubbleLabel(text: "Render to Library", systemImage: "play.rectangle.fill")
                    }
                    .disabled(model.document.videoTrack.isEmpty || store.isBuilderPreviewRendering)
                    .help(store.isBuilderPreviewRendering
                          ? "Wait for the temporary Render Preview to finish"
                          : "Render the timeline to a video in the Library")
                }
            }
        }
        .confirmationDialog("Clear the timeline?", isPresented: $confirmClear) {
            Button("Clear Timeline", role: .destructive) {
                model.clear()
            }
        } message: {
            Text("Removes every clip, music block, and text overlay. You can undo this with ⌘Z.")
        }
        .onAppear {
            model.undoManager = undoManager
            wizardModel = store.builderWizard
            if browserTab == "wizard" { ensureWizard() }
        }
        .onChange(of: browserTab) { _, tab in
            if tab == "wizard" { ensureWizard() }
        }
        .onChange(of: wizardModel?.identityMatches) { _, matches in
            if matches == false, wizardModel?.identityMatches == false {
                wizardModel?.dismiss()
                wizardModel = nil
                if browserTab == "wizard" { ensureWizard() }
            }
        }
        .task(id: wizardModel.map { ObjectIdentifier($0) }) {
            guard let wizardModel else { return }
            await wizardModel.refreshExamples()
            await wizardModel.refreshBeforeVersion()
        }
        .onChange(of: undoManager) { _, manager in
            model.undoManager = manager
        }
        .sheet(item: $playingClip) { clip in
            PlayerSheet(url: model.sourceURL(for: clip) ?? URL(fileURLWithPath: "/"),
                        title: model.scene(for: clip)?.videoFilename ?? "Clip",
                        startTime: clip.sourceStart ?? 0,
                        endTime: (clip.sourceStart ?? 0) + clip.duration)
        }
        .sheet(isPresented: $showPreview) {
            TimelinePreviewSheet()
        }
        .sheet(isPresented: $showScenePicker) {
            BuilderScenePickerSheet()
        }
        .onChange(of: store.builderPlanResult?.id, initial: true) { _, _ in
            if let result = store.builderPlanResult, result.openRequested,
               let preview = result.makeWizard(store: store) {
                store.builderPlanResult?.openRequested = false
                showWizard(preview)
            }
        }
        .sheet(isPresented: $showBRollPicker, onDismiss: {
            pickerFind = nil
            if let preview = pendingPickerPreview {
                pendingPickerPreview = nil
                showWizard(preview)
            }
        }) {
            BuilderBRollPickerSheet(wizardFind: pickerFind) { pendingPickerPreview = $0 }
        }
        .onChange(of: model.brollRequest) { _, request in
            if request != nil { showBRollPicker = true }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerSheet { urls in
                for url in urls { model.addImage(path: url.path) }
            }
        }
        #if DEBUG
        .sheet(isPresented: $showScriptPreview) { BuilderScriptDebugView() }
        #endif
        .onDeleteCommand {
            deleteSelection()
        }
    }

    private var renderLogVisible: Bool {
        showLog || store.isBuilderRendering || store.isBuilderPreviewRendering
    }

    private func ensureWizard() {
        if let wizardModel, wizardModel.identityMatches { return }
        wizardModel?.dismiss()
        wizardModel = nil
        guard store.openTimelineID != nil else { return }
        let model = WizardSheetModel(store: store)
        wizardModel = model
        store.builderWizard = model
    }

    private func showWizard(_ model: WizardSheetModel) {
        if wizardModel !== model { wizardModel?.dismiss() }
        wizardModel = model
        store.builderWizard = model
        browserTab = "wizard"
    }

    private func discardWizard() {
        wizardModel?.dismiss()
        wizardModel = nil
        browserTab = "scenes"
    }

    private func openWizardPicker(_ request: BuilderWizardPickerRequest) {
        pickerFind = request
        store.builder.brollRequest = .init(time: request.time, track: request.track)
        showBRollPicker = true
    }

    // MARK: - Controls bar

    private var controlsBar: some View {
        let model = store.builder
        return HStack(spacing: Theme.spaceM) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            BuilderAddMenu(showScenePicker: $showScenePicker,
                           showImagePicker: $showImagePicker,
                           showBRollPicker: $showBRollPicker)

            Divider().frame(height: 16)

            CropStyleMenu()

            Menu {
                Picker("Canvas", selection: Binding(
                    get: { model.document.renderSettings.preset },
                    set: { preset in
                        var settings = model.document.renderSettings
                        settings.preset = preset
                        model.setRenderSettings(settings)
                    })) {
                    ForEach(RenderPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("Quality", selection: Binding(
                    get: { model.document.renderSettings.quality },
                    set: { quality in
                        var settings = model.document.renderSettings
                        settings.quality = quality
                        model.setRenderSettings(settings)
                    })) {
                    ForEach(EncodeQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
            } label: {
                Label(model.document.renderSettings.preset.label, systemImage: "aspectratio")
            }
            .help("Output canvas and encode quality for this timeline")

            Menu {
                Picker("Cadence", selection: Binding(
                    get: { model.document.pacing.cadence },
                    set: { cadence in
                        var pacing = model.document.pacing
                        pacing.cadence = cadence
                        model.setPacing(pacing)
                    })) {
                    ForEach(CutCadence.allCases) { cadence in
                        Text(cadence.label).tag(cadence)
                    }
                }
                Picker("Curve", selection: Binding(
                    get: { model.document.pacing.curve },
                    set: { curve in
                        var pacing = model.document.pacing
                        pacing.curve = curve
                        model.setPacing(pacing)
                    })) {
                    ForEach(PaceCurve.allCases) { curve in
                        Text(curve.label).tag(curve)
                    }
                }
            } label: {
                Label(model.document.pacing.cadence.label, systemImage: "metronome")
            }
            .help("Cadence guide shown on the timeline ruler")

            Spacer()

            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { model.pointsPerSecond },
                set: { model.pointsPerSecond = $0 }),
                in: 20...200)
                .frame(width: 140)
                .accessibilityLabel("Timeline zoom")
                .accessibilityValue("\(Int(model.pointsPerSecond)) points per second")
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.spaceM)
        .padding(.vertical, Theme.spaceS)
    }

    // MARK: - Log drawer

    private var logDrawer: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Render Log")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                LogActions(lines: store.builderLog) { store.builderLog = [] }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            ActivityLogView(lines: \.builderLog)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .frame(height: 130)
        .background(.background.secondary)
    }

    private func deleteSelection() {
        let model = store.builder
        switch model.selection {
        case .clip(let uid): model.removeClip(uid)
        case .sound(let uid): model.removeSound(uid)
        case .text(let uid): model.removeText(uid)
        case .image(let uid): model.removeImage(uid)
        case .overlay(let uid): model.removeOverlayBlock(uid)
        case .crop(let uid): model.removeCropBlock(uid)
        case nil: break
        }
    }
}

/// Crop style for the selected block, or the one under the playhead. Its
/// own view because it reads the playhead: inline in the controls bar it
/// would re-evaluate the whole Builder (browser, preview, every lane) on
/// each scrub pixel.
private struct CropStyleMenu: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        let target = model.targetCropBlock
        Menu {
            ForEach(BuilderTimelineModel.availableCropLayouts(), id: \.self) { layout in
                Button {
                    if let target { model.setCropLayout(layout, for: target.uid) }
                } label: {
                    if let target, target.layout == layout {
                        Label(layout.displayName, systemImage: "checkmark")
                    } else {
                        Text(layout.displayName)
                    }
                }
            }
        } label: {
            Label("Screen: \(target?.layout.displayName ?? "—")", systemImage: "crop")
        }
        .disabled(target == nil)
        .help("Change the Screen Crop layout of the selected crop block (or the one at the playhead). Layouts come from Resources > Screen Crop.")
    }
}

/// Full-screen loading card shown while "Pre-fill Builder" plans a timeline
/// from a reel template. Isolated so per-line log appends only re-evaluate
/// this overlay, not the whole Builder.
private struct PrefillProgressOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Pre-filling from template…")
                    .font(.headline)
                Text(store.wizardLog.last ?? "Planning a timeline from the reel's structure")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420)
                    .multilineTextAlignment(.center)
                Button("Cancel") { store.cancelWizard() }
                    .controlSize(.small)
            }
            .padding(28)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 24, y: 8)
        }
    }
}

#Preview {
    BuilderView()
        .environment(AppStore())
}
