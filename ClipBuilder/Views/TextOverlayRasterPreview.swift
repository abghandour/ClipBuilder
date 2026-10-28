import SwiftUI

/// Shared by the inspector and the two editable stages. Their hit targets stay unchanged.
struct TextOverlayRasterPreview: View {
    let item: TextOverlayItem
    var canvas = CGSize(width: 1080, height: 1920)
    /// Called after each render with the item's box in canvas pixels from the
    /// top left, or nil when the design has no box. Callers scale it to their
    /// stage at layout time, so a stage resize never leaves it stale.
    var onBox: ((CGRect?) -> Void)? = nil
    /// Inspector mode: show only the text's box plus padding, so the
    /// decorations are legible at inspector width. Stages keep the full frame.
    var cropToBox = false
    @Environment(AppStore.self) private var store
    @State private var image: NSImage?
    @State private var error: String?

    private struct Input: Equatable {
        var item: TextOverlayItem
        var width: Int
        var height: Int
    }

    private var input: Input {
        Input(item: item.applyingSharedStyle(store.activeProfile.textStyles ?? []),
              width: max(1, Int(canvas.width)), height: max(1, Int(canvas.height)))
    }

    var body: some View {
        Group {
            if let image {
                if cropToBox { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(nsImage: image).resizable() }
            } else { Color.clear }
        }
        .accessibilityLabel("Text style preview")
        .help(error ?? "Preview uses the same text renderer as export.")
        .task(id: input) {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let snapshot = input
                let crop = cropToBox
                let worker = Task.detached(priority: .userInitiated) { () throws -> (TextOverlayPreviewImage.Output, CGImage?) in
                    let output = try TextOverlayPreviewImage.render(item: snapshot.item, width: snapshot.width, height: snapshot.height)
                    guard crop, let rect = TextOverlayPreviewImage.cropRect(box: output.box, width: snapshot.width, height: snapshot.height) else {
                        return (output, nil)
                    }
                    return (output, TextOverlayPreviewImage.cropped(png: output.png, to: rect))
                }
                let (output, croppedImage) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                if let croppedImage {
                    image = NSImage(cgImage: croppedImage, size: NSSize(width: croppedImage.width, height: croppedImage.height))
                } else {
                    image = NSImage(data: output.png)
                }
                error = nil
                onBox?(output.box)
            } catch is CancellationError {
                // A newer edit owns the preview.
            } catch {
                image = nil
                self.error = "Could not render text preview: \(error.localizedDescription)"
            }
        }
    }
}
