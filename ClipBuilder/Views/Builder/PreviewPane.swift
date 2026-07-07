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
                    textLayer(overlay, frame: frame)
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

    private func textLayer(_ overlay: TextOverlayItem, frame: CGSize) -> some View {
        let (r, g, b) = TextOverlayRenderer.parseColor(overlay.fontcolor)
        let x = overlay.xFrac ?? 0.5
        let y = overlay.yFrac ?? {
            switch overlay.position {
            case "top": return 0.1
            case "center", "middle": return 0.5
            default: return 0.85
            }
        }()
        return Text(overlay.text)
            .font(.system(size: CGFloat(overlay.fontsize) * frame.width / 1080,
                          weight: overlay.bold ? .bold : .regular))
            .italic(overlay.italic)
            .foregroundStyle(Color(red: r, green: g, blue: b))
            .padding(4)
            .background(overlay.boxOpacity > 0
                        ? backgroundColor(for: overlay).opacity(overlay.boxOpacity) : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
            .position(x: frame.width * x, y: frame.height * y)
    }

    private func backgroundColor(for overlay: TextOverlayItem) -> Color {
        let (r, g, b) = TextOverlayRenderer.parseColor(overlay.bgcolor, fallback: (0, 0, 0))
        return Color(red: r, green: g, blue: b)
    }
}
