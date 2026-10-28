import AppKit
import SwiftUI

/// A one-line field that grows into a text area as soon as Return is
/// pressed: Return inserts a line break at the cursor instead of ending the
/// edit, so a short label and a two-line title use the same control.
struct NewlineTextField: View {
    let prompt: String
    @Binding var text: String
    var maxLines = 8

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(1...maxLines)
            .onSubmit(insertNewline)
    }

    /// The field editor inserts at the caret, as Option-Return would; with
    /// no editor the break goes at the end.
    private func insertNewline() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            text += "\n"
        }
    }
}
