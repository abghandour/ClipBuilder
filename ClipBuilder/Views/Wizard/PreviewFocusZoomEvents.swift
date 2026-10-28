import SwiftUI

/// Observes only the visible preview image. Mouse events still reach SwiftUI's
/// move/resize grips, and scrolling elsewhere keeps its normal responder chain.
struct PreviewFocusZoomEvents: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onMagnify: (CGFloat, Bool) -> Void

    final class EventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var owner: PreviewFocusZoomEvents
        var monitor: Any?
        var magnifying = false

        init(owner: PreviewFocusZoomEvents) { self.owner = owner }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak view, weak coordinator] event in
            let handled = MainActor.assumeIsolated {
                guard let view, let coordinator, let window = view.window,
                      window.isKeyWindow, event.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
                let inside = view.visibleRect.contains(view.convert(event.locationInWindow, from: nil))
                let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
                // Finish a pinch even if its last event lands outside the image,
                // but pass that outside event through to the rest of the window.
                if event.type == .magnify, ended, coordinator.magnifying {
                    coordinator.magnifying = false
                    coordinator.owner.onMagnify(inside ? 1 / max(0.01, 1 + event.magnification) : 1, true)
                    return inside
                }
                guard inside else { return false }
                if event.type == .magnify {
                    coordinator.magnifying = !ended
                    coordinator.owner.onMagnify(1 / max(0.01, 1 + event.magnification), ended)
                    return true
                }
                guard event.scrollingDeltaY != 0, !coordinator.magnifying else { return false }
                // Precise trackpad deltas are pixels; wheel deltas are coarser.
                // Scrolling down pulls back; spreading a pinch moves closer.
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
                let exponent = min(1, max(-1, -event.scrollingDeltaY * sensitivity))
                coordinator.owner.onScroll(exp(exponent))
                return true
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: EventView, context: Context) { context.coordinator.owner = self }

    static func dismantleNSView(_ view: EventView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}
