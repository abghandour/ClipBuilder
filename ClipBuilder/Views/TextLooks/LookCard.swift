import SwiftUI

/// Coalesces concurrent requests as well as caching completed thumbnails.
/// The key includes the font; two looks with identical decor can use different fonts.
actor LookThumbnailCache {
    static let shared = LookThumbnailCache()
    nonisolated struct Key: Hashable, Sendable {
        var decor: TextDecor
        var fontFamily: String?
    }
    private var images: [Key: Data] = [:]
    private var pending: [Key: Task<Data, Error>] = [:]
    private(set) var renderCount = 0

    func image(decor: TextDecor, fontFamily: String?) async throws -> Data {
        let key = Key(decor: decor, fontFamily: fontFamily)
        if let image = images[key] { return image }
        if let worker = pending[key] { return try await worker.value }
        renderCount += 1
        let worker = Task.detached(priority: .utility) {
            var item = TextOverlayItem(text: "Aa")
            // fontsize is relative to a 1920-high frame; 1000 fills about half of this short canvas.
            item.fontsize = 1000
            item.xFrac = 0.5
            item.yFrac = 0.5
            item.decor = decor
            item.fontOverride = fontFamily
            return try TextOverlayPreviewImage.render(item: item, width: 400, height: 240).png
        }
        pending[key] = worker
        do {
            let data = try await worker.value
            // Bounded cache; edits cannot retain an unbounded history of raster images.
            if images.count >= 256 { images.removeAll(keepingCapacity: true) }
            images[key] = data
            pending[key] = nil
            return data
        } catch {
            pending[key] = nil
            throw error
        }
    }
}

struct LookCard: View {
    let name: String
    let decor: TextDecor
    var fontFamily: String? = nil
    var showsName = true
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if error != nil {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 80, height: 48)
            .background(.black, in: RoundedRectangle(cornerRadius: 6))
            if showsName { Text(name).font(.caption).lineLimit(1).fixedSize(horizontal: false, vertical: true).frame(width: 80) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(name)
        .help(error ?? name)
        .task(id: LookThumbnailCache.Key(decor: decor, fontFamily: fontFamily)) {
            do {
                let png = try await LookThumbnailCache.shared.image(decor: decor, fontFamily: fontFamily)
                try Task.checkCancellation()
                image = NSImage(data: png)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = "Could not render look: \(error.localizedDescription)"
            }
        }
    }
}
