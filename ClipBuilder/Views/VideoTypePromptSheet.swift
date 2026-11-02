import SwiftUI

/// Asked before an analysis of recordings that have no type yet: the type
/// decides which passes run (podcast exchanges or visual scenes, fight
/// scoring), so a wrong guess means redoing the work. "Let analysis guess"
/// keeps the classifier, which only sees long recordings.
struct VideoTypePromptSheet: View {
    @Environment(AppStore.self) private var store
    let videos: [VideoRecord]
    /// Called with the videos carrying their chosen types, after they are saved.
    let onContinue: ([VideoRecord]) -> Void
    let onCancel: () -> Void

    @State private var choices: [Int64: String] = [:]
    @State private var saving = false
    @State private var cancelled = false

    static let guessTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            Text(videos.count == 1 ? "What kind of recording is this?" : "What kind of recordings are these?")
                .font(.headline)
            Text("The type picks the analysis: Podcast and Interview transcribe and group exchanges, Fight scores the action, the others find scenes. Short recordings cannot be guessed, so choose when you know.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(videos, id: \.id) { video in
                        HStack {
                            Text(video.filename).lineLimit(1).truncationMode(.middle)
                            Text(video.duration.timecode).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Spacer(minLength: Theme.spaceS)
                            Picker("Type", selection: binding(for: video)) {
                                Text("Let analysis guess").tag(Self.guessTag)
                                ForEach(VideoType.allCases, id: \.rawValue) { type in
                                    Text(type.label).tag(type.rawValue)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help(video.duration < Analyzer.minimumClassifiableDuration
                                  ? "Too short for the classifier: without a type it is analyzed as Other."
                                  : "The classifier looks at the first minutes when left to guess.")
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { cancelled = true; onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? "Saving…" : "Continue") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 520)
    }

    private func binding(for video: VideoRecord) -> Binding<String> {
        Binding(get: { choices[video.id] ?? Self.guessTag }, set: { choices[video.id] = $0 })
    }

    private func save() {
        saving = true
        let assignments = videos.reduce(into: [Int64: VideoType]()) { result, video in
            if let raw = choices[video.id], let type = VideoType(rawValue: raw) { result[video.id] = type }
        }
        Task {
            defer { saving = false }
            do {
                try await store.setVideoTypes(assignments)
                // The sheet may have been dismissed meanwhile: the types
                // are saved, but nothing starts.
                guard !cancelled else { return }
                let updated = videos.map { video in
                    var copy = video
                    if let type = assignments[video.id] { copy.videoType = type.rawValue }
                    return copy
                }
                onContinue(updated)
            } catch {
                store.presentError("Could not save the video types", error)
            }
        }
    }
}
