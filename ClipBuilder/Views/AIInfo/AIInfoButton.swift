import SwiftUI

struct AIInfoEntry: Identifiable {
    var id = UUID()
    var name: String
    var roles: [AIRole] = []
    var kind = AISettingsEnvelope.Kind.analysis
    var settings: [String: JSONSetting]?
    var notes: String = ""
    var output: GeneratedVideoRecord?
    static let notRecorded = "Settings not recorded for this run"
}

struct AIInfoButton: View {
    enum Style { case icon, model, full }
    @Environment(AppStore.self) private var store
    var provenance: AIProvenance? = nil
    var style: Style = .icon
    var role: String? = nil
    var size: CGFloat = 14
    var plated = false
    var video: VideoRecord? = nil
    var scene: SceneRecord? = nil
    var output: GeneratedVideoRecord? = nil
    var run: AnalysisRun? = nil
    @State private var showing = false

    private func roles(_ entries: [(String, AIProvenance?)]) -> [AIRole] {
        entries.compactMap { name, value in value.map { AIRole(role: name, provenance: $0) } }
    }
    private func runEntry(_ run: AnalysisRun) -> AIInfoEntry {
        var recorded = AISettingsJSON.decode([AIRole].self, run.modelsJSON) ?? []
        if recorded.isEmpty { recorded = roles([("Tagging", run.provenance)]) }
        return AIInfoEntry(
            name: run.name, roles: recorded,
            settings: AISettingsJSON.decode(AnalysisRunSettings.self, run.settingsJSON).map(
                JSONSetting.dictionary),
            notes: run.notesJSON ?? "")
    }
    private var entries: [AIInfoEntry] {
        if let output {
            let output = store.generatedVideos.first { $0.id == output.id } ?? output
            var recorded = AISettingsJSON.decode([AIRole].self, output.modelsJSON) ?? []
            for entry in roles([
                ("Plan", output.planProvenance), ("Captions", output.captionProvenance),
                ("Critique", output.critiqueProvenance), ("Cover", output.coverProvenance),
            ])
            where !recorded.contains(where: { $0.role == entry.role }) { recorded.append(entry) }
            return [
                AIInfoEntry(
                    name: output.filename, roles: recorded, kind: .wizard,
                    settings: AISettingsJSON.decode(WizardRunSettings.self, output.settingsJSON)?
                        .flattened,
                    notes: [
                        output.rationale, output.critiqueJSON, output.qualityJSON,
                        output.planClipsJSON,
                    ]
                    .compactMap { $0 }.joined(separator: "\n\n"), output: output)
            ]
        }
        if let run { return [runEntry(run)] }
        if let scene {
            var entry =
                store.analysisRuns.first { $0.id == scene.runID }.map(runEntry)
                ?? AIInfoEntry(name: scene.videoFilename)
            let recorded = AISettingsJSON.decode([AIRole].self, scene.modelsJSON) ?? []
            entry.roles += recorded
            entry.roles += roles([
                ("Curation", scene.curationProvenance), ("Framing", scene.framingProvenance),
            ]).filter { candidate in
                !recorded.contains { $0.role == candidate.role }
            }
            entry.notes = [scene.narrative, entry.notes].compactMap { $0 }.joined(separator: "\n")
            return [entry]
        }
        if let video {
            let video = store.videos.first { $0.id == video.id } ?? video
            let summary = AIInfoEntry(
                name: video.filename,
                roles: roles([
                    ("Tagging", video.visualAnalysisProvenance),
                    ("Transcript", video.transcriptionProvenance),
                    ("People", video.peopleProvenance), ("Naming", video.namingProvenance),
                ]))
            return store.analysisRuns.filter { $0.videoID == video.id }.map(runEntry) + [summary]
        }
        return [AIInfoEntry(name: role ?? "AI details", roles: roles([(role ?? "AI", provenance)]))]
    }
    // Avoid decoding potentially large prompt snapshots for every visible row.
    private var hasAIData: Bool {
        if let video {
            return video.visualAnalysisProvenance != nil || video.transcriptionProvenance != nil
                || video.peopleProvenance != nil || video.namingProvenance != nil
                || store.analysisRuns.contains { $0.videoID == video.id }
        }
        if let scene {
            return scene.curationProvenance != nil || scene.framingProvenance != nil
                || scene.modelsJSON != nil || store.analysisRuns.contains { $0.id == scene.runID }
        }
        if let output {
            return output.settingsJSON != nil || output.planProvenance != nil
                || output.captionProvenance != nil || output.critiqueProvenance != nil
                || output.coverProvenance != nil
        }
        if let run { return run.settingsJSON != nil || run.provenance != nil }
        return provenance != nil
    }

    var body: some View {
        if hasAIData {
            Button {
                showing = true
            } label: {
                Image(systemName: "sparkles").font(.system(size: size)).foregroundStyle(.secondary)
                    .padding(plated ? 4 : 0).background(
                        plated ? Color.black.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain).help("AI details").accessibilityLabel("AI details")
            .sheet(isPresented: $showing) { AIInfoSheet(entries: entries) }
        }
    }
}
