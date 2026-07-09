import SwiftUI

/// Clip Builder: scene browser on the left; preview + inspector above the
/// multi-track timeline on the right; Generate renders through the
/// multitrack pipeline into the Library.
struct BuilderView: View {
    @Environment(AppStore.self) private var store

    @State private var playingClip: TimelineClip?
    @State private var showLog = false
    @State private var showPreview = false

    var body: some View {
        let model = store.builder
        HSplitView {
            ClipBrowserPane()
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420, maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    PreviewPane()
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            // Hidden while the crop editor is up so it never
                            // covers the crop rectangles.
                            if !model.document.videoTrack.isEmpty && !isCropEditing {
                                PreviewPlayButton { showPreview = true }
                            }
                        }
                    Divider()
                    BuilderInspector()
                        .frame(width: 270)
                }
                .frame(maxHeight: .infinity)

                Divider()
                controlsBar
                Divider()

                TimelineView(onPlayClip: { playingClip = $0 })
                    .frame(minHeight: 200, idealHeight: 260, maxHeight: 340)

                if showLog || store.isBuilderRendering {
                    Divider()
                    logDrawer
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Builder")
        .navigationSubtitle("\(model.document.videoTrack.count) clips · \(model.totalDuration.timecode)")
        .toolbar {
            ToolbarItem {
                Button {
                    showLog.toggle()
                } label: {
                    Label("Log", systemImage: "text.alignleft")
                }
                .help("Show the render log")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    model.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.document.isEmpty)
                .help("Remove everything from the timeline")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLog = true
                    store.renderBuilderTimeline()
                } label: {
                    if store.isBuilderRendering {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Rendering…")
                        }
                    } else {
                        Label("Generate", systemImage: "play.rectangle.fill")
                    }
                }
                .disabled(store.isBuilderRendering || model.document.videoTrack.isEmpty)
                .help("Render the timeline to a video in the Library")
            }
        }
        .sheet(item: $playingClip) { clip in
            PlayerSheet(url: model.sourceURL(for: clip) ?? URL(fileURLWithPath: "/"),
                        title: model.scene(for: clip)?.videoFilename ?? "Clip",
                        startTime: clip.sourceStart ?? 0)
        }
        .sheet(isPresented: $showPreview) {
            TimelinePreviewSheet()
        }
        .onDeleteCommand {
            deleteSelection()
        }
    }

    /// Mirrors PreviewPane's crop-editor condition.
    private var isCropEditing: Bool {
        let model = store.builder
        if case .clip(let uid) = model.selection,
           let clip = model.clip(uid), clip.freeCrops?.isEmpty == false {
            return true
        }
        return false
    }

    // MARK: - Controls bar

    private var controlsBar: some View {
        let model = store.builder
        return HStack(spacing: 14) {
            Stepper("Tracks: \(model.document.trackCount)",
                    value: Binding(
                        get: { model.document.trackCount },
                        set: { model.setTrackCount($0) }),
                    in: 1...3)

            Divider().frame(height: 16)

            Menu {
                let music = WizardEngine.availableMusic()
                if music.isEmpty {
                    Text("Drop audio files into \(WizardEngine.musicDirectory.path)")
                } else {
                    ForEach(music, id: \.name) { track in
                        Button(track.name) {
                            model.addSound(name: track.name)
                        }
                    }
                }
            } label: {
                Label("Music", systemImage: "music.note.list")
            }
            .fixedSize()
            .help("Add a music block at the playhead")

            Button {
                _ = model.addText()
            } label: {
                Label("Text", systemImage: "textformat")
            }
            .help("Add a text overlay at the playhead")

            Divider().frame(height: 16)

            Toggle("Intro", isOn: Binding(
                get: { model.document.includeIntro },
                set: { model.setIncludeIntro($0) }))
            Toggle("Outro", isOn: Binding(
                get: { model.document.includeOutro },
                set: { model.setIncludeOutro($0) }))

            Spacer()

            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { model.pointsPerSecond },
                set: { model.pointsPerSecond = $0 }),
                in: 20...200)
                .frame(width: 140)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Log drawer

    private var logDrawer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a long render log would otherwise keep a live Text
                // for every line inside this 110pt drawer.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.builderLog.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.offset)
                    }
                }
                .padding(8)
            }
            .frame(height: 110)
            .background(.background.secondary)
            .onChange(of: store.builderLog.count) {
                if let last = store.builderLog.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func deleteSelection() {
        let model = store.builder
        switch model.selection {
        case .clip(let uid): model.removeClip(uid)
        case .sound(let uid): model.removeSound(uid)
        case .text(let uid): model.removeText(uid)
        case nil: break
        }
    }
}

#Preview {
    BuilderView()
        .environment(AppStore())
}
