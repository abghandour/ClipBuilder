import SwiftUI

/// Answers the reel's Select (`AppStore.miniReelReveal`) in one Footage
/// section: the section selects the item and clears the request, but only
/// while it is the open section. Hidden sections stay mounted, so a request
/// made while another section is open waits until this one is shown.
private struct MiniReelRevealModifier: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.workspacePageVisible) private var pageVisible
    let kind: MiniWizardFlow.FootageKind
    let contains: (Int64) -> Bool
    let select: (Int64) -> Void

    private struct Trigger: Equatable {
        var reveal: MiniReelRules.Key?
        var visible: Bool
    }

    func body(content: Content) -> some View {
        content.onChange(of: Trigger(reveal: store.miniReelReveal, visible: pageVisible), initial: true) { _, trigger in
            guard trigger.visible, let reveal = trigger.reveal, reveal.kind == kind, contains(reveal.itemID) else { return }
            select(reveal.itemID)
            store.miniReelReveal = nil
        }
    }
}

extension View {
    func onMiniReelReveal(_ kind: MiniWizardFlow.FootageKind, contains: @escaping (Int64) -> Bool,
                          select: @escaping (Int64) -> Void) -> some View {
        modifier(MiniReelRevealModifier(kind: kind, contains: contains, select: select))
    }
}
