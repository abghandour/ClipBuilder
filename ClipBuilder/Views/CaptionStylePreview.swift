import SwiftUI

struct CaptionStylePreview: View {
    let style: CaptionStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [CaptionPreviewImage] = []
    @State private var images: [NSImage?] = []
    @State private var error: String?
    @State private var states: [(CaptionPreviewImage.WordState, NSImage)] = []
    @State private var started = Date.now
    @State private var playing = true
    @State private var pausedTime = 0.0
    /// The phrase the preview speaks; blank means the stock sample. Shared by
    /// every style so the user compares them on the same words.
    @AppStorage("captions.previewText") private var previewText = ""
    @State private var debouncedText = ""

    private var loop: Double { frames.last?.end ?? 3 }

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { timeline in
                let time = reduceMotion ? 0.3 : (playing ? timeline.date.timeIntervalSince(started) : pausedTime)
                    .truncatingRemainder(dividingBy: loop)
                let index = frames.firstIndex { $0.start <= time && time < $0.end }
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .darkGray)
                    if let index, images.indices.contains(index), let image = images[index] {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: frames[index].size.width / 5, height: frames[index].size.height / 5)
                            .offset(x: frames[index].origin.x / 5, y: frames[index].origin.y / 5)
                    }
                }
                .frame(width: 216, height: 384)
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Caption preview: \(CaptionPreviewImage.text(debouncedText))")
            TextField("Sample phrase", text: $previewText, prompt: Text(CaptionPreviewImage.sampleText))
                .textFieldStyle(.roundedBorder)
                .frame(width: 216)
                .help("The words the preview speaks. Leave blank for the stock sample.")
            if !reduceMotion {
                Button(playing ? "Pause Preview" : "Play Preview", systemImage: playing ? "pause.fill" : "play.fill") {
                    if playing { pausedTime = Date.now.timeIntervalSince(started) }
                    else { started = Date.now.addingTimeInterval(-pausedTime) }
                    playing.toggle()
                }
                .lineLimit(1).fixedSize()
                .help("Play or pause the sample caption animation.")
            }
            if let error { FormCaption(error, tone: .warning) }
            wordStateRows
        }
        .onAppear { debouncedText = previewText }
        .task(id: previewText) {
            // Let typing settle before re-rendering every frame of the loop.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            debouncedText = previewText
        }
        .task(id: style) {
            let previewStyle = style
            let task = Task.detached(priority: .userInitiated) { try CaptionPreviewImage.wordStates(style: previewStyle) }
            guard let values = try? await withTaskCancellationHandler(operation: { try await task.value },
                                                                      onCancel: { task.cancel() }),
                  !Task.isCancelled else { return }
            states = values.compactMap { state in NSImage(data: state.image.data).map { (state, $0) } }
        }
        .task(id: PreviewInput(style: style, text: debouncedText)) {
            let previewStyle = style, text = debouncedText
            let task = Task.detached(priority: .userInitiated) { try CaptionPreviewImage.frames(style: previewStyle, text: text) }
            do {
                let values = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                frames = values
                images = values.map { NSImage(data: $0.data) }
                started = .now
                pausedTime = playing ? 0 : max(0.3, pausedTime.truncatingRemainder(dividingBy: loop))
                error = nil
            } catch is CancellationError {
                // A newer edit owns the preview now.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not render preview: \(error.localizedDescription)"
            }
        }
    }

    /// One row per word state: the label and that word as the style draws it
    /// now, so the Text, Highlight and Emphasis groups each show their effect.
    private var wordStateRows: some View {
        VStack(spacing: Theme.spaceXS) {
            ForEach(states, id: \.0.id) { state, image in
                HStack(spacing: Theme.spaceS) {
                    Text(state.kind.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                        .frame(width: 64, alignment: .leading)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: state.image.size.width / 5, height: state.image.size.height / 5)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, Theme.spaceS)
                .frame(height: 44)
                .background(Color(nsColor: .darkGray), in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
        }
        .frame(width: 216)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Word states: Text, Highlight, Emphasis as the style draws them")
    }
}

private struct PreviewInput: Equatable {
    var style: CaptionStyle
    var text: String
}
