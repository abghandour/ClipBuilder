import AppKit
import SwiftUI

/// Remembers the size a user drags a split-view pane to across launches.
/// SwiftUI's H/VSplitView ignores ideal sizes when placing its divider, so
/// persistence rides on AppKit instead: the modifier finds the enclosing
/// NSSplitView and gives it an autosave name — AppKit then saves the divider
/// position as it moves and restores it on the next appearance.
extension View {
    /// A horizontally resizable pane (HSplitView child). Apply to exactly
    /// one pane per split; `key` is the split's autosave name.
    func rememberedPaneWidth(_ key: String, min: CGFloat, initial: CGFloat,
                             max: CGFloat? = nil) -> some View {
        frame(minWidth: min, idealWidth: initial, maxWidth: max)
            .background(SplitViewAutosave(name: key))
    }

    /// A vertically resizable pane (VSplitView child). Apply to exactly
    /// one pane per split; `key` is the split's autosave name.
    func rememberedPaneHeight(_ key: String, min: CGFloat, initial: CGFloat,
                              max: CGFloat? = nil) -> some View {
        frame(minHeight: min, idealHeight: initial, maxHeight: max)
            .background(SplitViewAutosave(name: key))
    }
}

private struct SplitViewAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The pane isn't in the window yet — climb to the split view once
        // the hierarchy exists.
        DispatchQueue.main.async { attach(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func attach(from view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let splitView = current as? NSSplitView {
                splitView.autosaveName = name
                return
            }
            ancestor = current.superview
        }
        NSLog("SplitViewAutosave: no NSSplitView ancestor for %@", name)
    }
}
