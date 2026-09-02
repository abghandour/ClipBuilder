import SwiftUI

/// The whole transcript of one video, every segment editable in place.
/// Save writes all changed segments at once; a segment edited before can
/// be reverted to what the transcriber produced. Opened from the Raw
/// Videos detail pane and from batch/scene context menus.
struct TranscriptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var rows: [TranscriptRow] = []
    /// Edited text per segment id; only segments whose text differs from
    /// the stored row are written on Save.
    @State private var drafts: [Int64: String] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var confirmDiscard = false

    private var changedIDs: [Int64] {
        rows.compactMap { row in
            (drafts[row.id] ?? row.text) != row.text ? row.id : nil
        }
    }

    private var hasChanges: Bool { !changedIDs.isEmpty }

    /// Language shown per segment only when the transcript mixes languages
    /// (a translation stored alongside the original).
    private var showsLanguage: Bool {
        Set(rows.map { "\($0.language)|\($0.isTranslation)" }).count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Transcript — \(video.filename)")
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let provenance = rows.first?.provenance {
                            HStack(spacing: 4) {
                                Text("Transcribed by")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ProvenanceBadge(provenance: provenance, style: .full,
                                                role: "Transcribed by", size: 12)
                            }
                        }
                        if !rows.isEmpty {
                            Text("\(rows.count) segments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Re-transcribe") {
                    store.transcribe(video: video, force: true)
                    dismiss()
                }
                .help("Discard this transcript and run the transcriber again")
                Button(hasChanges ? "Save" : "Done") {
                    if hasChanges { save() } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.quote",
                    description: Text("Transcribe this video from the Raw Videos screen."))
                    // Fill the sheet's remaining height so the header stays
                    // pinned to the top instead of centering with it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            segmentRow(row)
                            Divider()
                        }
                    }
                }
            }

            if hasChanges {
                Divider()
                HStack {
                    Text("\(changedIDs.count) segment\(changedIDs.count == 1 ? "" : "s") edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard Changes") { drafts = [:] }
                        .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 680, height: 520)
        .modalCloseButton {
            if hasChanges { confirmDiscard = true } else { dismiss() }
        }
        .task { await load() }
        .confirmationDialog("Discard unsaved transcript edits?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Save and Close") { save() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func segmentRow(_ row: TranscriptRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.startTime.timecode)–\(row.endTime.timecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if showsLanguage {
                    Text(row.isTranslation ? "\(row.language) · translation" : row.language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 96, alignment: .leading)
            .padding(.top, 3)

            TextField("Segment text", text: Binding(
                get: { drafts[row.id] ?? row.text },
                set: { drafts[row.id] = $0 }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)

            if row.originalText != nil {
                Button("Revert") { revert(row) }
                    .controlSize(.mini)
                    .help("Restore the transcriber's original text for this segment")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background((drafts[row.id] ?? row.text) != row.text
                    ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func load() async {
        guard let database = store.database else { return }
        rows = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
        isLoading = false
    }

    private func save() {
        guard let database = store.database else { return }
        let changes = rows.compactMap { row -> (id: Int64, text: String)? in
            guard let draft = drafts[row.id] else { return nil }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != row.text ? (row.id, trimmed) : nil
        }
        guard !changes.isEmpty else { dismiss(); return }
        isSaving = true
        Task {
            do {
                try await database.updateTranscriptTexts(changes)
                drafts = [:]
                await load()
                dismiss()
            } catch {
                store.presentError("Could not save the transcript", error)
            }
            isSaving = false
        }
    }

    private func revert(_ row: TranscriptRow) {
        guard let database = store.database else { return }
        Task {
            try? await database.revertTranscriptText(id: row.id)
            drafts[row.id] = nil
            await load()
        }
    }
}
