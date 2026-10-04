import SwiftUI
import AppKit

/// A custom separator avoids AppKit split-view layout with fixed-height panes.
struct TranscriptQAColumnDivider: View {
    let column: TranscriptQAColumns.Column
    let width: CGFloat
    let onResize: (CGFloat) -> Void
    let onReset: () -> Void
    @State private var dragStartWidth: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: TranscriptQAColumns.dividerWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering && !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !hovering {
                    restoreCursor()
                }
            }
            .onDisappear { restoreCursor() }
            .gesture(DragGesture(coordinateSpace: .named("transcriptQA.columns"))
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = width }
                    let delta = column == .list ? value.translation.width : -value.translation.width
                    onResize((dragStartWidth ?? width) + delta)
                }
                .onEnded { _ in dragStartWidth = nil })
            .onTapGesture(count: 2, perform: onReset)
            .help("Drag to resize")
            .accessibilityElement()
            .accessibilityLabel(column == .list ? "Exchange list width" : "Transcript width")
            .accessibilityValue("\(Int(width.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onResize(width + 20)
                case .decrement: onResize(width - 20)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Reset width", onReset)
    }

    private func restoreCursor() {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
