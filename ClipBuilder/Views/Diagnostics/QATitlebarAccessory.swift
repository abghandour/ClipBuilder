import AppKit
import SwiftUI

/// Pins Sync and the QA menu to the trailing edge of the window's title bar. A SwiftUI
/// `ToolbarItem` declared at the window root sorts before each screen's own
/// items, so it can never be the rightmost control; a trailing title-bar
/// accessory always is, on every screen.
@MainActor
enum QATitlebarAccessory {
    private static let identifier = NSUserInterfaceItemIdentifier("com.mokotti-solutions.clipbuilder.qa-accessory")
    private typealias RootView = QATitlebarControls

    static func sync(window: NSWindow, visible: Bool, syncVisible: Bool, store: AppStore) {
        let index = window.titlebarAccessoryViewControllers.firstIndex { $0.identifier == identifier }
        let rootView = RootView(store: store, visible: visible, syncVisible: syncVisible)
        switch (visible || syncVisible, index) {
        case (true, nil):
            let controller = NSTitlebarAccessoryViewController()
            controller.identifier = identifier
            controller.layoutAttribute = .trailing
            let host = NSHostingView(rootView: rootView)
            host.setFrameSize(host.fittingSize)
            controller.view = host
            window.addTitlebarAccessoryViewController(controller)
        case (true, let index?):
            let controller = window.titlebarAccessoryViewControllers[index]
            if let host = controller.view as? NSHostingView<RootView> {
                host.rootView = rootView
                host.setFrameSize(host.fittingSize)
            }
        case (false, let index?):
            window.removeTitlebarAccessoryViewController(at: index)
        default:
            break
        }
    }
}

private struct QATitlebarControls: View {
    let store: AppStore
    let visible: Bool
    let syncVisible: Bool

    var body: some View {
        // Both controls are AppKit bezels of the same control size, so
        // their centres line up; a borderless image next to a bordered
        // popup sat visibly higher.
        HStack(alignment: .center, spacing: 8) {
            if syncVisible { TeamSyncTitlebarButton().environment(store) }
            if visible { QAToolbarMenu() }
        }
        .padding(.horizontal, 8)
        // The trailing accessory lays out below the toolbar's own row;
        // bottom padding lifts both controls onto the toolbar line.
        .padding(.bottom, 12)
    }
}

struct TeamSyncTitlebarButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button { store.teamSync.syncNow() } label: {
            Group {
                if store.teamSync.syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.teamSync.status.hasPrefix("Offline") ? Color.orange : Color.primary)
                }
            }
            // Same 22 pt content box as the QA logo so both bezels are the
            // same height.
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help(store.teamSync.status + " — click to sync now")
        .accessibilityLabel("Sync with team")
        .disabled(store.teamSync.syncing || store.teamSync.paused || store.teamSync.replacingProfile)
    }
}

/// Zero-size view that installs or removes the accessory once it has a window,
/// and updates its contents whenever QA or Team Sync visibility changes.
struct QATitlebarAccessoryInstaller: NSViewRepresentable {
    let store: AppStore
    let visible: Bool
    let syncVisible: Bool

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
        QATitlebarAccessory.sync(window: window, visible: visible, syncVisible: syncVisible, store: store)
    }
}
