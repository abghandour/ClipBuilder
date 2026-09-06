import AppKit
import Foundation
import Testing

@testable import Clip_Builder

@Suite("Captured AI settings")
@MainActor
struct AISettingsTests {
    @Test("Analysis settings preserve optional choices and notes")
    func analysisRoundTrip() throws {
        let value = AnalysisRunSettings(
            instructions: "Find the finish", sampleInterval: 2,
            includeTranscript: true, language: "pt", detectPeople: false, autoZoomUnframed: true,
            breakdownTags: ["action"], trimRange: [3, 45],
            notes: [.init(at: 8, note: "watch this")],
            provider: "claude", model: "chosen", videoPath: "/fixture.mp4", sourcePeople: ["a"],
            sourceProfile: "profile",
            modelPrompts: ["Tagging": .init(role: "Tagging", prompt: "Actual prompt")])
        #expect(
            AISettingsJSON.decode(AnalysisRunSettings.self, AISettingsJSON.encode(value)) == value)
    }

    @Test("Wizard settings preserve all options without derived benchmarks")
    func wizardRoundTrip() throws {
        var options = WizardOptions()
        options.aiInstructions = "Tell a story"
        options.selectedRunIDs = [1, 2]
        options.sourcePeople = ["a"]
        options.modelOverride = "chosen"
        options.templateJSON = "{}"
        options.allowedTransitions = ["cut"]
        options.targetDurationSeconds = 30
        options.includeOutro = false
        let value = WizardRunSettings(
            options: options, stackLevel: "fine", sourceProfile: "profile",
            sourceVideoPaths: ["/a.mp4"], sourceSceneIDs: [3], builderDocumentJSON: "{}")
        let encoded = try #require(AISettingsJSON.encode(value))
        let decoded = try #require(AISettingsJSON.decode(WizardRunSettings.self, encoded))
        #expect(decoded.options.selectedRunIDs == value.options.selectedRunIDs)
        var expected = value
        var actual = decoded
        expected.options.selectedRunIDs = []
        actual.options.selectedRunIDs = []
        #expect(JSONSetting.dictionary(actual) == JSONSetting.dictionary(expected))
        #expect(!encoded.contains("accountBenchmarks"))
    }

    @Test("Envelope round trip and scopes omit unrelated fields")
    func envelopeRoundTrip() throws {
        let envelope = AISettingsEnvelope(
            kind: .analysis, sourceName: "Source", scopes: [.models],
            settings: JSONSetting.dictionary(
                AnalysisRunSettings(instructions: "private prompt", provider: "claude")))
        let decoded = try #require(
            AISettingsJSON.decode(AISettingsEnvelope.self, AISettingsJSON.encode(envelope)))
        #expect(decoded.settings == envelope.settings)
        #expect(decoded.settings["instructions"] == nil)
        #expect(decoded.scopes == [.models])
        #expect(decoded.settings["model"] == .null)
    }

    @Test("Scoped paste preserves every nonselected field")
    func scopeIsolation() throws {
        for kind in [AISettingsEnvelope.Kind.analysis, .wizard] {
            let current =
                kind == .analysis
                ? JSONSetting.dictionary(AnalysisRunSettings())
                : JSONSetting.dictionary(WizardOptions())
            for scope in AISettingsScope.allCases {
                var changed = current
                changed["instructions"] = .string("new")
                changed["aiInstructions"] = .string("new")
                changed["modelOverride"] = .string("new-model")
                changed["provider"] = .string("claude")
                let envelope = AISettingsEnvelope(
                    kind: kind, sourceName: "Test", scopes: [scope], settings: changed)
                let result = envelope.applying(
                    to: current, profile: "", videoPaths: [], runIDs: [], people: [], sceneIDs: [])
                let allowed = AISettingsEnvelope.keys(scope, kind: kind)
                for (key, value) in current where !allowed.contains(key) {
                    #expect(result.settings[key] == value)
                }
            }
        }
    }

    @Test("Missing sources are skipped and never widen an empty selection")
    func missingSources() throws {
        let original: [String: JSONSetting] = [
            "sourceProfile": .string("p"),
            "selectedRunIDs": .array([.number(1), .number(9)]),
            "sourceSceneIDs": .array([.number(8)]),
            "sourceVideoPaths": .array([.string("/gone.mp4")]),
            "sourcePeople": .array([.string("gone")]),
        ]
        let envelope = AISettingsEnvelope(
            kind: .wizard, sourceName: "Old", scopes: [.sources], settings: original)
        let result = envelope.applying(
            to: [:], profile: "p", videoPaths: [], runIDs: [1], people: [], sceneIDs: [])
        #expect(result.settings["selectedRunIDs"] == .array([.number(1)]))
        #expect(result.settings["sourceSceneIDs"] == .array([]))
        #expect(result.settings["sourcesRestricted"] == .bool(true))
        #expect(result.skipped.count == 4)
        let otherProfile = envelope.applying(
            to: [:], profile: "other", videoPaths: [], runIDs: [1, 9], people: [], sceneIDs: [8])
        #expect(otherProfile.settings["selectedRunIDs"] == .array([]))
    }

    @Test("A trim only applies to the original video")
    func trimIdentity() throws {
        let source = AnalysisRunSettings(trimRange: [10, 20], videoPath: "/a.mp4")
        let envelope = AISettingsEnvelope(
            kind: .analysis, sourceName: "A", scopes: [.options],
            settings: JSONSetting.dictionary(source)
        )
        let current = JSONSetting.dictionary(
            AnalysisRunSettings(trimRange: [2, 4], videoPath: "/b.mp4"))
        let result = envelope.applying(
            to: current, profile: "", videoPaths: [], runIDs: [], people: [], sceneIDs: [],
            sameVideo: "/b.mp4")
        #expect(result.settings["trimRange"] == current["trimRange"])
        #expect(result.settings["videoPath"] == .string("/b.mp4"))
        #expect(result.skipped == ["Trim range (different video)"])
    }

    @Test("Run snapshots and model details survive database reload")
    func persistedSnapshots() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let settings = AnalysisRunSettings(instructions: "captured", includeTranscript: true)
        let role = AIRole(
            role: "Tagging",
            provenance: AIProvenance(provider: "claude", model: "test", at: Date(), fellBack: true))
        let runID = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Captured", instructions: "captured",
            sampleInterval: 2, notesJSON: nil, tagRanges: [:], moments: [], analyzedTags: [],
            provider: "claude", model: "test", mode: "visual", settings: settings, roles: [role])
        let runs = try await temp.database.fetchAnalysisRuns()
        let run = try #require(runs.first { $0.id == runID })
        #expect(AISettingsJSON.decode(AnalysisRunSettings.self, run.settingsJSON) == settings)
        #expect(AISettingsJSON.decode([AIRole].self, run.modelsJSON) == [role])
        let wizard = WizardRunSettings(options: WizardOptions())
        let outputID = try await temp.database.insertGeneratedVideo(
            path: "/output.mp4", duration: 12, timelineJSON: "{}",
            wizardProvider: "claude", wizardModel: "test", settings: wizard, roles: [role])
        let outputs = try await temp.database.fetchGeneratedVideos()
        let output = try #require(outputs.first { $0.id == outputID })
        #expect(
            AISettingsJSON.decode(WizardRunSettings.self, output.settingsJSON)?.options.useMusic
                == true)
        #expect(AISettingsJSON.decode([AIRole].self, output.modelsJSON) == [role])
    }

    @Test("Legacy runs retain the not-recorded state")
    func legacyRows() async throws {
        let temp = try TempDatabase()
        _ = try await temp.seedVideo()
        let runs = try await temp.database.fetchAnalysisRuns()
        #expect(runs.first?.settingsJSON == nil)
        #expect(AIInfoEntry.notRecorded == "Settings not recorded for this run")
    }

    @Test("Model-only preference writes leave form options untouched")
    func preferenceIsolation() throws {
        let name = "AISettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("music", forKey: WizardDefaults.audioModeKey)
        defaults.set("none", forKey: WizardDefaults.textModeKey)
        defaults.set("keep", forKey: "wizard.aiInstructions")
        AISettingsPreferences.write(
            ["modelOverride": .string("chosen")], kind: .wizard, scopes: [.models],
            defaults: defaults)
        #expect(defaults.string(forKey: "wizard.modelOverride") == "chosen")
        #expect(defaults.string(forKey: WizardDefaults.audioModeKey) == "music")
        #expect(defaults.string(forKey: WizardDefaults.textModeKey) == "none")
        #expect(defaults.string(forKey: "wizard.aiInstructions") == "keep")
    }

    @Test("Named pasted state persists until Clear restores profile defaults")
    func clearPastedWizard() throws {
        let name = "AISettingsClear.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var options = WizardOptions()
        options.modelOverride = "copied"
        options.framingCamera = "copied-camera"
        options.selectedRunIDs = [12]
        options.sourcesRestricted = true
        options.renderSettings.preset = .landscape4K
        options.pacing.cadence = .twoSeconds
        let snapshot = JSONSetting.dictionary(options)
        AISettingsPreferences.write(
            snapshot, kind: .wizard, sourceName: "My output", defaults: defaults)
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(reopened.string(forKey: AISettingsPreferences.sourceNameKey) == "My output")
        #expect(reopened.string(forKey: AISettingsPreferences.snapshotKey) != nil)
        let saved = try #require(
            AISettingsJSON.decode(
                WizardOptions.self, reopened.string(forKey: AISettingsPreferences.snapshotKey)))
        #expect(saved.renderSettings == options.renderSettings)
        #expect(saved.pacing == options.pacing)
        let profile = BrandProfile(name: "target")
        #expect(
            AISettingsPreferences.wizard(defaults: reopened, profile: profile)["pacing"]
                == snapshot["pacing"])
        AISettingsPreferences.clearWizardPaste(defaults: reopened)
        #expect(reopened.string(forKey: AISettingsPreferences.snapshotKey) == nil)
        #expect(reopened.string(forKey: AISettingsPreferences.sourceNameKey) == nil)
        #expect(reopened.string(forKey: "wizard.modelOverride") == nil)
        #expect(reopened.string(forKey: "wizard.selectedRunIDs") == nil)
        #expect(!reopened.bool(forKey: "wizard.limitToSelection"))
        let restored = AISettingsPreferences.wizard(defaults: reopened, profile: profile)
        #expect(
            restored["renderSettings"]
                == .object(JSONSetting.dictionary(profile.defaultRenderSettings)))
        #expect(restored["pacing"] == .object(JSONSetting.dictionary(profile.defaultPacing)))
        #expect(restored["sourcesRestricted"] == .bool(false))
    }

    @Test("Large generated prompts persist bounded previews and never enter envelopes")
    func boundedPrompts() async throws {
        let capture = AIRunCapture()
        let longPrompt = String(repeating: "x", count: 100_000)
        capture.append(AIProvenance(provider: "claude", task: "analysis"), prompt: longPrompt)
        let preview = try #require(capture.prompts.values.first)
        #expect(preview.preview.count == 2_000)
        #expect(preview.characterCount == 100_000)
        #expect(preview.truncated)
        let settings = AnalysisRunSettings(
            instructions: "Keep all of my instructions", modelPrompts: capture.prompts)
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let id = try await temp.database.saveAnalysis(
            videoID: videoID, runName: "Bounded", instructions: settings.instructions,
            sampleInterval: 1, notesJSON: nil, tagRanges: [:], moments: [], analyzedTags: [],
            provider: "claude", model: nil, mode: "visual", settings: settings)
        let rows = try await temp.database.fetchAnalysisRuns()
        let json = try #require(rows.first { $0.id == id }?.settingsJSON)
        #expect(json.utf8.count < 10_000)
        #expect(AISettingsJSON.decode(AnalysisRunSettings.self, json) == settings)
        for kind in [AISettingsEnvelope.Kind.analysis, .wizard] {
            let envelope = AISettingsEnvelope(
                kind: kind, sourceName: "Bounded", scopes: [.prompts],
                settings: JSONSetting.dictionary(settings))
            #expect(envelope.settings["modelPrompts"] == nil)
        }
        let legacy = try #require(
            AISettingsJSON.decode(AIPromptPreview.self, AISettingsJSON.encode(longPrompt)))
        #expect(legacy.preview.count == 2_000)
        #expect(legacy.characterCount == 100_000)
    }

    @Test("Copying prompt text preserves an existing settings envelope")
    func copyTextPreservesEnvelope() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard board.setString("probe", forType: .string) else {
            print("Skipping pasteboard check: pasteboard service is unavailable")
            return
        }
        let envelope = AISettingsEnvelope(
            kind: .wizard, sourceName: "Saved settings", scopes: [.models],
            settings: ["modelOverride": .string("chosen")])
        AISettingsPasteboard.write(envelope, to: board)
        let original = try #require(board.data(forType: AISettingsPasteboard.type))
        AISettingsPasteboard.writeText("Prompt text", to: board)
        #expect(board.data(forType: AISettingsPasteboard.type) == original)
        #expect(board.string(forType: .string) == "Prompt text")
        #expect(AISettingsPasteboard.read(from: board)?.sourceName == "Saved settings")
    }

    @Test("Vendor logos only appear inside the AI popup")
    func logoCallSites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("ClipBuilder/Views")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: views.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            print(
                "Skipping logo call-site check: Views source directory is unavailable at \(views.path)"
            )
            return
        }
        let files = try #require(
            FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let file as URL in files
        where file.pathExtension == "swift" && file.lastPathComponent != "AIInfoSheet.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("ProviderLogo("))
            #expect(!source.contains("ProvenanceBadge("))
            #expect(!source.contains("ProvenanceRow("))
        }
    }
}
