import SwiftUI

/// Poster-frame preview of the composited 9:16 output at the playhead: each
/// active clip's frame is laid out with the same rules as the FFmpeg
/// compositor (full frame, 9:16 crop window, or a 1080x640 wide slot), in
/// layer + stack order, with active text overlays drawn on top. Scrub the
/// ruler to move the playhead. This is a layout-accurate approximation;
/// the render is the source of truth.
struct PreviewPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.builder
        // Snap the preview time to the 0.5s grid so scrubbing reuses cached
        // thumbnails instead of extracting a frame per pixel.
        let time = BuilderTimelineModel.snap(model.playhead)
        let active = model.document.videoTrack
            .filter { $0.startTime <= time + 0.001 && time < $0.startTime + $0.duration }
            .sorted { ($0.track, $0.stackOrder) < ($1.track, $1.stackOrder) }

        GeometryReader { geo in
            let frame = fittedFrame(in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.black)
                ForEach(active) { clip in
                    clipLayer(clip: clip, time: time, frame: frame, model: model)
                }
                ForEach(model.document.textOverlays.filter {
                    $0.startTime <= time && time < $0.endTime
                }) { overlay in
                    TextOverlayLayer(overlay: overlay, frame: frame)
                }
                if case .clip(let uid) = model.selection,
                   let selected = active.first(where: { $0.uid == uid }),
                   selected.freeCrops?.isEmpty == false {
                    CropEditorLayer(clip: selected, time: time, frame: frame)
                }
                if active.isEmpty {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(width: frame.width, height: frame.height)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }

    private func fittedFrame(in size: CGSize) -> CGSize {
        let scale = min(size.width / 9, size.height / 16)
        return CGSize(width: scale * 9, height: scale * 16)
    }

    @ViewBuilder
    private func clipLayer(clip: TimelineClip, time: Double, frame: CGSize,
                           model: BuilderTimelineModel) -> some View {
        if let url = model.sourceURL(for: clip) {
            let sourceTime = model.sourceTime(for: clip, atTimeline: time)
            let settings = model.document.trackSettings[safe: clip.track] ?? TrackSettings()
            let cropped = clip.wide && (clip.cropXFrac ?? settings.defaultCropXFrac) != nil
            if clip.wide && !cropped {
                // Slot band: 1080x640 at top/center/bottom.
                let position = clip.position ?? settings.defaultPosition
                let slotIndex = ["top": 0, "center": 1, "bottom": 2][position] ?? 0
                VideoThumbnail(url: url, time: sourceTime, cornerRadius: 0)
                    .frame(width: frame.width, height: frame.height / 3)
                    .offset(y: CGFloat(slotIndex) * frame.height / 3)
            } else {
                VideoThumbnail(url: url, time: sourceTime, cornerRadius: 0)
                    .frame(width: frame.width, height: frame.height)
            }
        }
    }

}

/// Crop editor shown while the selected clip has custom crops: the source
/// frame is letterboxed (aspect fit) over a dimmed canvas so each rectangle
/// maps exactly onto source-space fractions. Drag a rectangle to move the
/// region it shows; drag a corner handle to resize it. Edits write the clip's
/// freeCrops, which the FFmpeg compositor renders.
private struct CropEditorLayer: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip
    let time: Double
    let frame: CGSize

    @State private var image: NSImage?
    @State private var drag: (crop: Int, corner: Corner?, start: FreeCropRect)?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private static let minSize = 0.05

    var body: some View {
        let crops = clip.freeCrops ?? []
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.7))
            if let image {
                let fitted = fittedRect(imageSize: image.size)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                ForEach(crops.indices, id: \.self) { index in
                    cropRectangle(index: index, src: crops[index].src, fitted: fitted)
                }
            } else {
                ProgressView()
                    .frame(width: frame.width, height: frame.height)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .task(id: "\(clip.uid)|\(time)") {
            let model = store.builder
            if let url = model.sourceURL(for: clip),
               let data = await store.thumbnails.thumbnail(
                   for: url, at: model.sourceTime(for: clip, atTimeline: time)),
               let loaded = NSImage(data: data) {
                image = loaded
            }
        }
    }

    /// Aspect-fit rect of the source frame within the preview canvas.
    private func fittedRect(imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: frame)
        }
        let scale = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (frame.width - size.width) / 2,
                      y: (frame.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    @ViewBuilder
    private func cropRectangle(index: Int, src: FreeCropRect, fitted: CGRect) -> some View {
        let rect = CGRect(x: fitted.minX + src.xFrac * fitted.width,
                          y: fitted.minY + src.yFrac * fitted.height,
                          width: src.wFrac * fitted.width,
                          height: src.hFrac * fitted.height)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.accentColor.opacity(0.15))
            Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .gesture(dragGesture(index: index, corner: nil, fitted: fitted))
        ForEach(Corner.allCases, id: \.self) { corner in
            Circle()
                .fill(Color.accentColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                .position(handlePosition(corner, rect: rect))
                .gesture(dragGesture(index: index, corner: corner, fitted: fitted))
        }
    }

    private func handlePosition(_ corner: Corner, rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func dragGesture(index: Int, corner: Corner?, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let model = store.builder
                if drag == nil || drag?.crop != index || drag?.corner != corner {
                    guard let crops = model.clip(clip.uid)?.freeCrops,
                          crops.indices.contains(index) else { return }
                    drag = (index, corner, crops[index].src)
                }
                guard let drag else { return }
                let newRect = Self.transformed(drag.start, corner: corner,
                                               dx: value.translation.width / fitted.width,
                                               dy: value.translation.height / fitted.height)
                model.updateClip(clip.uid) {
                    guard var crops = $0.freeCrops, crops.indices.contains(index) else { return }
                    // Crops created in-app display in place (dst mirrors src);
                    // keep them coupled unless the timeline came in with a
                    // custom destination mapping.
                    let coupled = crops[index].dst == crops[index].src
                    crops[index].src = newRect
                    if coupled { crops[index].dst = newRect }
                    $0.freeCrops = crops
                }
            }
            .onEnded { _ in drag = nil }
    }

    /// Move (corner == nil) or corner-resize the start rect by a fractional
    /// delta, clamped to the unit square with a minimum size.
    private static func transformed(_ start: FreeCropRect, corner: Corner?,
                                    dx: Double, dy: Double) -> FreeCropRect {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            min(max(value, low), high)
        }
        let right = start.xFrac + start.wFrac
        let bottom = start.yFrac + start.hFrac
        var rect = start
        switch corner {
        case nil:
            rect.xFrac = clamp(start.xFrac + dx, 0, 1 - start.wFrac)
            rect.yFrac = clamp(start.yFrac + dy, 0, 1 - start.hFrac)
        case .topLeft:
            let x = clamp(start.xFrac + dx, 0, right - minSize)
            let y = clamp(start.yFrac + dy, 0, bottom - minSize)
            rect = FreeCropRect(xFrac: x, yFrac: y, wFrac: right - x, hFrac: bottom - y)
        case .topRight:
            let newRight = clamp(right + dx, start.xFrac + minSize, 1)
            let y = clamp(start.yFrac + dy, 0, bottom - minSize)
            rect = FreeCropRect(xFrac: start.xFrac, yFrac: y,
                                wFrac: newRight - start.xFrac, hFrac: bottom - y)
        case .bottomLeft:
            let x = clamp(start.xFrac + dx, 0, right - minSize)
            let newBottom = clamp(bottom + dy, start.yFrac + minSize, 1)
            rect = FreeCropRect(xFrac: x, yFrac: start.yFrac,
                                wFrac: right - x, hFrac: newBottom - start.yFrac)
        case .bottomRight:
            rect.wFrac = clamp(start.wFrac + dx, minSize, 1 - start.xFrac)
            rect.hFrac = clamp(start.hFrac + dy, minSize, 1 - start.yFrac)
        }
        return rect
    }
}

/// A text overlay in the preview. Drag it to reposition: the drag writes the
/// same xFrac/yFrac the inspector sliders edit, so both stay in sync.
private struct TextOverlayLayer: View {
    @Environment(AppStore.self) private var store
    let overlay: TextOverlayItem
    let frame: CGSize

    /// Fractional position at the moment the drag started; nil when idle.
    @State private var dragStart: CGPoint?

    var body: some View {
        let (r, g, b) = TextOverlayRenderer.parseColor(overlay.fontcolor)
        let x = overlay.xFrac ?? 0.5
        let y = overlay.yFrac ?? {
            switch overlay.position {
            case "top": return 0.1
            case "center", "middle": return 0.5
            default: return 0.85
            }
        }()
        Text(overlay.text)
            .font(.system(size: CGFloat(overlay.fontsize) * frame.width / 1080,
                          weight: overlay.bold ? .bold : .regular))
            .italic(overlay.italic)
            .foregroundStyle(Color(red: r, green: g, blue: b))
            .padding(4)
            .background(overlay.boxOpacity > 0
                        ? backgroundColor.opacity(overlay.boxOpacity) : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .position(x: frame.width * x, y: frame.height * y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let model = store.builder
                        if dragStart == nil {
                            dragStart = CGPoint(x: x, y: y)
                            model.selection = .text(overlay.uid)
                        }
                        guard let start = dragStart else { return }
                        let newX = min(max(start.x + value.translation.width / frame.width, 0), 1)
                        let newY = min(max(start.y + value.translation.height / frame.height, 0), 1)
                        model.updateText(overlay.uid) {
                            $0.xFrac = newX
                            $0.yFrac = newY
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private var backgroundColor: Color {
        let (r, g, b) = TextOverlayRenderer.parseColor(overlay.bgcolor, fallback: (0, 0, 0))
        return Color(red: r, green: g, blue: b)
    }
}
