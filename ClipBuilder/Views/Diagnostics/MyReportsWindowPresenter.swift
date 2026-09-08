import BugReporterKit
import SwiftUI

/// The kit's presenter is internal; host its public view in an app-owned window.
@MainActor
enum MyReportsWindowPresenter {
    private static var window: NSWindow?

    static func show() {
        guard BugReporting.requireConfiguration() else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: NavigationStack { MyReportsView() })
        let newWindow = NSWindow(contentViewController: controller)
        newWindow.title = "My Reports"
        newWindow.setContentSize(NSSize(width: 480, height: 420))
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }
}
