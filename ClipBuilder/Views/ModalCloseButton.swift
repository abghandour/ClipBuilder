import SwiftUI

/// Standard modal chrome: an ✕ close button pinned at the sheet's top-left
/// corner, above the content. Escape triggers it. It never takes keyboard
/// focus, so a fresh sheet does not open with a ring around it; sheets
/// with an action row also carry a real Cancel or Close button there.
extension View {
    func modalCloseButton(action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            Button(action: action) {
                Label("Close", systemImage: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(.top, 10)
            .padding(.leading, 12)
            .padding(.bottom, 2)
        }
    }
}
