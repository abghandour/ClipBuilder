import SwiftUI

/// A still from the real caption renderer, including word states and decoration.
struct CaptionPresetThumbnail: View {
    let style: CaptionStyle
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFit().padding(8)
            } else if failed {
                Text("Preview unavailable").font(.caption).foregroundStyle(.white)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
        .accessibilityHidden(true)
        .task(id: style) {
            image = nil
            failed = false
            do {
                let preview = try await CaptionThumbnailCache.shared.image(for: style)
                try Task.checkCancellation()
                image = NSImage(data: preview.data)
                failed = image == nil
            } catch is CancellationError {
                // A newer style owns the thumbnail.
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
