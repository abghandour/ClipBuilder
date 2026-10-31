import SwiftUI

struct AskAIPopover: View {
    let assistant: any PageAssistant
    let outcome: AskAIOutcome?
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Ask AI · \(assistant.page)").font(.headline)
            TextField("What would you like to do?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
            ForEach(Array(assistant.examples.prefix(3)), id: \.self) { example in
                Button { text = example; focused = true } label: {
                    Text(example).font(.callout).multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
            }
            if let outcome {
                Text(outcome.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(outcome.summary)
            }
            HStack {
                Spacer()
                Button("Send", systemImage: "arrow.up") {
                    send(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .lineLimit(1).fixedSize()
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}
