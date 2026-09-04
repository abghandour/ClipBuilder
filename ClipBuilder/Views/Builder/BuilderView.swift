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
        .navigationTitle("Builder")
        .navigationSubtitle("\(model.document.videoTrack.count) clips · \(model.totalDuration.timecode)")
        .toolbar {
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

            Divider().frame(height: 16)

            CropStyleMenu()

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
