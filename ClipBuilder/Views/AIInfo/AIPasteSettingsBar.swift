import AppKit
import SwiftUI

struct AIPasteSettingsBar: View {
    @Environment(AppStore.self) private var store
    let kind: AISettingsEnvelope.Kind
    var analysis: Binding<AnalysisRunSettings>? = nil
    @State private var available: AISettingsEnvelope?
    @State private var banner: String?
    @State private var undoValues: [String: Any]?
    @State private var undoAnalysis: AnalysisRunSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Paste Settings", systemImage: "doc.on.clipboard") { paste() }
                    .disabled(available?.kind != kind)
                if undoValues != nil { Button("Undo") { undo() } }
            }
            if let banner { Text(banner).font(.caption).textSelection(.enabled) }
        }
        .task {
            var lastChangeCount: Int?
            while !Task.isCancelled {
                let changeCount = NSPasteboard.general.changeCount
                if changeCount != lastChangeCount {
                    available = AISettingsPasteboard.read()
                    lastChangeCount = changeCount
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: store.activeProfile.profileName) {
            undoValues = nil
            banner = nil
        }
        .onChange(of: store.activeProjectID) {
            undoValues = nil
            banner = nil
        }
    }
    private func relevant(_ key: String) -> Bool {
        key.hasPrefix(kind == .wizard ? "wizard." : "analysis.") || key == SceneStacks.levelKey
    }
    private func paste() {
        guard let envelope = AISettingsPasteboard.read(), envelope.kind == kind else { return }
        let defaults = UserDefaults.standard
        undoValues = defaults.dictionaryRepresentation().filter { relevant($0.key) }
        undoAnalysis = analysis?.wrappedValue
        let current =
            kind == .wizard
            ? AISettingsPreferences.wizard(defaults: defaults, profile: store.activeProfile)
            : analysis.map { JSONSetting.dictionary($0.wrappedValue) }
                ?? AISettingsPreferences.analysis(defaults: defaults)
        let applied = envelope.applying(
            to: current, profile: store.activeProfile.profileName,
            videoPaths: Set(store.videos.map(\.path)), runIDs: Set(store.analysisRuns.map(\.id)),
            people: Set(store.people.map(\.key)), sceneIDs: Set(store.scenes.map(\.id)),
            sameVideo: analysis?.wrappedValue.videoPath)
        AISettingsPreferences.write(
            applied.settings, kind: kind, scopes: envelope.scopes, sourceName: envelope.sourceName,
            defaults: defaults)
        if let analysis,
            let value = AISettingsJSON.decode(
                AnalysisRunSettings.self, AISettingsJSON.encode(applied.settings))
        {
            analysis.wrappedValue = value
            if envelope.scopes.contains(.prompts) {
                defaults.set(AISettingsJSON.encode(value.notes), forKey: "analysis.pastedNotes")
            }
        }
        banner =
            "Settings pasted from \(envelope.sourceName)"
            + (applied.skipped.isEmpty
                ? "" : "\nSkipped: " + applied.skipped.joined(separator: ", "))
    }
    private func undo() {
        guard let undoValues else { return }
        if let undoAnalysis { analysis?.wrappedValue = undoAnalysis }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where relevant(key) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in undoValues { defaults.set(value, forKey: key) }
        self.undoValues = nil
        banner = nil
    }
}
