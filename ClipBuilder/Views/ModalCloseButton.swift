import SwiftUI

/// Standard modal chrome: an ✕ close button pinned at the sheet's top-left
/// corner, above the content. Escape triggers it. Sheets use this instead of
/// a footer Cancel button.
extension View {
    func modalCloseButton(action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(.top, 10)
            .padding(.leading, 12)
            .padding(.bottom, 2)
        }
    }
}
