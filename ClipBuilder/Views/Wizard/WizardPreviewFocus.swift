import SwiftUI

private struct WizardPreviewFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    /// Preview controls own their keys even while a Footage item remains selected.
    var wizardPreviewFocused: Bool? {
        get { self[WizardPreviewFocusKey.self] }
        set { self[WizardPreviewFocusKey.self] = newValue }
    }
}

extension View {
    /// A quiet ring on the pane that has the keyboard. Space and Delete act
    /// on whichever pane that is, so it has to show; the system ring is off
    /// on these panes because it would sit on a scroll view's clipped edge.
    func keyboardFocusRing(_ focused: Bool, cornerRadius: CGFloat = 6) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
