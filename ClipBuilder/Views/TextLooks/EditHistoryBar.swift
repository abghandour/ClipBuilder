import SwiftUI

/// Undo, Redo and Discard Changes under a Text Looks inspector. The owner
/// keeps the `EditHistory`; this row only shows what it allows.
struct EditHistoryBar: View {
    var canUndo: Bool
    var canRedo: Bool
    var canDiscard: Bool
    var undo: () -> Void
    var redo: () -> Void
    var discard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // An inspector can be 280 points wide: titles give way to icons.
            ViewThatFits(in: .horizontal) {
                buttons.labelStyle(.titleAndIcon)
                buttons.labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.spaceM).padding(.vertical, Theme.spaceS)
        }
    }

    private var buttons: some View {
        HStack(spacing: Theme.spaceS) {
            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(!canUndo)
                .lineLimit(1).fixedSize()
                .help("Undo the last change to this look")
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(!canRedo)
                .lineLimit(1).fixedSize()
                .help("Redo the change that was undone")
            Spacer(minLength: Theme.spaceS)
            Button("Discard Changes", systemImage: "arrow.counterclockwise", action: discard)
                .disabled(!canDiscard)
                .lineLimit(1).fixedSize()
                .help("Return this look to how it was when you opened it. Undo brings the changes back")
        }
    }
}
