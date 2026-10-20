import SwiftUI

struct CaptionStylePreview: View {
    let style: CaptionStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [CaptionPreviewImage] = []
    @State private var images: [NSImage?] = []
    @State private var error: String?
    @State private var started = Date.now
    @State private var playing = true
    @State private var pausedTime = 0.0

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { timeline in
                let time = reduceMotion ? 0.3 : (playing ? timeline.date.timeIntervalSince(started) : pausedTime)
                    .truncatingRemainder(dividingBy: 3)
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
            .accessibilityLabel("Caption preview: Every strong moment earns victory")
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
        }
        .task(id: style) {
            let previewStyle = style
            let task = Task.detached(priority: .userInitiated) { try CaptionPreviewImage.frames(style: previewStyle) }
            do {
                let values = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                frames = values
                images = values.map { NSImage(data: $0.data) }
                started = .now
                pausedTime = playing ? 0 : max(0.3, pausedTime.truncatingRemainder(dividingBy: 3))
                error = nil
            } catch is CancellationError {
                // A newer edit owns the preview now.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not render preview: \(error.localizedDescription)"
            }
        }
    }
}
