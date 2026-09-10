import AppKit
import BugReporterKit
import SwiftUI

struct QAToolbarMenu: View {
    static let logoPointSize: CGFloat = 22
    /// The mark scaled past the circle so the rounded-square canvas falls away.
    static let logoOverscan: CGFloat = 1.16

    /// The logo drawn once into a 22 pt circle, so no layout modifier is
    /// needed wherever AppKit draws the label itself.
    static let logoImage: NSImage? = {
        guard let source = QAButtonLogo.nsImage else { return nil }
        return circular(source, pointSize: logoPointSize, overscan: logoOverscan)
    }()

    /// Draws `source` centred in a circle of `pointSize`, scaled by `overscan`
    /// so the source's corners fall outside the circle. Resolution independent:
    /// the drawing handler runs per backing scale.
    static func circular(_ source: NSImage, pointSize: CGFloat, overscan: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            let side = pointSize * overscan
            let origin = (pointSize - side) / 2
            source.draw(in: NSRect(x: origin, y: origin, width: side, height: side),
                        from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
    var body: some View {
        Menu {
            Button("Report a Bug…") { BugReporting.presentReport() }
            Button("Take Screenshot") { BugReporting.takeScreenshot() }
            Button("My Reports…") { MyReportsWindowPresenter.show() }
        } label: {
            // The VerticalCorn mark, cropped to a circle exactly like the kit's
            // iOS floating button. The image is pre-rendered at 22 pt because a
            // Menu label's image can be drawn natively by AppKit at the file's
            // own size (264 px) on some macOS releases, ignoring SwiftUI frames.
            // Falls back to the ladybug if the resource is missing.
            Group {
                if let logo = QAToolbarMenu.logoImage {
                    Image(nsImage: logo)
                } else {
                    Image(systemName: "ladybug.fill")
                }
            }
                .accessibilityLabel("Bug reporting")
                .overlay(alignment: .topTrailing) {
                    if ScreenshotStore.shared.count > 0 {
                        Text(ScreenshotStore.shared.count, format: .number)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(.red, in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Bug reporting, \(ScreenshotStore.shared.count) screenshots")
        .help("Report a bug, take a screenshot, or view your reports")
    }
}
