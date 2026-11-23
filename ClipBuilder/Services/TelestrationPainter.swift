import AppKit
import CoreGraphics
import Foundation

nonisolated enum TelestrationPainter {
    /// `rect` is the video's rectangle, not the entire context. SwiftUI uses
    /// a top-left origin; unflipped bitmap contexts use a bottom-left origin.
    static func draw(_ telestration: Telestration, at elapsed: Double, in context: CGContext,
                     rect: CGRect, topLeftOrigin: Bool) {
        draw(TelestrationRules.state(of: telestration, at: elapsed), in: context,
             rect: rect, topLeftOrigin: topLeftOrigin)
    }

    /// Editor resting state and still previews have no fade or partial figures.
    static func draw(_ telestration: Telestration, in context: CGContext, rect: CGRect, topLeftOrigin: Bool) {
        let state = TelestrationRules.State(figures: telestration.figures.map {
            TelestrationRules.FigureState(figure: $0, progress: 1)
        }, opacity: 1)
        draw(state, in: context, rect: rect, topLeftOrigin: topLeftOrigin)
    }

    static func draw(_ state: TelestrationRules.State, in context: CGContext, rect: CGRect, topLeftOrigin: Bool) {
        guard state.opacity > 0, rect.width > 0, rect.height > 0 else { return }
        // Keep the original single composite layer for ordinary drawings.
        // Consecutive equal-opacity figures may share a layer without changing
        // their paint order, including where their outlines intersect.
        if state.figures.contains(where: { $0.opacity != 1 }) {
            var start = 0
            while start < state.figures.count {
                let opacity = state.figures[start].opacity
                var end = start + 1
                while end < state.figures.count, state.figures[end].opacity == opacity { end += 1 }
                let figures = state.figures[start..<end].map { item in
                    var item = item
                    item.opacity = 1
                    return item
                }
                draw(.init(figures: figures, opacity: state.opacity * opacity),
                     in: context, rect: rect, topLeftOrigin: topLeftOrigin)
                start = end
            }
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // Fade the composite once, so intersections and the outline fade equally.
        context.setAlpha(CGFloat(min(1, state.opacity)))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        for item in state.figures {
            if item.figure.kind == .stamp {
                drawStamp(item, in: context, rect: rect, topLeftOrigin: topLeftOrigin)
                continue
            }
            let paths = TelestrationRules.paths(for: item.figure, progress: item.progress, aspect: rect.width / rect.height)
            let path = CGMutablePath()
            for points in paths where points.count >= 2 {
                path.addLines(between: points.map {
                    TelestrationRules.placed($0, in: rect, topLeftOrigin: topLeftOrigin)
                })
            }
            stroke(path, figure: item.figure, width: item.figure.width * rect.height, in: context)
        }
    }

    private static func color(of figure: Telestration.Figure) -> CGColor {
        let rgb = figure.color.components
        return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private static func stroke(_ path: CGPath, figure: Telestration.Figure, width: CGFloat, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let color = color(of: figure)
        if figure.style == .neon {
            context.setShadow(offset: .zero, blur: width * 1.2, color: color)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            for _ in 0..<2 {
                context.addPath(path)
                context.strokePath()
            }
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(width * 0.55)
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            context.setLineWidth(width * 1.4)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokePath()
        }
    }

    private static func drawStamp(_ item: TelestrationRules.FigureState, in context: CGContext,
                                  rect: CGRect, topLeftOrigin: Bool) {
        let corners = TelestrationRules.boxCorners(for: item.figure)
        let state = TelestrationRules.stampState(for: item.figure, progress: item.progress)
        guard corners.count == 5, state.opacity > 0 else { return }
        let a = TelestrationRules.placed(corners[0], in: rect, topLeftOrigin: topLeftOrigin)
        let b = TelestrationRules.placed(corners[2], in: rect, topLeftOrigin: topLeftOrigin)
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let side = min(box.width, box.height)
        guard side > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: box.midX, y: box.midY)
        context.scaleBy(x: state.scale, y: state.scale)
        context.setAlpha(state.opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        let bounds = CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
        let path = CGPath(roundedRect: bounds, cornerWidth: side * 0.15, cornerHeight: side * 0.15, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 0.35))
        context.fillPath()
        stroke(path, figure: item.figure, width: item.figure.width * rect.height, in: context)
        drawSymbol(item.figure.symbol ?? Telestration.Figure.symbols[0], size: side * 0.6,
                   color: item.figure.style == .neon ? CGColor(gray: 1, alpha: 1) : color(of: item.figure),
                   in: context, topLeftOrigin: topLeftOrigin)
    }

    private static func drawSymbol(_ name: String, size: CGFloat, color: CGColor,
                                   in context: CGContext, topLeftOrigin: Bool) {
        // Each call owns its AppKit image; no mutable image crosses executors.
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)) else { return }
        var proposed = CGRect(origin: .zero, size: configured.size)
        guard let mask = configured.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        let factor = size / CGFloat(max(mask.width, mask.height))
        let width = CGFloat(mask.width) * factor, height = CGFloat(mask.height) * factor
        let bounds = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        context.saveGState()
        defer { context.restoreGState() }
        // CGImage masks use bottom-left coordinates. Undo only the flipped
        // caller's y direction, around the stamp centre, so the symbol stays upright.
        if topLeftOrigin { context.scaleBy(x: 1, y: -1) }
        context.clip(to: bounds, mask: mask)
        context.setFillColor(color)
        context.fill(bounds)
    }
}
