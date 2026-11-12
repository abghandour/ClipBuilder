import SwiftUI

/// Express Footage header: which transcript of the source is in use. It
/// applies to every Footage tab, so it sits on the card, not in one of them.
/// A menu when the video has several; the one transcript's name when it has
/// one; "No transcript" when it has none. Changing it brings the picks and
/// Q&A sections made on that transcript. The owner loads `sets`: a task on
/// this view would never start while it draws nothing.
struct MiniTranscriptSetControl: View {
    let videoID: Int64
    let sets: [TranscriptionSet]
    @Environment(AppStore.self) private var store

    private var active: TranscriptionSet? { sets.first(where: \.isActive) ?? sets.first }

    private var selection: Binding<String> {
        Binding(get: { active?.id ?? "" },
                set: { key in
                    guard !key.isEmpty, key != active?.id else { return }
                    store.setMiniTranscriptSet(videoID: videoID, key: key)
                })
    }

    private var picker: some View {
        Picker("Transcript", selection: selection) {
            ForEach(sets) { set in
                Text(TranscriptSetSwitch.label(set)).lineLimit(1).tag(set.id)
            }
        }
        .labelsHidden().lineLimit(1)
        .disabled(store.isWizardRunning || store.miniEditsBlocked)
        .help("Use another transcript of this video. Picks and Q&A sections are kept per transcript.")
        .accessibilityLabel("Transcript")
    }

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Text("Transcript").lineLimit(1).fixedSize().foregroundStyle(.secondary).accessibilityHidden(true)
            if sets.count > 1 {
                // Wide enough for the whole name; truncated only when the header cannot hold it.
                ViewThatFits(in: .horizontal) {
                    picker.fixedSize()
                    picker
                }
            } else if let active {
                Text(TranscriptSetSwitch.label(active)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help("This video's transcript. Transcribe it again to have another to choose from.")
            } else {
                Text("No transcript").lineLimit(1).fixedSize().foregroundStyle(.secondary)
                    .help("This video has not been transcribed. Q&A and Transcript need a transcript; Fight metrics does not.")
            }
            if let active { TranscriptSetRenameButton(videoID: videoID, set: active) }
        }
        .controlSize(.small)
    }
}

/// Names a transcript set, from the Express row and the Transcript sheet.
struct TranscriptSetRenameButton: View {
    let videoID: Int64
    let set: TranscriptionSet
    var renamed: () -> Void = {}
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    private func save(_ value: String) {
        editing = false
        Task {
            await store.renameTranscriptSet(videoID: videoID, key: set.id, name: value)
            renamed()
        }
    }

    var body: some View {
        Button("Rename", systemImage: "pencil") {
            name = set.name ?? ""
            editing = true
        }
        .labelStyle(.iconOnly).lineLimit(1).fixedSize()
        .help("Name this transcript")
        .accessibilityLabel("Rename transcript")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                TextField("Transcript name", text: $name, prompt: Text(TranscriptSetSwitch.date(set.createdAt)))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .focused($focused)
                    .onSubmit { save(name) }
                HStack(spacing: Theme.spaceS) {
                    Button("Remove Name") { save("") }
                        .lineLimit(1).fixedSize().disabled((set.name ?? "").isEmpty)
                        .help("Show this transcript by its date and model again")
                    Spacer(minLength: 0)
                    Button("Cancel", role: .cancel) { editing = false }.lineLimit(1).fixedSize()
                    Button("Save") { save(name) }
                        .lineLimit(1).fixedSize().keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Theme.spaceM)
            .onAppear { focused = true }
        }
    }
}
