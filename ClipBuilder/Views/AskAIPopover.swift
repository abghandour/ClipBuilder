import SwiftUI

/// Ask AI (docs/Page-Assistant-Plan.md): what the assistant sees, what it
/// would do next here, and a free-text request.
struct AskAIPopover: View {
    @Environment(AppStore.self) private var store
    let assistant: any PageAssistant
    let close: () -> Void
    @State private var text = ""
    @State private var showingDismissed = false
    @FocusState private var focused: Bool

    var body: some View {
        let model = store.assistant
        let context = assistant.context(store: store)
        let actions = assistant.actions(store: store)
        let suggestions = model.suggestions(for: assistant, context: context, actions: actions, store: store)
        let dismissed = model.dismissedSuggestions(for: assistant, context: context, actions: actions, store: store)
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Ask AI · \(assistant.page)").font(.headline).lineLimit(1)
            contextLine(context)
            Divider()
            suggestionsSection(suggestions, actions: actions, model: model)
            Divider()
            askSection(model: model)
            if !dismissed.isEmpty {
                Divider()
                dismissedSection(dismissed, model: model)
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 420)
        .onAppear {
            focused = true
            model.refresh(assistant: assistant, store: store)
            // Let the first layout land before closing the open signpost
            // (`AskAIToolbar` starts it on the click or ⌘⇧A).
            let page = assistant.page
            DispatchQueue.main.async { UITiming.responseReady(screen: "Ask AI", what: page) }
        }
        // A setting applied from a row changes the context: rank again.
        .onChange(of: context.fingerprint) { _, _ in model.refresh(assistant: assistant, store: store) }
        // An AI answer ran an action: close like Send does for a direct one.
        .onChange(of: model.closeRequest) { _, request in if request != nil { close() } }
    }

    // MARK: - Context

    private func contextLine(_ context: AssistantContext) -> some View {
        Text(context.summaryLine)
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(context.detailText)
            .accessibilityLabel("Ask AI sees: \(context.summaryLine)")
    }

    // MARK: - Suggestions

    private func suggestionsSection(_ suggestions: [AssistantSuggestion], actions: [AssistantAction],
                                    model: AssistantModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Text("Suggestions").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
            if suggestions.isEmpty {
                Text("Nothing to suggest here").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ForEach(suggestions) { suggestion in
                    row(suggestion, action: suggestion.actionID.flatMap { id in actions.first { $0.id == id } },
                        model: model)
                }
            }
        }
    }

    private func row(_ suggestion: AssistantSuggestion, action: AssistantAction?, model: AssistantModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.spaceXS) {
                    Text(suggestion.title).font(.callout).lineLimit(1)
                    if let provenance = suggestion.provenance {
                        AIInfoButton(provenance: provenance, role: "Ranked by", size: 12)
                    }
                }
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if suggestion.kind != .insight, let action {
                Button {
                    run(suggestion)
                } label: {
                    if suggestion.kind == .setting {
                        Text("Apply").lineLimit(1)
                    } else {
                        Label("Run", systemImage: action.systemImage).lineLimit(1)
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(!action.isAvailable(store))
                .help(action.title)
            }
            Button {
                model.dismiss(suggestion, profileName: store.activeProfile.profileName)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Hide this suggestion until its reason changes")
            .accessibilityLabel("Dismiss \(suggestion.title)")
        }
    }

    private func run(_ suggestion: AssistantSuggestion) {
        // A setting changes in place and its row goes away; work closes the
        // popover so the status bar or the page shows what started.
        if suggestion.kind != .setting { close() }
        let outcome = store.assistant.run(suggestion, assistant: assistant, store: store)
        if suggestion.kind == .setting, case .unavailable = outcome { close() }
    }

    // MARK: - Dismissed

    /// "Show dismissed (N)": only rows this page would suggest now, each
    /// with Restore. Shown only when N > 0.
    private func dismissedSection(_ dismissed: [AssistantSuggestion], model: AssistantModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Button(showingDismissed ? "Hide dismissed" : "Show dismissed (\(dismissed.count))") {
                showingDismissed.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .help("Suggestions you hid on this page")
            if showingDismissed {
                ForEach(dismissed) { suggestion in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout).lineLimit(1)
                            Text(suggestion.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        Button("Restore") {
                            model.restore(suggestion, profileName: store.activeProfile.profileName)
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Show this suggestion again")
                        .accessibilityLabel("Restore \(suggestion.title)")
                    }
                }
            }
        }
        .onChange(of: dismissed.isEmpty) { _, empty in if empty { showingDismissed = false } }
    }

    // MARK: - Ask

    private func askSection(model: AssistantModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
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
            if let outcome = model.lastOutcome[assistant.page] {
                HStack(spacing: Theme.spaceXS) {
                    if model.isAsking(assistant.page) { ProgressView().controlSize(.small) }
                    Text(outcome.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(outcome.summary)
                }
            }
            HStack {
                Spacer()
                Button("Send", systemImage: "arrow.up") {
                    let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A request the page's keywords miss goes to the AI: stay
                    // open on "Asking…" until the answer lands.
                    if store.assistant.send(request, assistant: assistant, store: store).isPending {
                        text = ""
                    } else {
                        close()
                    }
                }
                .lineLimit(1).fixedSize()
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.isAsking(assistant.page))
            }
        }
    }
}
