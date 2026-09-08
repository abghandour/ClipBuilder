import AppKit
import SwiftUI

/// Pins the QA menu to the trailing edge of the window's title bar. A SwiftUI
/// `ToolbarItem` declared at the window root sorts before each screen's own
/// items, so it can never be the rightmost control; a trailing title-bar
/// accessory always is, on every screen.
@MainActor
enum QATitlebarAccessory {
    private static let identifier = NSUserInterfaceItemIdentifier("com.mokotti-solutions.clipbuilder.qa-accessory")

    static func sync(window: NSWindow, visible: Bool) {
        let index = window.titlebarAccessoryViewControllers.firstIndex { $0.identifier == identifier }
        switch (visible, index) {
        case (true, nil):
            let controller = NSTitlebarAccessoryViewController()
            controller.identifier = identifier
            controller.layoutAttribute = .trailing
            let host = NSHostingView(rootView: QAToolbarMenu().padding(.horizontal, 8))
            host.setFrameSize(host.fittingSize)
            controller.view = host
            window.addTitlebarAccessoryViewController(controller)
        case (false, let index?):
            window.removeTitlebarAccessoryViewController(at: index)
        default:
            break
        }
    }
}

/// Zero-size view that installs or removes the accessory once it has a window,
/// and again whenever `visible` changes (the Settings toggle in Release).
struct QATitlebarAccessoryInstaller: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(nsView) }
    }

    private func attach(_ view: NSView) {
        guard let window = view.window else { return }
        QATitlebarAccessory.sync(window: window, visible: visible)
    }
}
