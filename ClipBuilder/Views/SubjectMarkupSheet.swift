import AVKit
import SwiftUI

extension VideoSubject {
    /// This subject's border color for SwiftUI views.
    var color: Color {
        let entry = SubjectPalette.entry(colorIndex)
        return Color(red: entry.red, green: entry.green, blue: entry.blue)
    }
}

/// Mark VIP subjects on a source video: scrub to a moment, drag a box around
/// a person, and name them. Every box is anchored at the timestamp it was
/// drawn on; the analyzer sends those frames (box burned in) as references so
/// scenes featuring a subject are tagged "vip:<name>" — filterable in Scenes
/// and referenceable by name from analysis and wizard instructions.
struct SubjectMarkupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var selectedSubjectID: Int64?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @FocusState private var focusedNameID: Int64?

    /// Boxes drawn near the playhead stay visible for this long on either
    /// side, so a paused frame shows what was marked around it.
    private static let rectVisibilityWindow = 0.75

    private var subjects: [VideoSubject] { store.subjects(for: video.id) }

    private var selectedSubject: VideoSubject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VIP Subjects — \(video.filename)")
                        .font(.headline)
                    Text("Pause on a clear view of a person, then drag a box around them. Boxes add to the selected subject; with none selected a new subject is created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            HSplitView {
                VStack(spacing: 8) {
                    playerArea
                    transportBar
                }
                .padding([.leading, .bottom], 12)
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

                subjectsPanel
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            let player = AVPlayer(url: video.url)
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    currentTime = time.seconds.isFinite ? time.seconds : 0
                    isPlaying = player.rate != 0
                }
            }
        }
        .onDisappear {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player?.pause()
        }
    }

    // MARK: - Player + drawing overlay

    private var playerArea: some View {
        GeometryReader { geometry in
            let frame = videoRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: player)
                visibleBoxes(in: frame)
                if let start = dragStart, let current = dragCurrent {
                    let rubber = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                        width: abs(start.x - current.x), height: abs(start.y - current.y))
                    Rectangle()
                        .strokeBorder(rubberBandColor, lineWidth: 2)
                        .frame(width: rubber.width, height: rubber.height)
                        .offset(x: rubber.minX, y: rubber.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drawGesture(in: frame))
        }
        .background(.black, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Where the aspect-fit video actually sits inside the container.
    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = video.width > 0 && video.height > 0
            ? Double(video.width) / Double(video.height) : 16.0 / 9.0
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    /// The color a drag will resolve to: the selected subject's, or the next
    /// palette color for the subject the drag would create.
    private var rubberBandColor: Color {
        if let selected = selectedSubject { return selected.color }
        let entry = SubjectPalette.entry(subjects.count)
        return Color(red: entry.red, green: entry.green, blue: entry.blue)
    }

    /// Boxes anchored near the current playhead, drawn in video coordinates.
    @ViewBuilder
    private func visibleBoxes(in frame: CGRect) -> some View {
        ForEach(subjects) { subject in
            ForEach(Array(subject.rects.enumerated()), id: \.offset) { _, rect in
                if abs(rect.at - currentTime) <= Self.rectVisibilityWindow {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .strokeBorder(subject.color, lineWidth: 3)
                        Text(subject.name)
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(subject.color)
                            .offset(y: -16)
                    }
                    .frame(width: rect.w * frame.width, height: rect.h * frame.height)
                    .offset(x: frame.minX + rect.x * frame.width,
                            y: frame.minY + rect.y * frame.height)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func drawGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil {
                    player?.pause()
                    dragStart = clamp(value.startLocation, to: frame)
                }
                dragCurrent = clamp(value.location, to: frame)
            }
            .onEnded { _ in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                guard let start = dragStart, let end = dragCurrent, frame.width > 0 else { return }
                let rect = SubjectRect(at: (currentTime * 10).rounded() / 10,
                                       x: (min(start.x, end.x) - frame.minX) / frame.width,
                                       y: (min(start.y, end.y) - frame.minY) / frame.height,
                                       w: abs(start.x - end.x) / frame.width,
                                       h: abs(start.y - end.y) / frame.height)
                // Accidental clicks shouldn't create slivers.
                guard rect.w > 0.015, rect.h > 0.015 else { return }
                Task {
                    if let subject = selectedSubject {
                        await store.updateVideoSubjectRects(subject, rects: subject.rects + [rect])
                    } else if let created = await store.addVideoSubject(videoID: video.id, rects: [rect]) {
                        selectedSubjectID = created.id
                        focusedNameID = created.id
                    }
                }
            }
    }

    private func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX),
                y: min(max(point.y, frame.minY), frame.maxY))
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                guard let player else { return }
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(isPlaying ? "Pause" : "Play")

            Slider(value: scrubBinding, in: 0...max(video.duration, 0.1))

            Text("\(currentTime.timecode) / \(video.duration.timecode)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(get: { currentTime },
                set: { time in
                    currentTime = time
                    player?.pause()
                    player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                })
    }

    // MARK: - Subjects panel

    private var subjectsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subjects")
                .font(.subheadline.weight(.medium))
            if subjects.isEmpty {
                Text("No subjects yet — drag a box around a person in the video.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(subjects) { subject in
                        subjectRow(subject)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("During analysis, scenes featuring a subject are tagged \"vip:<name>\" — so instructions like “only include scenes with Person A” work in Analyze and in the AI Wizard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func subjectRow(_ subject: VideoSubject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(subject.color)
                    .frame(width: 12, height: 12)
                TextField("Name", text: nameBinding(subject))
                    .textFieldStyle(.plain)
                    .font(.body.weight(selectedSubjectID == subject.id ? .semibold : .regular))
                    .focused($focusedNameID, equals: subject.id)
                Spacer()
                Button {
                    Task { await store.deleteVideoSubject(subject) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete this subject and its boxes")
            }
            if subject.rects.isEmpty {
                Text("No boxes yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                // One chip per box: click seeks to its frame, x removes it.
                FlowChips(spacing: 4) {
                    ForEach(Array(subject.rects.enumerated()), id: \.offset) { index, rect in
                        HStack(spacing: 2) {
                            Button(rect.at.timecode) {
                                scrubBinding.wrappedValue = rect.at
                            }
                            .buttonStyle(.plain)
                            .font(.caption2.monospacedDigit())
                            Button {
                                var rects = subject.rects
                                rects.remove(at: index)
                                Task { await store.updateVideoSubjectRects(subject, rects: rects) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(subject.color.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .padding(8)
        .background(selectedSubjectID == subject.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSubjectID = selectedSubjectID == subject.id ? nil : subject.id
        }
        .help("Select to add more boxes to this subject; click again to deselect")
    }

    private func nameBinding(_ subject: VideoSubject) -> Binding<String> {
        Binding(get: { subjects.first { $0.id == subject.id }?.name ?? subject.name },
                set: { name in
                    Task { await store.renameVideoSubject(subject, to: name) }
                })
    }
}

/// Bare AVPlayerLayer host — no built-in controls, so drawing gestures land
/// on the SwiftUI overlay instead of AVPlayerView's chrome.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView()
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.playerLayer.player = player
    }

    final class LayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // Resizes shouldn't animate the video surface.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Minimal wrapping HStack for the box chips (Layout-based flow).
private struct FlowChips: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
