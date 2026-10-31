import SwiftUI

struct GenerateImageSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let builder: BuilderTimelineModel

    init(builder: BuilderTimelineModel, prefill: String = "") {
        self.builder = builder
        _prompt = State(initialValue: prefill)
    }

    @State private var follow = true
    @State private var prompt = ""
    @State private var mode: ImageGeneration.Mode = .sticker
    @State private var available = false
    @State private var checkedTools = false
    @State private var loadingFrame = true
    @State private var frame: CGImage?
    @State private var faces: [CGRect] = []
    @State private var faceNames: [String?] = []
    @State private var placement: ImageGeneration.Placement = .fullFrame
    @State private var selectedFace: Int?
    @State private var video: URL?
    @State private var sourceTime: Double?
    @State private var frameMessage: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Generate Image").font(.title2.bold())
            TextField("What to add", text: $prompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
            Picker("Place as", selection: $mode) {
                Text("Sticker on a person").tag(ImageGeneration.Mode.sticker)
                Text("Edit the whole frame").tag(ImageGeneration.Mode.edit)
            }
            if mode == .sticker {
                Toggle("Follow the face", isOn: $follow)
            }
            if let frame {
                framePreview(frame)
                Text(faceHint)
                    .font(.caption).foregroundStyle(.secondary)
                if selectedFace != nil {
                    Button("Use largest face") { selectedFace = nil }
                }
            } else if loadingFrame {
                ProgressView("Loading frame…")
            }
            if let frameMessage {
                Text(frameMessage).font(.caption).foregroundStyle(.secondary)
            }
            if checkedTools && !available {
                Text("Image generation needs the Gemini CLI and the Nano Banana extension installed in ~/.gemini/extensions/nanobanana.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if mode == .edit && frame == nil && !loadingFrame {
                Text("Move the playhead onto a video frame to edit it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") {
                    store.generateSticker(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        mode: mode, video: video, sourceTime: sourceTime,
                        subject: selectedFace.map { faces[$0] },
                        subjectName: selectedFace.flatMap { faceNames[safe: $0] ?? nil },
                        placement: placement, follow: follow && mode == .sticker, builder: builder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!available || loadingFrame || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (mode == .edit && frame == nil))
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spaceL)
        .frame(width: 560)
        .task { await loadFrame() }
        .onChange(of: store.profileGeneration) { _, _ in dismiss() }
        .onChange(of: builder.timelineID) { _, _ in dismiss() }
    }

    private var faceHint: String {
        if faces.isEmpty { return "No faces found. The sticker will be centered." }
        let offScreen = faces.filter { !placement.shows($0) }.count
        var hint = "Choose a face, or leave none selected to use the largest face on screen."
        if offScreen > 0 {
            hint += " The shaded part of the frame is cropped out by the screen layout."
        }
        return hint
    }

    private func faceLabel(_ index: Int) -> String {
        (faceNames[safe: index] ?? nil) ?? "Face \(index + 1)"
    }

    private func framePreview(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    // The visible window: everything outside it is cropped
                    // out by the screen layout at the playhead.
                    let window = placement.window
                    let visible = CGRect(x: window.xFrac * geometry.size.width, y: window.yFrac * geometry.size.height,
                                         width: window.wFrac * geometry.size.width, height: window.hFrac * geometry.size.height)
                    if window != FreeCropRect() {
                        let size = geometry.size
                        let shade = Color.black.opacity(0.55)
                        Path { path in
                            path.addRect(CGRect(x: 0, y: 0, width: size.width, height: visible.minY))
                            path.addRect(CGRect(x: 0, y: visible.maxY, width: size.width, height: size.height - visible.maxY))
                            path.addRect(CGRect(x: 0, y: visible.minY, width: visible.minX, height: visible.height))
                            path.addRect(CGRect(x: visible.maxX, y: visible.minY, width: size.width - visible.maxX, height: visible.height))
                        }
                        .fill(shade)
                        .allowsHitTesting(false)
                        Rectangle().strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: visible.width, height: visible.height)
                            .position(x: visible.midX, y: visible.midY)
                            .allowsHitTesting(false)
                    }
                    ForEach(faces.indices, id: \.self) { index in
                        let box = faces[index]
                        let selected = selectedFace == index
                        Button {
                            selectedFace = selected ? nil : index
                        } label: {
                            Rectangle()
                                .fill(selected ? Color.accentColor.opacity(0.2) : Color.clear)
                                .overlay {
                                    Rectangle().strokeBorder(selected ? Color.accentColor : .white, lineWidth: 2)
                                }
                                .overlay(alignment: .top) {
                                    if let name = faceNames[safe: index] ?? nil {
                                        MediaBadge(text: name)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .offset(y: -18)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: box.width * geometry.size.width, height: box.height * geometry.size.height)
                        .position(x: box.midX * geometry.size.width, y: box.midY * geometry.size.height)
                        .accessibilityLabel(faceLabel(index))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 260)
    }

    private func loadFrame() async {
        promptFocused = true
        let generation = store.profileGeneration
        let timelineID = builder.timelineID
        let playhead = builder.playhead
        let clip = builder.pictureClip(at: playhead)
        let source = clip.flatMap { builder.sourceURL(for: $0) }
        let time = clip.map { builder.sourceTime(for: $0, atTimeline: playhead) }
        if let clip { placement = builder.framePlacement(for: clip, atTimeline: playhead) }
        let videoID = clip.flatMap { builder.scene(for: $0)?.videoID }
        let hasTools = await store.ai.hasGeminiImageTools
        guard !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID else { return }
        available = hasTools
        checkedTools = true
        defer { loadingFrame = false }
        guard let source, let time else { return }
        guard let data = await ThumbnailService.jpegFrame(url: source, at: time, maxDimension: 1280) else {
            if !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID {
                frameMessage = "Could not load the frame at the playhead."
            }
            return
        }
        do {
            let image = try await AppJobWork.run { try ImageGeneration.decode(data) }
            guard !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID else { return }
            video = source
            sourceTime = time
            frame = image
            let detected = try await CenterStageService.faces(in: image)
            guard !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID else { return }
            faces = detected
            faceNames = Array(repeating: nil, count: detected.count)
            guard let videoID else { return }
            let roster = await store.videoPeople(for: videoID)
            let tiles = store.videos.first { $0.id == videoID }?.podcastTiles ?? []
            guard !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID,
                  faces == detected else { return }
            faceNames = ImageGeneration.names(for: detected, roster: roster, tiles: tiles)
        } catch {
            guard !Task.isCancelled, store.profileGeneration == generation, builder.timelineID == timelineID else { return }
            frameMessage = error.userMessage
        }
    }
}
