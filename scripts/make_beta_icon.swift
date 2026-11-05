#!/usr/bin/env swift
// Generates ClipBuilder/Assets.xcassets/AppIcon-Beta.appiconset from the
// stable AppIcon set: the same icon under a blue diagonal BETA banner across
// the lower-right corner, so the two sets never drift. Run from the repo
// root after changing the stable icon:
//
//     swift scripts/make_beta_icon.swift
//
// The banner is about a third of the icon wide, white heavy uppercase text,
// legible at 32 pt in the Dock and Finder lists; at 16 pt it is a blue corner.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("ClipBuilder/Assets.xcassets/AppIcon.appiconset")
let target = root.appendingPathComponent("ClipBuilder/Assets.xcassets/AppIcon-Beta.appiconset")
let blue = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)  // Color.blue on macOS

guard let master = NSImage(contentsOf: source.appendingPathComponent("icon_512x512@2x.png")) else {
    fatalError("missing stable master icon_512x512@2x.png")
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)

    let cg = context.cgContext
    // Banner geometry: a band at 45° through the lower-right corner. Its
    // centre line passes through (0.76, 0.24) of the icon; width 0.2.
    let bandWidth = size * 0.2
    cg.translateBy(x: size * 0.76, y: size * 0.24)
    cg.rotate(by: .pi / 4)
    let band = CGRect(x: -size, y: -bandWidth / 2, width: size * 2, height: bandWidth)
    cg.setFillColor(blue.cgColor)
    cg.fill(band)
    if pixels >= 32 {
        let font = NSFont.systemFont(ofSize: bandWidth * 0.68, weight: .black)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                         .kern: bandWidth * 0.04]
        let text = NSAttributedString(string: "BETA", attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2 + bandWidth * 0.02))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
        try render(pixels: point * scale).write(to: target.appendingPathComponent(name))
    }
}
try FileManager.default.copyItem(at: source.appendingPathComponent("Contents.json"),
                                 to: target.appendingPathComponent("Contents.json.tmp"))
_ = try? FileManager.default.removeItem(at: target.appendingPathComponent("Contents.json"))
try FileManager.default.moveItem(at: target.appendingPathComponent("Contents.json.tmp"),
                                 to: target.appendingPathComponent("Contents.json"))
print("wrote \(target.path)")
