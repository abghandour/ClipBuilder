import SwiftUI

struct CriticBriefControls: View {
    var showsUsePicker = false
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = "Checking critic brief…"

    private var refreshKey: String {
        let jobs = "\(store.jobs.completionRevision(.criticBrief)):\(store.jobs.completionRevision(.evaluateCritic))"
        let generated = store.generatedVideos.map { "\($0.id):\($0.favorite):\($0.audiencePercentile ?? -1)" }.joined(separator: ",")
        let references = store.igMedia.map { "\($0.id):\($0.localVideoPath ?? "")" }.joined(separator: ",")
        let downloads = store.igDownloadingMediaIDs.sorted().map(String.init).joined(separator: ",")
        return [String(store.profileGeneration), jobs, store.activeProfile.tasteRubric,
                store.activeProfile.houseStyle, store.activeProfile.criticBriefUse.rawValue,
                generated, references, downloads, store.igImportStatus ?? ""].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { usePicker; refreshButton }
                VStack(alignment: .leading) { usePicker; refreshButton }
            }
            Text(state).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).help(state)
        }
        .task(id: refreshKey) { await refresh() }
        .onChange(of: store.activeProfile.criticBriefUse) { _, _ in store.saveActiveProfile() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @ViewBuilder private var usePicker: some View {
        @Bindable var store = store
        if showsUsePicker {
            Picker("Use critic brief", selection: $store.activeProfile.criticBriefUse) {
                ForEach(CriticBriefUse.allCases, id: \.self) { use in
                    Text(use.title).tag(use)
                }
            }
            .lineLimit(1).fixedSize()
            .help("Automatic follows this profile's agreement keep rule. On uses a cached brief or builds one when needed. Off skips the brief during runs.")
        }
    }

    private var refreshButton: some View {
        Button("Refresh Critic Brief") { store.startCriticBriefRefresh() }
            .lineLimit(1).fixedSize()
            .disabled(store.database == nil || store.jobs.running.contains {
                $0.kind == .criticBrief && $0.subjectID == store.activeProfile.profileName
            })
    }

    private func refresh() async {
        let key = refreshKey
        let value = await store.criticBriefState()
        guard !Task.isCancelled, key == refreshKey else { return }
        state = value
    }
}
