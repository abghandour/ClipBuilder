import AppKit
import Testing
@testable import Clip_Builder

@MainActor struct QAToolbarMenuTests {
    /// The menu label must never inherit the 264 px file size: AppKit can draw a
    /// Menu label's image natively at its own size, which made the button
    /// gigantic on another Mac.
    @Test func logoIsPreRenderedAtButtonSize() {
        let source = NSImage(size: NSSize(width: 264, height: 264), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let rendered = QAToolbarMenu.circular(source, pointSize: 22, overscan: 1.16)
        #expect(rendered.size == NSSize(width: 22, height: 22))
        #expect(rendered.isTemplate == false)
        if let logo = QAToolbarMenu.logoImage {
            #expect(logo.size == NSSize(width: QAToolbarMenu.logoPointSize, height: QAToolbarMenu.logoPointSize))
        }
    }
}
