import SwiftUI

/// End-of-analysis rename review: files whose names the analyzer judged
/// auto-generated (screen-recording defaults, IMG_…, hex strings) get a
/// proposed descriptive name built from the content — people, event, round.
/// The user edits or unchecks each proposal before it's applied.
struct RenameReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: RenameReviewRequest

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(request.suggestions.count == 1
                         ? "Rename suggestion"
                         : "\(request.suggestions.count) rename suggestions")
                        .font(.headline)
                    if let provenance = request.suggestions.first?.provenance {
                        ProvenanceBadge(provenance: provenance, style: .full, role: "Named by")
                    }
                }
                Text("These filenames look auto-generated or misspelled, so the analyzer built corrected names from what it saw. Edit them, uncheck any you want to keep, then Rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            RenameSuggestionEditor(suggestions: request.suggestions,
                                   onApplied: { dismiss() })
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 220, idealHeight: 260)
        // Closing keeps the current filenames — nothing is renamed.
        .modalCloseButton { dismiss() }
    }
}

/// The editable proposal list + Rename action shared by the end-of-analysis
/// review sheet and the File Name Wizard. Applying goes through
/// `store.renameVideo`, which moves the file and rebuilds derived
/// analyze-batch labels.
struct RenameSuggestionEditor: View {
    @Environment(AppStore.self) private var store
    let suggestions: [RenameSuggestion]
    /// Called after the checked renames are applied (dismiss the sheet).
    var onApplied: () -> Void

    /// videoID → edited name (pre-filled with the AI's proposal).
    @State private var names: [Int64: String] = [:]
    /// videoID → whether this row's rename is applied on Rename.
    @State private var included: [Int64: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { included[suggestion.videoID] ?? true },
                            set: { included[suggestion.videoID] = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Uncheck to keep the current filename")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.currentFilename)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("Current filename")
                            TextField("New name", text: Binding(
                                get: { names[suggestion.videoID] ?? suggestion.suggestedName },
                                set: { names[suggestion.videoID] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(!(included[suggestion.videoID] ?? true))
                        }
                    }
                    .padding(10)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
        }

        HStack {
            Spacer()
            Button("Rename") {
                for suggestion in suggestions
                where included[suggestion.videoID] ?? true {
                    let name = (names[suggestion.videoID] ?? suggestion.suggestedName)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty,
                          let video = store.videos.first(where: { $0.id == suggestion.videoID })
                    else { continue }
                    // An edited proposal is still the model's work in origin;
                    // the stamp says which model proposed the name.
                    store.renameVideo(video, to: name, provenance: suggestion.provenance)
                }
                onApplied()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!suggestions.contains { included[$0.videoID] ?? true })
        }
        .padding()
    }
}
