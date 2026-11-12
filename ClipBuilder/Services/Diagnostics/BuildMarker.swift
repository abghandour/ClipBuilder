import AppKit
import SwiftUI

/// Tells a build run from Xcode apart from the installed app: both share a
/// name, an icon and a bundle id, and both can be open at once. A Debug
/// build marks its window title, its status bar and its Dock icon; a Release
/// build compiles none of it in.
nonisolated enum BuildMarker {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    static let label = "Debug"

    /// " · Debug" after a window title, or nothing in a release.
    static var titleSuffix: String { isDebug ? " · \(label)" : "" }

    /// The icon with an orange band across its lower part naming the build.
    @MainActor static func markedIcon(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            // App icons keep a transparent margin; the band sits inside the tile.
            let band = NSRect(x: rect.width * 0.15, y: rect.height * 0.16,
                              width: rect.width * 0.7, height: rect.height * 0.22)
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: band, xRadius: band.height * 0.3, yRadius: band.height * 0.3).fill()
            let text = NSAttributedString(string: label.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: band.height * 0.62, weight: .heavy),
                .foregroundColor: NSColor.black,
                .kern: band.height * 0.06,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: band.midX - textSize.width / 2, y: band.midY - textSize.height / 2))
            return true
        }
    }

    /// Marks the Dock icon for as long as this process runs.
    @MainActor static func markDockIcon() {
        guard isDebug, let icon = NSApp.applicationIconImage else { return }
        NSApp.applicationIconImage = markedIcon(icon)
    }
}

/// The status bar's build pill; draws nothing in a release.
struct BuildMarkerBadge: View {
    var body: some View {
        if BuildMarker.isDebug {
            Text(BuildMarker.label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.orange, in: Capsule())
                .lineLimit(1).fixedSize()
                .help("This is a Debug build run from Xcode, not the installed app")
                .accessibilityLabel("Debug build")
        }
    }
}
