import AppKit
import Foundation

/// Renders the brand-kit elements the wizard burns into every reel: the
/// corner watermark, the full-video result headline, the intro title card,
/// and the branded outro card. Everything is deterministic CoreGraphics —
/// the AI decides the words, the brand kit decides the look.
nonisolated enum BrandRenderer {
    static let width = 1080
    static let height = 1920
    static let defaultAccent = "#FFD400"

    // MARK: - Elements

    /// Full-frame transparent PNG with the logo in the top-left corner.
    static func watermark(logoURL: URL, to directory: URL) -> URL? {
        guard let logo = NSImage(contentsOf: logoURL) else { return nil }
        return draw(named: "brand_watermark", in: directory) { context in
            let targetWidth = 150.0
            drawImage(logo, in: context,
                      rect: fittedRect(for: logo, width: targetWidth,
                                       topLeft: CGPoint(x: 48, y: 52)),
                      opacity: 0.85)
        }
    }

    /// Lower-third result headline: accent chip with the brand name over
    /// up-to-two lines of condensed caps, bottom-left, above broadcast HUDs.
    static func headline(_ text: String, brandName: String, accent: String,
                         to directory: URL) -> URL? {
        draw(named: "brand_headline", in: directory) { context in
            let accentColor = color(accent)
            let margin = 52.0
            var cursorY = 390.0    // bottom-up coordinates: block base above HUD area

            // Headline: up to 2 lines, widest condensed face available.
            let font = titleFont(size: 54)
            let lines = wrap(text.uppercased(), font: font, maxWidth: 760, maxLines: 2)
            for line in lines.reversed() {
                drawText(line, font: font, color: .white, at: CGPoint(x: margin, y: cursorY),
                         in: context, shadow: true)
                cursorY += 64
            }
            // Brand chip above the headline.
            let chipFont = titleFont(size: 34)
            drawText(brandName.uppercased(), font: chipFont, color: accentColor,
                     at: CGPoint(x: margin, y: cursorY + 10), in: context, shadow: true)
        }
    }

    /// Full-frame typographic intro card for compilations.
    static func titleCard(_ text: String, brandName: String, accent: String,
                          logoURL: URL?, to directory: URL) -> URL? {
        draw(named: "brand_title_card", in: directory, background: .black) { context in
            let accentColor = color(accent)
            if let logoURL, let logo = NSImage(contentsOf: logoURL) {
                drawImage(logo, in: context,
                          rect: fittedRect(for: logo, width: 130,
                                           topLeft: CGPoint(x: (1080 - 130) / 2, y: 260)),
                          opacity: 0.95)
            }
            let font = titleFont(size: 96)
            let lines = wrap(text.uppercased(), font: font, maxWidth: 900, maxLines: 3)
            let lineHeight = 112.0
            var y = 960 + Double(lines.count - 1) * lineHeight / 2
            for line in lines {
                drawText(line, font: font, color: .white, at: nil, centeredY: y,
                         in: context, shadow: false)
                y -= lineHeight
            }
            // Accent rule under the title block.
            context.setFillColor(accentColor.cgColor)
            context.fill(CGRect(x: (1080 - 220) / 2, y: y + lineHeight - 72, width: 220, height: 10))
            drawText(brandName.uppercased(), font: titleFont(size: 34), color: accentColor,
                     at: nil, centeredY: y + lineHeight - 140, in: context, shadow: false)
        }
    }

    /// Branded outro: logo, brand name, tagline, follow CTA + handle.
    static func outroCard(profile: BrandProfile, to directory: URL) -> URL? {
        draw(named: "brand_outro", in: directory, background: .black) { context in
            let accentColor = color(profile.accentColor.isEmpty ? "#FFFFFF" : profile.accentColor)
            if let logoURL = profile.logoURL, let logo = NSImage(contentsOf: logoURL) {
                drawImage(logo, in: context,
                          rect: fittedRect(for: logo, width: 380,
                                           topLeft: CGPoint(x: (1080 - 380) / 2, y: 560)),
                          opacity: 1)
            }
            drawText(profile.brandName.uppercased(), font: titleFont(size: 64), color: .white,
                     at: nil, centeredY: 1010, in: context, shadow: false, tracking: 8)
            if !profile.tagline.isEmpty {
                drawText(profile.tagline.uppercased(), font: titleFont(size: 26),
                         color: NSColor.white.withAlphaComponent(0.7),
                         at: nil, centeredY: 940, in: context, shadow: false, tracking: 6)
            }
            drawText("FOLLOW", font: titleFont(size: 36),
                     color: accentColor, at: nil, centeredY: 560, in: context,
                     shadow: false, tracking: 10)
            let handle = profile.socials["instagram"]?.handle ?? ""
            if !handle.isEmpty {
                let display = handle.hasPrefix("@") ? handle : "@" + handle
                drawText(display, font: titleFont(size: 40), color: .white,
                         at: nil, centeredY: 490, in: context, shadow: false, tracking: 2)
            }
        }
    }

    /// A still card → a silent video clip concatenate() can splice in.
    static func cardClip(png: URL, duration: Double, output: URL) async throws {
        try await FFmpeg.run([
            "-loop", "1", "-framerate", "30", "-t", String(format: "%.2f", duration),
            "-i", png.path,
            "-f", "lavfi", "-t", String(format: "%.2f", duration),
            "-i", "anullsrc=r=44100:cl=stereo",
            "-vf", "format=yuv420p,scale=\(width):\(height)",
            "-c:v", "libx264", "-preset", "fast", "-crf", "18",
            "-c:a", "aac", "-shortest", "-y", output.path,
        ], timeout: 120)
    }

    // MARK: - Drawing plumbing

    private static func draw(named name: String, in directory: URL,
                             background: NSColor? = nil,
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
                                 in context: CGContext, shadow: Bool,
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
        let origin = point ?? CGPoint(x: (Double(width) - size.width) / 2, y: centeredY)
        string.draw(at: origin)
    }

    private static func fittedRect(for image: NSImage, width targetWidth: Double,
                                   topLeft: CGPoint) -> CGRect {
        let aspect = image.size.height > 0 ? image.size.height / image.size.width : 1
        let targetHeight = targetWidth * aspect
        // topLeft.y is measured from the TOP of the frame for readability.
        return CGRect(x: topLeft.x, y: Double(height) - topLeft.y - targetHeight,
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
