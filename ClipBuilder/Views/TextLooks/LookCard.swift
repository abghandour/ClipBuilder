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

/// The rendered "Aa" sample on a black ground, loaded through the cache.
struct LookThumbnail: View {
    let decor: TextDecor
    var fontFamily: String? = nil
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if error != nil {
                Image(systemName: "exclamationmark.triangle")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 6))
        .help(error ?? "")
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

/// A fixed 80 x 48 thumbnail with the name under it: lists and template rows.
struct LookCard: View {
    let name: String
    let decor: TextDecor
    var fontFamily: String? = nil
    var showsName = true

    var body: some View {
        VStack(spacing: 4) {
            LookThumbnail(decor: decor, fontFamily: fontFamily).frame(width: 80, height: 48)
            if showsName { Text(name).font(.caption).lineLimit(1).fixedSize(horizontal: false, vertical: true).frame(width: 80) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(name)
        .help(name)
    }
}

/// A selectable tile for the inspector's Look grid: thumbnail, name, and a
/// tick when it is the look in use. Fills the grid cell it is given.
struct LookTile: View {
    let name: String
    var decor: TextDecor?
    var fontFamily: String? = nil
    var isSelected = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let decor {
                    LookThumbnail(decor: decor, fontFamily: fontFamily)
                } else {
                    Text("Aa").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 34)
            Text(name).font(.caption2).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(3)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One choice in a tile grid: what to draw and what picking it does.
struct LookChoice: Identifiable {
    var id: String
    var name: String
    var decor: TextDecor? = nil
    var fontFamily: String? = nil
    var isSelected = false
    var help = ""
    var action: () -> Void
}

/// A fixed-column grid of `LookTile`s. Not lazy on purpose: a lazy grid
/// inside the inspector's scroll view reported stale widths whenever the
/// controls above it changed, and the whole column laid out off-centre
/// until the window was refocused.
struct LookTileGrid: View {
    let choices: [LookChoice]
    var columns = 4

    private var rows: [[LookChoice]] {
        stride(from: 0, to: choices.count, by: columns).map { Array(choices[$0..<min($0 + columns, choices.count)]) }
    }

    var body: some View {
        VStack(spacing: Theme.spaceS) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Theme.spaceS) {
                    ForEach(row) { choice in
                        Button(action: choice.action) {
                            LookTile(name: choice.name, decor: choice.decor, fontFamily: choice.fontFamily, isSelected: choice.isSelected)
                        }
                        .buttonStyle(.plain)
                        .help(choice.help)
                    }
                    ForEach(row.count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
            }
        }
    }
}
