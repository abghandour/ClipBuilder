import AppKit
import Foundation

/// Renders the brand-kit elements the wizard burns into every reel: the
/// corner watermark, the full-video result headline, the intro title card,
/// and the branded outro card. Everything is deterministic CoreGraphics —
/// the AI decides the words, the brand kit decides the look.
nonisolated enum BrandRenderer {
    static var width: Int { RenderEngine.outputWidth }
    static var height: Int { RenderEngine.outputHeight }
    static let defaultAccent = "#FFD400"

    /// Every element is designed on the original 1080×1920 canvas and
    /// scaled UNIFORMLY into the output (scaling width and height by
    /// different factors distorted the cards on 16:9 and 1:1). Corner
    /// overlays (watermark, headline) anchor to the real frame edges; the
    /// full-frame cards are aspect-fit and centered.
    static let designWidth = 1080.0
    static let designHeight = 1920.0
    private static var scale: Double {
        min(Double(width) / designWidth, Double(height) / designHeight)
    }
    /// The output frame, for corner-anchored overlays.
    private static var canvasFrame: CGSize { CGSize(width: width, height: height) }
    /// The scaled design frame, for aspect-fit cards.
    private static var cardFrame: CGSize { CGSize(width: designWidth * scale, height: designHeight * scale) }

    // MARK: - Elements

    /// Full-frame transparent PNG with the logo in the top-left corner.
    static func watermark(logoURL: URL, to directory: URL) -> URL? {
        guard let logo = NSImage(contentsOf: logoURL) else { return nil }
        let s = scale
        let frame = canvasFrame
        return draw(named: "brand_watermark", in: directory) { context in
            drawImage(logo, in: context,
                      rect: fittedRect(for: logo, width: 150 * s,
                                       topLeft: CGPoint(x: 48 * s, y: 52 * s), frame: frame),
                      opacity: 0.85)
        }
    }

    /// Lower-third result headline: accent chip with the brand name over
    /// up-to-two lines of condensed caps, bottom-left, above broadcast HUDs.
    static func headline(_ text: String, brandName: String, accent: String,
                         to directory: URL) -> URL? {
        let s = scale
        let frame = canvasFrame
        return draw(named: "brand_headline", in: directory) { context in
            let accentColor = color(accent)
            let margin = 52.0 * s
            var cursorY = 390.0 * s

            // Headline: up to 2 lines, widest condensed face available.
            let font = titleFont(size: 54 * s)
            let lines = wrap(text.uppercased(), font: font, maxWidth: 760 * s, maxLines: 2)
            for line in lines.reversed() {
                drawText(line, font: font, color: .white, at: CGPoint(x: margin, y: cursorY),
                         in: context, frame: frame, shadow: true)
                cursorY += 64 * s
            }
            // Brand chip above the headline.
            let chipFont = titleFont(size: 34 * s)
            drawText(brandName.uppercased(), font: chipFont, color: accentColor,
                     at: CGPoint(x: margin, y: cursorY + 10 * s), in: context, frame: frame, shadow: true)
        }
    }

    /// Full-frame typographic intro card for compilations.
    static func titleCard(_ text: String, brandName: String, accent: String,
                          logoURL: URL?, to directory: URL) -> URL? {
        let s = scale
        let frame = cardFrame
        return draw(named: "brand_title_card", in: directory, background: .black, fitCard: true) { context in
            let accentColor = color(accent)
            if let logoURL, let logo = NSImage(contentsOf: logoURL) {
                drawImage(logo, in: context,
                          rect: fittedRect(for: logo, width: 130 * s,
                                           topLeft: CGPoint(x: (frame.width - 130 * s) / 2, y: 260 * s),
                                           frame: frame),
                          opacity: 1)
            }
            let font = titleFont(size: 96 * s)
            let lines = wrap(text.uppercased(), font: font, maxWidth: 900 * s, maxLines: 3)
            let lineHeight = 112.0 * s
            let blockHeight = Double(lines.count) * lineHeight
            var y = (frame.height - blockHeight) / 2 + blockHeight - lineHeight
            for line in lines {
                drawText(line, font: font, color: .white, at: nil, centeredY: y,
                         in: context, frame: frame, shadow: false)
                y -= lineHeight
            }
            context.setFillColor(accentColor.cgColor)
            context.fill(CGRect(x: (frame.width - 220 * s) / 2,
                                y: y + lineHeight - 72 * s,
                                width: 220 * s, height: 10 * s))
            drawText(brandName.uppercased(), font: titleFont(size: 34 * s), color: accentColor,
                     at: nil, centeredY: y + lineHeight - 140 * s, in: context, frame: frame, shadow: false)
        }
    }

    /// Branded outro: logo, brand name, tagline, follow CTA + handle.
    static func outroCard(profile: BrandProfile, to directory: URL) -> URL? {
        let s = scale
        let frame = cardFrame
        return draw(named: "brand_outro", in: directory, background: .black, fitCard: true) { context in
            let accentColor = color(profile.accentColor.isEmpty ? "#FFFFFF" : profile.accentColor)
            if let logoURL = profile.logoURL, let logo = NSImage(contentsOf: logoURL) {
                drawImage(logo, in: context,
                          rect: fittedRect(for: logo, width: 380 * s,
                                           topLeft: CGPoint(x: (frame.width - 380 * s) / 2, y: 560 * s),
                                           frame: frame),
                          opacity: 1)
            }
            drawText(profile.brandName.uppercased(), font: titleFont(size: 64 * s), color: .white,
                     at: nil, centeredY: 1010 * s, in: context, frame: frame, shadow: false,
                     tracking: 8 * s)
            if !profile.tagline.isEmpty {
                drawText(profile.tagline.uppercased(), font: titleFont(size: 26 * s),
                         color: NSColor.white.withAlphaComponent(0.7),
                         at: nil, centeredY: 940 * s, in: context, frame: frame, shadow: false,
                         tracking: 6 * s)
            }
            drawText("FOLLOW", font: titleFont(size: 36 * s),
                     color: accentColor, at: nil, centeredY: 560 * s, in: context, frame: frame,
                     shadow: false, tracking: 10 * s)
            let handle = profile.socials["instagram"]?.handle ?? ""
            if !handle.isEmpty {
                let display = handle.hasPrefix("@") ? handle : "@" + handle
                drawText(display, font: titleFont(size: 40 * s), color: .white,
                         at: nil, centeredY: 490 * s, in: context, frame: frame, shadow: false,
                         tracking: 2 * s)
            }
        }
    }

    /// Generate the full-resolution preview asset away from the main actor.
    @concurrent
    static func outroPreviewCard(profile: BrandProfile, in directory: URL) async -> URL? {
        guard !Task.isCancelled else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return outroCard(profile: profile, to: directory)
    }

    /// A still card → a silent video clip concatenate() can splice in.
    static func cardClip(png: URL, duration: Double, output: URL) async throws {
        try await FFmpeg.run([
            "-loop", "1", "-framerate", "30", "-t", String(format: "%.2f", duration),
            "-i", png.path,
            "-f", "lavfi", "-t", String(format: "%.2f", duration),
            "-i", "anullsrc=r=44100:cl=stereo",
            "-vf", "format=yuv420p,scale=\(width):\(height)",
        ] + FFmpeg.videoEncodeArgs + [
            "-c:a", "aac", "-shortest", "-y", output.path,
        ], timeout: 120)
    }

    // MARK: - Drawing plumbing

    /// `fitCard` draws the content in the scaled design frame centered on
    /// the canvas (letterboxed on 16:9, pillarboxed on 1:1); off, content
    /// draws straight onto the canvas.
    private static func draw(named name: String, in directory: URL,
                             background: NSColor? = nil, fitCard: Bool = false,
                             content: (CGContext) -> Void) -> URL? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if fitCard {
            let card = cardFrame
            context.translateBy(x: (Double(width) - card.width) / 2,
                                y: (Double(height) - card.height) / 2)
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        content(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image)
                  .representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent("\(name)_\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Heaviest condensed face available — matches the wizard overlay styles.
    private static func titleFont(size: Double) -> NSFont {
        for name in ["Anton-Regular", "Anton", "ArchivoBlack-Regular", "Archivo Black",
                     "HelveticaNeue-CondensedBlack"] {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.boldSystemFont(ofSize: size)
    }

    private static func color(_ hex: String) -> NSColor {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return .white }
        value.removeFirst()
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count >= 6, let number = UInt64(value.prefix(6), radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                       green: CGFloat((number >> 8) & 0xFF) / 255,
                       blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }

    /// x = nil centers horizontally at `centeredY` (baseline, bottom-up).
    private static func drawText(_ text: String, font: NSFont, color: NSColor,
                                 at point: CGPoint?, centeredY: Double = 0,
                                 in context: CGContext, frame: CGSize, shadow: Bool,
                                 tracking: Double = 0) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking > 0 { attributes[.kern] = tracking }
        if shadow {
            let drop = NSShadow()
            drop.shadowColor = NSColor.black.withAlphaComponent(0.75)
            drop.shadowOffset = NSSize(width: 0, height: -3)
            drop.shadowBlurRadius = 8
            attributes[.shadow] = drop
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let origin = point ?? CGPoint(x: (frame.width - size.width) / 2, y: centeredY)
        string.draw(at: origin)
    }

    private static func fittedRect(for image: NSImage, width targetWidth: Double,
                                   topLeft: CGPoint, frame: CGSize) -> CGRect {
        let aspect = image.size.height > 0 ? image.size.height / image.size.width : 1
        let targetHeight = targetWidth * aspect
        // topLeft.y is measured from the TOP of the frame for readability.
        return CGRect(x: topLeft.x, y: frame.height - topLeft.y - targetHeight,
                      width: targetWidth, height: targetHeight)
    }

    private static func drawImage(_ image: NSImage, in context: CGContext,
                                  rect: CGRect, opacity: Double) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.setAlpha(opacity)
        context.draw(cg, in: rect)
        context.restoreGState()
    }

    /// Greedy word wrap for the given font and width.
    private static func wrap(_ text: String, font: NSFont, maxWidth: Double,
                             maxLines: Int) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if NSAttributedString(string: candidate, attributes: attributes).size().width <= maxWidth
                || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
                if lines.count == maxLines - 1 { break }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return Array(lines.prefix(maxLines))
    }
}
