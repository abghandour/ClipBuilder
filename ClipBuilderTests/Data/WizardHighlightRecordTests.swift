import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard highlight record")
struct WizardHighlightRecordTests {
    @Test func recordRoundTripsAndDecodesWithMissingKeys() throws {
        let record = WizardHighlightRecord(id: 4, projectID: 2, flow: WizardHighlightFlow.expressQA.rawValue,
            batchID: "b", parentID: 3, selectionID: 7, takeID: 8, generatedVideoID: 9, videoHashes: ["h"],
            footage: [HighlightFootageRef(sceneID: 1, videoHash: "h", start: 0, end: 4)],
            settingsJSON: "{}", planJSON: nil, provenanceJSON: nil, note: "n", author: "A", createdAt: "2026-11-01 10:00:00")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(WizardHighlightRecord.self, from: data) == record)

        let sparse = try JSONDecoder().decode(WizardHighlightRecord.self,
            from: Data(#"{"id":1,"projectID":2,"flow":"someFutureFlow"}"#.utf8))
        #expect(sparse.highlightFlow == nil, "a flow from a newer build keeps its string")
        #expect(sparse.flow == "someFutureFlow")
        #expect(sparse.footage == nil && sparse.videoHashes == nil && sparse.settings == nil && sparse.plan == nil)
        #expect(sparse.provenance.isEmpty)
    }

    @Test func settingsNeedOnlyOptions() throws {
        let settings = try JSONDecoder().decode(WizardHighlightSettings.self, from: Data(#"{"options":{}}"#.utf8))
        #expect(settings.mini == nil && settings.length == nil && settings.outputMode == nil)
        #expect(settings.picks == nil && settings.qaKept == nil && settings.aiRouting == nil)

        var options = WizardOptions()
        options.targetDurationSeconds = 15
        let full = WizardHighlightSettings(options: options, mini: MiniWizardSettings(), length: "15",
            outputMode: MiniWizardFlow.OutputMode.oneReel.rawValue,
            picks: [HighlightPickSnapshot(kind: .fight, videoHash: "h", start: 1, end: 3, position: 0, eventTimes: [1.5])],
            qaKept: [HighlightFootageRef(sceneID: 5, videoHash: "h", start: 0, end: 9)],
            aiRouting: HighlightAIRouting(tasks: ["wizard": "claude"], taskModels: nil), sourceProfile: "P")
        let decoded = try JSONDecoder().decode(WizardHighlightSettings.self, from: JSONEncoder().encode(full))
        #expect(decoded.options.targetDurationSeconds == 15)
        #expect(decoded.mini == MiniWizardSettings())
        #expect(decoded.picks == full.picks && decoded.qaKept == full.qaKept && decoded.aiRouting == full.aiRouting)
        #expect(decoded.length == "15" && decoded.outputMode == "oneReel" && decoded.sourceProfile == "P")
    }

    @Test func flowsFollowFootageKinds() {
        for kind in MiniWizardFlow.FootageKind.allCases {
            let flow = WizardHighlightFlow(footageKind: kind)
            #expect(flow.isExpress && flow.footageKind == kind)
        }
        #expect(!WizardHighlightFlow.fullAutomatic.isExpress && WizardHighlightFlow.fullSelection.footageKind == nil)
    }
}
