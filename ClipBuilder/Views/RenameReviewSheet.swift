import SwiftUI

/// End-of-analysis rename review: files whose names the analyzer judged
/// auto-generated (screen-recording defaults, IMG_…, hex strings) get a
/// proposed descriptive name built from the content — people, event, round.
/// The user edits or unchecks each proposal before it's applied.
struct RenameReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: RenameReviewRequest

    /// videoID → edited name (pre-filled with the analyzer's proposal).
    @State private var names: [Int64: String] = [:]
    /// videoID → whether this row's rename is applied on Rename.
    @State private var included: [Int64: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(request.suggestions.count == 1
                     ? "Rename suggestion"
                     : "\(request.suggestions.count) rename suggestions")
                    .font(.headline)
                Text("These filenames look auto-generated, so the analyzer built names from what it saw. Edit them, uncheck any you want to keep, then Rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(request.suggestions) { suggestion in
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
                    for suggestion in request.suggestions
                    where included[suggestion.videoID] ?? true {
                        let name = (names[suggestion.videoID] ?? suggestion.suggestedName)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty,
                              let video = store.videos.first(where: { $0.id == suggestion.videoID })
                        else { continue }
                        store.renameVideo(video, to: name)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!request.suggestions.contains { included[$0.videoID] ?? true })
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 220, idealHeight: 260)
        // Closing keeps the current filenames — nothing is renamed.
        .modalCloseButton { dismiss() }
    }
}
