import SwiftUI

/// One monitor belongs to the screening surface, independent of player swaps.
struct PodcastHighlightScreeningKeys: NSViewRepresentable {
    let isActive: () -> Bool
    let rate: (PodcastHighlightScreeningState.Verdict) -> Void
    /// Any other unmodified key outside a text field (the trim view's
    /// Space, I and O). Returns true when it consumed the event.
    var other: ((NSEvent) -> Bool)? = nil

    final class Coordinator {
        var monitor: Any?
        var owner: PodcastHighlightScreeningKeys
        init(owner: PodcastHighlightScreeningKeys) { self.owner = owner }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            let handled = MainActor.assumeIsolated {
                guard let view, let coordinator, let window = view.window,
                      window.isKeyWindow, event.window === window else { return false }
                let editingText = window.firstResponder is NSText || window.firstResponder is NSTextField
                if let verdict = Self.verdict(for: event, isActive: coordinator.owner.isActive(), editingText: editingText) {
                    if !event.isARepeat { coordinator.owner.rate(verdict) }
                    return true
                }
                guard let other = coordinator.owner.other, !editingText, !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                return other(event)
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.owner = self }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    static func verdict(for event: NSEvent, isActive: Bool, editingText: Bool) -> PodcastHighlightScreeningState.Verdict? {
        guard isActive, !editingText,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 126 || key == "u" { return .approved }
        if event.keyCode == 125 || key == "d" { return .rejected }
        return nil
    }
}
