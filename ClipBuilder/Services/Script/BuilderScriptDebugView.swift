#if DEBUG
import SwiftUI

/// Developer-only preview makes the JSON surface reviewable without exposing
/// an Apply path or connecting an agent to a live document.
struct BuilderScriptDebugView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var script = """
    [
      {"command":{"op":"add_text","text":"Preview only"},"bind":"title"},
      {"command":{"op":"query","query":{"kind":"timeline"}}}
    ]
    """
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?
    @State private var output = "Run a script to inspect its outcomes and complete document diff."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Preview JSON Script").font(.title2)
            Text("Commands edit an isolated session. Close discards the preview.")
                .foregroundStyle(.secondary)
            TextEditor(text: $script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .help("A JSON array of command steps with optional ID bindings.")
            ScrollView {
                Text(output).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200)
            HStack(spacing: Theme.spaceM) {
                Button("Run Preview") { runTask = Task { await run() } }
                    .disabled(isRunning)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Run this JSON against a fresh snapshot and show the diff.")
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close and discard the preview.")
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 760, minHeight: 620)
        .onDisappear { runTask?.cancel() }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        let baseline = store.builder.document
        let profile = store.activeProfile.profileName
        let project = store.activeProjectID
        let timeline = store.openTimelineID
        let json = Data(script.utf8)
        do {
            var library = ScriptLibrarySnapshot(projectID: store.activeProject?.id)
            library.videos = store.videos
            library.scenes = store.scenes
            library.people = store.people
            library.layouts = ScreenCropStore.all()
            library.tags = store.activeProfile.tagSchema.values.flatMap { $0 }
            for (index, bumper) in store.bumpers.enumerated() { library.bumpers["bumper:\(index)"] = bumper }
            for (index, sound) in AssetStore.allFiles(of: .music).enumerated() { library.sounds["sound:\(index)"] = sound.name }
            for (index, image) in AssetStore.allFiles(of: .images).enumerated() { library.images["image:\(index)"] = image.url.path }
            if let database = store.database {
                library.videos = try await database.fetchVideos(projectID: library.projectID)
                library.scenes = try await database.fetchScenes(projectID: library.projectID)
                for video in library.videos {
                    library.transcripts += try await database.fetchTranscripts(videoID: video.id)
                    library.features += try await database.fetchTranscriptFeatures(videoID: video.id)
                    library.proposals += try await database.fetchEditProposals(videoID: video.id)
                    if !(try await database.fetchVideoPeople(videoID: video.id)).isEmpty { library.videosWithPeople.insert(video.id) }
                }
            }
            try Task.checkCancellation()
            guard profile == store.activeProfile.profileName, project == store.activeProjectID,
                  timeline == store.openTimelineID,
                  TimelineDiff(before: baseline, after: store.builder.document).isEmpty else {
                throw ScriptError.invalid("The timeline changed while collecting query data. Run again.")
            }
            let session = BuilderScriptSession(live: store.builder, library: library)
            let result = session.run(json: json)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = ScriptValue.object([
                "result": try JSONDecoder().decode(ScriptValue.self, from: encoder.encode(result)),
                "diff": try JSONDecoder().decode(ScriptValue.self, from: encoder.encode(session.diff())),
                "resources": .object([
                    "bumpers": .array(library.bumpers.keys.sorted().map { .string($0) }),
                    "sounds": .array(library.sounds.keys.sorted().map { .string($0) }),
                    "images": .array(library.images.keys.sorted().map { .string($0) })
                ])
            ])
            output = String(decoding: try encoder.encode(report), as: UTF8.self)
            session.discard()
        } catch { if !Task.isCancelled { output = error.localizedDescription } }
    }
}
#endif
