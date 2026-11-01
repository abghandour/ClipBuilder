import SwiftUI

/// Keeps Ask AI's "Apply cleanup cuts" count current for the open timeline
/// (BuilderAssistant). Always mounted with the Builder, unlike the Cleanup
/// Cuts inspector section, which shows only while a video clip is
/// selected. Counts accepted cuts after each document revision settles and
/// publishes them keyed by timeline id and revision, so the assistant never
/// reads a count made for another timeline or an earlier edit.
struct BuilderCleanupCutsPublisher: View {
    @Environment(AppStore.self) private var store

    private struct Key: Equatable {
        var generation: Int
        var timelineID: Int64?
        var revision: Int
        var videoIDs: Set<Int64>
    }

    var body: some View {
        let key = Key(generation: store.profileGeneration, timelineID: store.builder.timelineID,
                      revision: store.builder.revision, videoIDs: store.builderVideoIDs())
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) { await publish(key) }
    }

    private func publish(_ key: Key) async {
        guard key.timelineID != nil else { return }
        // Let a drag or a run of edits settle before reading the database.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let cuts = key.videoIDs.isEmpty ? [:] : await store.acceptedCleanupCuts(videoIDs: key.videoIDs)
        guard !Task.isCancelled, store.profileGeneration == key.generation,
              store.builder.timelineID == key.timelineID, store.builder.revision == key.revision else { return }
        let total = store.builder.cleanupCutCount(cuts, videoIDsByPath: store.videoIDsByPath)
        store.assistant.updatePageState(BuilderAssistant().page,
            BuilderAssistant.cleanupCutsState(total, timelineID: key.timelineID, revision: key.revision))
    }
}
