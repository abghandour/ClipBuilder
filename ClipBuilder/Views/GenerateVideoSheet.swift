import SwiftUI

/// What footage a "Generate Video" request draws from: whole source videos
/// (Analyze tab) or the scenes currently displayed by a filtered browser
/// (Scenes/People tabs), whose people/tag filters ride into the Wizard.
enum GenerateVideoSource {
    case videos([VideoRecord])
    case scenes([SceneRecord], personKeys: Set<String>, tags: [String])
}

/// One question — "what should the video be?" — everything else is
/// interpreted from the answer and lands as editable settings in the Wizard.
struct GenerateVideoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: GenerateVideoSource

    @State private var requestText = ""
    @State private var history = Self.loadHistory()

    private var unanalyzedCount: Int {
        guard case .videos(let videos) = source else { return 0 }
        return videos.count(where: { $0.visualAnalyzedAt == nil })
    }

    private var sourceLabel: String {
        switch source {
        case .videos(let videos): return "the \(videos.count) selected video(s)"
        case .scenes(let scenes, _, _): return "the \(scenes.count) displayed scene(s)"
        }
    }

    /// Spells out exactly what footage rides into the Wizard — the same
    /// button means "selected videos" on Raw Videos but "displayed scenes +
    /// filters" on Scenes/People, so the sheet says which.
    private var sourceDescription: String {
        switch source {
        case .videos(let videos):
            return "Source: \(videos.count) selected video\(videos.count == 1 ? "" : "s")"
        case .scenes(let scenes, let personKeys, let tags):
            var parts = ["Source: \(scenes.count) scene\(scenes.count == 1 ? "" : "s") currently displayed"]
            if !personKeys.isEmpty {
                parts.append("people: \(personKeys.sorted().joined(separator: ", "))")
            }
            if !tags.isEmpty {
                parts.append("tags: \(tags.joined(separator: ", "))")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Request history

    private static let historyKey = "analyze.sampleRequestHistory"

    private static func loadHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    /// Newest first, deduplicated case-insensitively, capped — typing a
    /// fresh description automatically remembers it for next time.
    private static func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = loadHistory()
        entries.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        entries.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(entries.prefix(15)), forKey: historyKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Video")
                .font(.title3.bold())
            Text("Describe what to create from \(sourceLabel). Mention duration, content, overlays, music — the AI Wizard is filled in from your description, ready to review and run.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label(sourceDescription, systemImage: "film.stack")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(history, id: \.self) { entry in
                    Button {
                        requestText = entry
                    } label: {
                        Text(entry.count > 70 ? entry.prefix(70) + "…" : entry)
                    }
                }
                Divider()
                Button("Clear History", role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: Self.historyKey)
                    history = []
                }
            } label: {
                Label("Previous requests", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize()
            .disabled(history.isEmpty)
            .help(history.isEmpty
                  ? "Descriptions you generate with are remembered here for reuse"
                  : "Reuse a description from an earlier generated video")

            TextEditor(text: $requestText)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if requestText.isEmpty {
                        Text("e.g. “generate an action-packed 15s video with fight footage only and use the text overlay ‘Sample 1’ with the caption ‘Porrada day!’”")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                }

            if unanalyzedCount > 0 {
                Label("\(unanalyzedCount) selected video(s) haven't been analyzed — they'll be analyzed first so their footage can be used.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Generate Video") {
                    Self.remember(requestText)
                    switch source {
                    case .videos(let videos):
                        store.generateSampleVideo(description: requestText, videos: videos)
                    case .scenes(let scenes, let personKeys, let tags):
                        store.generateSampleVideo(description: requestText, scenes: scenes,
                                                  personKeys: personKeys, tags: tags)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                // ⌘⏎ rather than plain Return — the text editor owns Return.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .modalCloseButton { dismiss() }
    }
}
