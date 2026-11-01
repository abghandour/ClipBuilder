import Foundation
import Testing
@testable import Clip_Builder

@Suite("Sources assistant")
struct SourcesAssistantTests {
    private func context(_ edit: (inout SourcesAssistant.Snapshot) -> Void = { _ in }) -> AssistantContext {
        var s = SourcesAssistant.Snapshot()
        s.sourceCount = 4
        s.presentCount = 4
        edit(&s)
        return SourcesAssistant.context(s)
    }

    private func ids(_ context: AssistantContext) -> [String] {
        SourcesAssistant().suggestions(for: context).map(\.id)
    }

    @Test func quietWhenEverythingIsDone() {
        #expect(ids(context()).isEmpty)
    }

    @Test func noSourcesSuggestsAddingOnly() {
        let rows = SourcesAssistant().suggestions(for: context { $0.sourceCount = 0; $0.cameraNamed = 2 })
        #expect(rows.map(\.id) == ["sources.add.none"])
        #expect(rows.first?.actionID == "sources.add")
    }

    @Test func missingScenesSuggestsAnalyze() {
        let rows = SourcesAssistant().suggestions(for: context { $0.missingSteps = ["scenes": 3]; $0.missingFiles = 3 })
        #expect(rows.map(\.id) == ["sources.analyze.missing"])
        #expect(rows.first?.reason == "3 sources have no scenes yet")
        #expect(rows.first?.actionID == "sources.analyze.missing")
    }

    @Test func missingTranscriptSuggestsTranscribe() {
        #expect(ids(context { $0.missingSteps = ["transcript": 1] }) == ["sources.transcribe.missing"])
        #expect(!ids(context { $0.missingSteps = ["people": 2] }).contains("sources.transcribe.missing"))
    }

    @Test func unnamedSpeakersSuggestsNaming() {
        let rows = SourcesAssistant().suggestions(for: context { $0.missingSteps = ["speakerNames": 2] })
        #expect(rows.map(\.id) == ["sources.speakers.unnamed"])
        #expect(rows.first?.actionID == "sources.speakers.name")
    }

    @Test func sameLengthSourcesSuggestDuplicateScan() {
        #expect(ids(context { $0.durationTwins = 2 }) == ["sources.duplicates.scan"])
        #expect(ids(context { $0.durationTwins = 1 }).isEmpty)
    }

    @Test func cameraNamesSuggestFileNames() {
        let rows = SourcesAssistant().suggestions(for: context { $0.cameraNamed = 1 })
        #expect(rows.map(\.id) == ["sources.names.messy"])
        #expect(rows.first?.actionID == "sources.names.suggest")
    }

    @Test func durationTwinsWithinOneSecond() {
        #expect(SourcesAssistant.durationTwins([60, 60.8, 120, 300]) == 2)
        #expect(SourcesAssistant.durationTwins([60, 62, 120]) == 0)
        #expect(SourcesAssistant.durationTwins([10, 10.5, 11.2]) == 3)
        #expect(SourcesAssistant.durationTwins([0, 0]) == 0)
    }

    @Test func cameraNames() {
        for name in ["IMG_1234.MOV", "C0001.mp4", "GX010123.MP4", "DSCF4410.mov", "PXL_20260101_123456.mp4",
                     "20261005_183000.mp4", "Screen Recording 2026-10-01 at 10.00.mov", "MVI-0042.mov"] {
            #expect(SourcesAssistant.isCameraName(name), "\(name)")
        }
        for name in ["UFC 300 Pereira vs Hill.mov", "Interview Jon.mp4", "Clip of the week.mov", "image.png"] {
            #expect(!SourcesAssistant.isCameraName(name), "\(name)")
        }
    }

    @Test func summaryLine() {
        let line = context { $0.missingFiles = 2; $0.selectedCount = 1; $0.selected = ["a.mov"] }.summaryLine
        #expect(line == "Sources · 4 sources · 2 need analysis · 1 selected")
    }

    @Test func routing() {
        #expect(SourcesAssistant.route("Analyze everything that is missing") == "sources.analyze.missing")
        #expect(SourcesAssistant.route("Transcribe the sources without a transcript") == "sources.transcribe.missing")
        #expect(SourcesAssistant.route("Suggest better file names for the selected videos") == "sources.names.suggest")
        #expect(SourcesAssistant.route("find duplicates") == "sources.duplicates.scan")
        #expect(SourcesAssistant.route("name the speakers") == "sources.speakers.name")
        #expect(SourcesAssistant.route("make a reel from these") == "sources.wizard.open")
        #expect(SourcesAssistant.route("research this fight") == "sources.fight.research")
        #expect(SourcesAssistant.route("") == nil)
        #expect(SourcesAssistant.route("what's the weather") == nil)
    }

    @Test func missingStepsBusyCoversEveryRunningStep() {
        func busy(batch: Bool = false, analyzing: Bool = false, people: Bool = false, transcribing: Bool = false,
                  scoring: Bool = false, mapping: Bool = false) -> Bool {
            AnalysisSteps.batchBusy(batchRunning: batch, analyzing: analyzing, detectingPeople: people,
                                    transcribing: transcribing, fightScoring: scoring, mappingSpeakers: mapping)
        }
        #expect(!busy())
        #expect(busy(batch: true))
        #expect(busy(analyzing: true))
        #expect(busy(people: true))
        #expect(busy(transcribing: true))
        #expect(busy(scoring: true))
        #expect(busy(mapping: true))
    }

    @MainActor
    @Test func analyzeMissingWaitsForPeopleDetection() throws {
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "SourcesAssistantTests")
        let store = AppStore(settings: settings, profiles: [profile], active: profile, ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        let analyze = try #require(SourcesAssistant().actions(store: store).first { $0.id == "sources.analyze.missing" })
        #expect(analyze.isAvailable(store))
        store.isDetectingPeople = true
        #expect(!analyze.isAvailable(store))
        #expect(store.isMissingStepsBatchBusy)
        store.isDetectingPeople = false
        store.transcribingVideoIDs = [3]
        #expect(!analyze.isAvailable(store))
    }
}
