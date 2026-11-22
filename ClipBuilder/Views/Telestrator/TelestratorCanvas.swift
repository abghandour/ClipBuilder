import CoreGraphics
import Foundation
import SwiftUI

struct TelestratorCanvas: View {
    let editor: TelestratorEditor
    let aspect: CGFloat
    let visibleRect: CGRect?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let rect = TelestrationRules.videoRect(aspect: aspect, in: geometry.size)
            SwiftUI.TimelineView(.animation(paused: editor.playStarted == nil)) { timeline in
                Canvas { context, _ in
                    if let image = editor.image {
                        context.draw(Image(decorative: image, scale: 1), in: rect)
                        context.withCGContext { cg in
                            guard editor.ready else { return }
                            if let start = editor.playStarted {
                                TelestrationPainter.draw(editor.drawing, at: timeline.date.timeIntervalSince(start),
                                    in: cg, rect: rect, topLeftOrigin: true)
                            } else {
                                TelestrationPainter.draw(editor.drawing, in: cg, rect: rect, topLeftOrigin: true)
                                if let draft = editor.draft {
                                    TelestrationPainter.draw(Telestration(figures: [draft]), in: cg,
                                        rect: rect, topLeftOrigin: true)
                                }
                            }
                        }
                        if let selected = editor.selected, editor.ready, editor.playStarted == nil,
                           editor.drawing.figures.indices.contains(selected) {
                            let figure = editor.drawing.figures[selected]
                            let paths = figure.kind == .stamp ? [TelestrationRules.boxCorners(for: figure)]
                                : TelestrationRules.paths(for: figure, progress: 1, aspect: aspect)
                            var path = Path()
                            for points in paths {
                                path.addLines(points.map { TelestrationRules.placed($0, in: rect) })
                            }
                            context.stroke(path, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        if visibleRect != nil {
                            var shade = Path(rect)
                            shade.addRect(TelestrationRules.cropRect(visibleRect, in: rect))
                            context.fill(shade, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    focused = true
                    guard rect.contains(value.startLocation) else { return }
                    if !editor.isDragging {
                        editor.beginDrag(at: TelestrationRules.sourcePoint(value.startLocation, in: rect))
                    }
                    editor.updateDrag(to: TelestrationRules.sourcePoint(value.location, in: rect))
                }
                .onEnded { value in
                    editor.endDrag(at: TelestrationRules.sourcePoint(value.location, in: rect))
                })
            .focusable()
            .focused($focused)
            .accessibilityLabel("Drawing canvas")
            .accessibilityHint("Drag to draw. Use Select to move a figure, or choose one in Drawing order.")
        }
        .background(.black)
        .overlay {
            if let error = editor.error {
                ContentUnavailableView("Could not load the frame", systemImage: "photo.badge.exclamationmark",
                    description: Text(error))
            } else if !editor.ready, editor.image == nil {
                ProgressView("Loading frame…")
            }
        }
        .overlay(alignment: .topTrailing) {
            if !editor.ready, editor.image != nil, editor.error == nil {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
                    .accessibilityLabel("Loading frame")
            }
        }
        .onDisappear { editor.cancelDrag() }
    }
}
