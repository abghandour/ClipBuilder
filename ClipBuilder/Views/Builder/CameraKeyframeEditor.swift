import SwiftUI

/// The custom camera path of a wide clip, edited at the playhead: the source
/// frame at that instant with the crop drawn over it. Drag the crop to move
/// it, zoom it with the slider; a keyframe within a quarter second takes
/// the change, otherwise one is added here. Keyframes can be stepped
/// through, removed, and turned into hard cuts.
struct CameraKeyframeEditor: View {
    @Environment(AppStore.self) private var store
    let clip: TimelineClip

    @State private var dragStart: CameraPathKeyframe?

    var body: some View {
        let model = store.builder
        let path = model.clip(clip.uid)?.cameraPath ?? clip.cameraPath ?? []
        let visible = CameraKeyframes.visible(path)
        let inside = model.playhead >= clip.startTime - 0.001 && model.playhead <= clip.startTime + clip.duration + 0.001
        let offset = CameraKeyframes.sourceOffset(atTimeline: model.playhead, clip: clip)
        let nearest = CameraKeyframes.nearestVisible(path, to: offset)
        let rect = CameraKeyframes.rect(path, at: offset)
        let ratio = model.cropRatio(for: clip)

        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Text(visible.count == 1 ? "1 keyframe" : "\(visible.count) keyframes")
                    .font(.caption.weight(.medium))
                if let source = clip.cameraPathSource, source == "wizard" || source == "recipe" {
                    Text(source == "wizard" ? "· set by the Wizard" : "· set by a recipe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear", role: .destructive) { model.setFraming(clip.uid, .tracking) }
                    .controlSize(.small)
                    .help("Drop the custom path and go back to the tracked framing")
            }
            if inside, let rect {
                framePreview(rect: rect, ratio: ratio, model: model)
                InspectorRow("Zoom") {
                    Slider(value: Binding(
                        get: { rect.h },
                        set: { height in
                            let h = min(1, max(CameraKeyframes.minimumSize, height))
                            var w = h * ratio
                            var hh = h
                            if w > 1 { w = 1; hh = w / ratio }
                            let cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2
                            model.setCameraKeyframe(clip.uid, atTimeline: model.playhead,
                                rect: CameraPathKeyframe(t: 0, x: cx - w / 2, y: cy - hh / 2, w: w, h: hh))
                        }), in: CameraKeyframes.minimumSize...1)
                        .help("How much of the frame the crop covers at this moment")
                }
                keyframeStrip(path: path, visible: visible, nearest: nearest, rect: rect, model: model)
            } else {
                Text("Move the playhead into this clip to see and adjust its crop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keyframeStrip(path: path, visible: visible, nearest: nil, rect: nil, model: model)
            }
            Text("Drag the crop or click where it should sit. A keyframe within a quarter second takes the change; otherwise one is added at the playhead.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func framePreview(rect: CameraPathKeyframe, ratio: Double, model: BuilderTimelineModel) -> some View {
        let uid = clip.uid
        let playhead = model.playhead
        let aspect = model.sourceAspect(for: clip) ?? 16.0 / 9.0
        return Group {
            if let url = model.sourceURL(for: clip) {
                VideoThumbnail(url: url, time: model.sourceTime(for: clip, atTimeline: playhead), cornerRadius: 4,
                               contentMode: .fit)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .overlay {
                        GeometryReader { geo in
                            let size = geo.size
                            ZStack(alignment: .topLeading) {
                                // Click anywhere: the crop centers there.
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { location in
                                        let cx = Double(location.x / max(1, size.width))
                                        let cy = Double(location.y / max(1, size.height))
                                        model.setCameraKeyframe(uid, atTimeline: playhead, rect: CameraPathKeyframe(
                                            t: 0, x: cx - rect.w / 2, y: cy - rect.h / 2, w: rect.w, h: rect.h))
                                    }
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .background(Color.accentColor.opacity(0.001))
                                    .contentShape(Rectangle())
                                    .frame(width: size.width * rect.w, height: size.height * rect.h)
                                    .offset(x: size.width * rect.x, y: size.height * rect.y)
                                    .gesture(DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let anchor = dragStart ?? rect
                                            dragStart = anchor
                                            let x = anchor.x + Double(value.translation.width / max(1, size.width))
                                            let y = anchor.y + Double(value.translation.height / max(1, size.height))
                                            model.setCameraKeyframe(uid, atTimeline: playhead, rect: CameraPathKeyframe(
                                                t: 0, x: x, y: y, w: anchor.w, h: anchor.h))
                                        }
                                        .onEnded { _ in dragStart = nil })
                                    .help("Drag to choose what the crop shows at this moment")
                                    .accessibilityLabel("Camera crop at the playhead")
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func keyframeStrip(path: [CameraPathKeyframe], visible: [Int], nearest: Int?,
                               rect: CameraPathKeyframe?, model: BuilderTimelineModel) -> some View {
        let uid = clip.uid
        let offset = CameraKeyframes.sourceOffset(atTimeline: model.playhead, clip: clip)
        let previous = visible.last { path[$0].t < offset - 0.001 }
        let next = visible.first { path[$0].t > offset + 0.001 }
        HStack(spacing: Theme.spaceS) {
            Button("Previous keyframe", systemImage: "backward.end") {
                if let previous { model.playhead = CameraKeyframes.timelineTime(of: path[previous], clip: clip) }
            }
            .labelStyle(.iconOnly)
            .disabled(previous == nil)
            .help("Jump to the previous keyframe")
            Group {
                if let nearest, let position = visible.firstIndex(of: nearest) {
                    Text("Keyframe \(position + 1) of \(visible.count) · \(path[nearest].t.timecode)")
                } else {
                    Text("Between keyframes · \(offset.timecode)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Button("Next keyframe", systemImage: "forward.end") {
                if let next { model.playhead = CameraKeyframes.timelineTime(of: path[next], clip: clip) }
            }
            .labelStyle(.iconOnly)
            .disabled(next == nil)
            .help("Jump to the next keyframe")
            Spacer()
            if let nearest {
                Button("Remove", systemImage: "minus.circle") { model.removeCameraKeyframe(uid, at: nearest) }
                    .labelStyle(.iconOnly)
                    .help("Remove this keyframe; the crop glides across from its neighbors")
            } else if let rect {
                Button("Add", systemImage: "plus.circle") {
                    model.setCameraKeyframe(uid, atTimeline: model.playhead, rect: rect)
                }
                .labelStyle(.iconOnly)
                .help("Add a keyframe at the playhead with the crop shown now")
            }
        }
        .controlSize(.small)
        if let nearest, nearest > 0 {
            Toggle("Cut to this keyframe", isOn: Binding(
                get: { CameraKeyframes.isCut(path, at: nearest) },
                set: { model.setCameraCut(uid, at: nearest, cut: $0) }))
                .font(.caption)
                .help("Jump straight to this crop instead of gliding into it")
        }
    }
}
