import SwiftUI

struct CaptionStylePreview: View {
    let style: CaptionStyle
    @State private var preview: CaptionPreviewImage?
    @State private var error: String?

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .darkGray)
                if let preview, let image = NSImage(data: preview.data) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: preview.size.width / 5, height: preview.size.height / 5)
                        .offset(x: preview.origin.x / 5, y: preview.origin.y / 5)
                }
            }
            .frame(width: 216, height: 384)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            .accessibilityLabel("Caption preview: Every moment has a story. Make yours stand out.")
            if let error { FormCaption(error, tone: .warning) }
        }
        .task(id: style) {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try CaptionPreviewImage.render(style: style)
                }.value
                try Task.checkCancellation()
                preview = value
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
