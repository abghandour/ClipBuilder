import SwiftUI

struct BuilderWizardReplyForm: View {
    @Bindable var model: WizardSheetModel
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            if !model.conversation.turns.isEmpty {
                DisclosureGroup("Conversation (\(model.conversation.turns.count) replies)") {
                    ForEach(Array(model.conversation.turns.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: Theme.spaceXS) {
                            Text(turn.question).foregroundStyle(.secondary)
                            Text("You: " + turn.answer)
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.spaceXS)
                    }
                }
            }
            Text(model.clarificationQuestion ?? "What would you like to do?")
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Your answer", text: $model.reply, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .focused($replyFocused)
                .accessibilityLabel("Reply to the Wizard")
            if let message = model.replyValidationMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("New request", action: model.newConversation)
                Spacer()
                Button("Continue", action: model.beginReply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canContinueReply)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send your reply with the conversation and continue this preview. ⌘Return.")
            }
            Text("Your request and earlier answers stay in this conversation. Changes still need Apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spaceM)
        .background(.quinary, in: .rect(cornerRadius: Theme.mediaRadius))
        .onAppear { replyFocused = true }
    }
}
