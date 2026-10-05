import SwiftUI

struct TagStylePreview: View {
    @Binding var style: TagStyle
    @Binding var selection: UUID?
    @State private var preview: TagPreviewImage?
    @State private var error: String?
    @State private var gestureStyle: TagStyle?

    private var liveStyle: TagStyle { gestureStyle ?? style }

    private func imageBinding(_ image: TagImage) -> Binding<TagImage> {
        Binding(get: { liveStyle.images.first { $0.id == image.id } ?? image }, set: { value in
            var draft = liveStyle
            guard let index = draft.images.firstIndex(where: { $0.id == image.id }) else { return }
            draft.images[index] = value
            gestureStyle = draft
        })
    }

    private func commitGesture() {
        guard let draft = gestureStyle else { return }
        style = draft
        gestureStyle = nil
    }

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            GeometryReader { geo in
                let scale = geo.size.width / TagPreviewImage.canvas.width
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .darkGray)
                    if let preview {
                        Image(decorative: preview.image, scale: 1)
                            .resizable().frame(width: geo.size.width, height: geo.size.height)
                        ForEach(liveStyle.images) { item in
                            if let rect = preview.geometry.images[item.id] {
                                TagPreviewImageHandle(item: imageBinding(item), selection: $selection,
                                    onEnd: commitGesture,
                                    rect: CGRect(x: (rect.minX + preview.offset.x) * scale,
                                                 y: (rect.minY + preview.offset.y) * scale,
                                                 width: rect.width * scale, height: rect.height * scale),
                                    textSize: CGSize(width: preview.geometry.textBlock.width * scale,
                                                     height: preview.geometry.textBlock.height * scale))
                            }
                        }
                    } else {
                        ProgressView().frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .coordinateSpace(name: "overlayCanvas")
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            }
            .aspectRatio(TagPreviewImage.canvas.width / TagPreviewImage.canvas.height, contentMode: .fit)
            .accessibilityLabel("Tag preview: Alex Morgan")
            if let error { FormCaption(error, tone: .warning) }
        }
        .task(id: liveStyle) {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let snapshot = liveStyle
                let value = try await Task.detached(priority: .userInitiated) {
                    try TagPreviewImage.render(style: snapshot)
                }.value
                try Task.checkCancellation()
                preview = value
                error = nil
            } catch is CancellationError {
                // A newer edit owns the preview.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not render preview: \(error.localizedDescription)"
            }
        }
    }
}

private struct TagPreviewImageHandle: View {
    @Binding var item: TagImage
    @Binding var selection: UUID?
    var onEnd: () -> Void
    let rect: CGRect
    let textSize: CGSize
    @State private var dragStart: CGPoint?
    @State private var dragSize: CGSize?
    @State private var resizeWidth: Double?

    var body: some View {
        Rectangle().fill(.clear).contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .overlay {
                if selection == item.id { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selection == item.id {
                    ResizeHandle(center: CGPoint(x: rect.midX, y: rect.midY), onScale: { factor in
                        if resizeWidth == nil { resizeWidth = item.width }
                        if let width = resizeWidth { item.width = min(2, max(0.05, width * factor)) }
                    }, onEnd: { resizeWidth = nil; onEnd() })
                        .offset(x: 6, y: 6)
                }
            }
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { selection = item.id }
            .gesture(DragGesture(coordinateSpace: .named("overlayCanvas"))
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = CGPoint(x: item.x, y: item.y)
                        dragSize = textSize
                        selection = item.id
                    }
                    guard let start = dragStart, let size = dragSize else { return }
                    item.x = start.x + value.translation.width / max(1, size.width)
                    item.y = start.y + value.translation.height / max(1, size.height)
                }
                .onEnded { _ in
                    dragStart = nil
                    dragSize = nil
                    onEnd()
                })
            .accessibilityLabel("Move \(URL(fileURLWithPath: item.path).lastPathComponent)")
    }
}
