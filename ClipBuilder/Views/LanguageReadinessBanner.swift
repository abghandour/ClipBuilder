import SwiftUI
import Translation

struct LanguageReadinessBanner: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    @Environment(\.workspacePageVisible) private var pageVisible
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"
    @State private var mounted = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var installing: LanguageAsset?
    @State private var generation = 0
    @State private var projectID: Int64?
    @State private var workID: UUID?
    @State private var requestID: UUID?

    var body: some View {
        if let project = store.activeProject {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    summary
                    Spacer(minLength: 0)
                    controls(project)
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    summary
                    controls(project)
                }
            }
            .font(.caption)
            .padding(Theme.spaceM)
            .background(.bar)
            .onAppear { mounted = true; startNext() }
            .onChange(of: pageVisible) { _, visible in
                if visible { startNext() } else { cancel(requeue: true) }
            }
            .onChange(of: store.languageTranslationInstall?.pending, initial: true) { _, _ in startNext() }
            .onChange(of: store.languageTranslationInstall?.id) { _, id in
                if id != workID { cancel(requeue: false); startNext() }
            }
            .onChange(of: store.activeProjectID) { _, _ in cancel(requeue: false) }
            .onChange(of: store.profileGeneration) { _, _ in cancel(requeue: false) }
            .onReceive(NotificationCenter.default.publisher(for: ElevenLabsVoices.settingsChanged)) { _ in
                Task { await store.refreshLanguageReadiness() }
            }
            .translationTask(configuration) { session in
                guard let asset = installing, let capturedRequest = requestID else { return }
                let capturedGeneration = generation
                let capturedProject = projectID
                let capturedWork = workID
                var failure: String?
                do {
                    try await session.prepareTranslation()
                    try Task.checkCancellation()
                } catch { failure = "\(asset.title): \(error.userMessage)" }
                guard capturedGeneration == store.profileGeneration, capturedProject == store.activeProjectID,
                      capturedWork == store.languageTranslationInstall?.id, capturedRequest == requestID else { return }
                store.languageTranslationInstall?.current = nil
                store.languageTranslationInstall?.failure = failure
                if let failure { store.appendLog(\.analysisLog, [failure]) }
                installing = nil
                requestID = nil
                configuration = nil
                await store.refreshLanguageReadiness()
                Task { startNext() }
            }
            .onDisappear { mounted = false; cancel(requeue: true) }
        }
    }

    private var summary: some View {
        let checked = store.activeProjectID.flatMap { store.projectLanguageAssets[$0] } != nil
        let message = checked ? (LanguageReadiness.summary(store.languageAssets) ?? "Project languages are ready on this Mac") : "Checking project languages…"
        return Label(message, systemImage: LanguageReadiness.missing(store.languageAssets).isEmpty ? "globe" : "exclamationmark.triangle")
            .lineLimit(1).fixedSize(horizontal: false, vertical: true).help(message)
    }

    private func controls(_ project: ProjectRecord) -> some View {
        HStack(spacing: Theme.spaceS) {
            if store.languageAssets.contains(where: \.installable) {
                Button("Install", systemImage: "arrow.down.circle") { store.installLanguageAssets() }
                    .disabled(installing != nil || store.jobs.running.contains { $0.kind == .languageAssets })
            }
            Button("Languages…") { store.languageEditorProject = project }
            if store.languageAssets.contains(where: { $0.kind == .dubVoice && $0.dubEngine == .elevenLabs && $0.state != .installed }) {
                Button("Open Settings…") {
                    settingsTab = "ai"
                    openSettings()
                }
                .help("Check your ElevenLabs key and account voices in Settings > AI.")
            }
            if store.languageAssets.contains(where: {
                $0.dubEngine != .elevenLabs && ($0.state == .unsupported || ($0.kind == .dubVoice && $0.state != .installed))
            }) {
                Button("Open System Settings") { openURL(SiriDubVoices.spokenContentSettingsURL) }
                    .help("Download voices in Spoken Content. Siri voices also need a Clip Builder Dub shortcut. Unsupported recognizers require choosing another spoken language.")
            }
        }
        .lineLimit(1).fixedSize()
    }

    private func startNext() {
        guard mounted, pageVisible, installing == nil, var work = store.languageTranslationInstall, work.failure == nil,
              work.current == nil, !work.pending.isEmpty,
              work.projectID == store.activeProjectID, work.generation == store.profileGeneration else { return }
        let asset = work.pending.removeFirst()
        let pair = asset.language.components(separatedBy: "→")
        guard pair.count == 2 else { return }
        generation = work.generation
        projectID = work.projectID
        workID = work.id
        requestID = UUID()
        installing = asset
        work.current = asset
        store.languageTranslationInstall = work
        configuration = TranslationSession.Configuration(source: Locale.Language(identifier: pair[0]), target: Locale.Language(identifier: pair[1]))
    }

    private func cancel(requeue: Bool) {
        if requeue, let asset = installing, store.languageTranslationInstall?.id == workID {
            store.languageTranslationInstall?.pending.insert(asset, at: 0)
            store.languageTranslationInstall?.current = nil
        }
        requestID = nil
        installing = nil
        configuration = nil
        workID = nil
    }
}
