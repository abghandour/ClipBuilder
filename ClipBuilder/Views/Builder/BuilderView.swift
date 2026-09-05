import SwiftUI

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
    @State private var showImagePicker = false
    @State private var confirmClear = false
    @State private var showMediaSuggestions = false

    var body: some View {
        let model = store.builder
        HSplitView {
            ClipBrowserPane()
                .rememberedPaneWidth("pane.builder.browser", min: 250, initial: 300, max: 420)
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
                Divider()

                TimelineView(onPlayClip: { playingClip = $0 })
                    .frame(minHeight: 200, idealHeight: 260, maxHeight: 340)

                if showLog || store.isBuilderRendering || store.isBuilderPreviewRendering {
                    Divider()
                    logDrawer
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onAppear { model.undoManager = undoManager }
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
        .sheet(isPresented: $showImagePicker) {
            ImagePickerSheet { urls in
                for url in urls { model.addImage(path: url.path) }
            }
        }
        .sheet(isPresented: $showMediaSuggestions) { MediaSuggestionsSheet() }
        .onDeleteCommand {
            deleteSelection()
        }
    }

    // MARK: - Controls bar

    private var controlsBar: some View {
        let model = store.builder
        return HStack(spacing: Theme.spaceM) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            BuilderAddMenu(showScenePicker: $showScenePicker,
                           showImagePicker: $showImagePicker)

            Button("Suggestions", systemImage: "sparkles") {
                showMediaSuggestions = true
            }
            .disabled(model.document.videoTrack.isEmpty)

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
            Label("Crop: \(target?.layout.displayName ?? "—")", systemImage: "crop")
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
