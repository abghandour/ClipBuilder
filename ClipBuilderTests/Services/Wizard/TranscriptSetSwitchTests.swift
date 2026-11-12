import Foundation
import Testing
@testable import Clip_Builder

@Suite("Transcript set switch")
struct TranscriptSetSwitchTests {
    private func request(_ key: String) -> String { #"{"transcriptKey":"\#(key)"}"# }

    @Test func theNewestBatchBuiltFromTheSetBecomesActive() {
        // Run 3 is older than run 1 but was pulled later, so its row id is higher.
        // Run 6 transcribed the video itself: its request names no set, its settings do.
        let runs: [(id: Int64, runKey: String?, requestJSON: String?, settingsJSON: String?, createdAt: String?)] = [
            (1, "r1", request("a"), nil, "2026-11-05 10:00:00"), (2, "r2", request("b"), nil, "2026-11-06 10:00:00"),
            (3, "r3", request("a"), nil, "2026-11-01 10:00:00"), (4, nil, request("a"), nil, "2026-11-09 10:00:00"),
            (5, "r5", nil, nil, "2026-11-10 10:00:00"),
            (6, "r6", "{}", #"{"transcriptionKey":"d"}"#, "2026-10-01 10:00:00"),
        ]
        #expect(TranscriptSetSwitch.runKey(for: "d", runs: runs, activeRunID: 2) == "r6")
        #expect(TranscriptSetSwitch.runKey(for: "a", runs: runs, activeRunID: 2) == "r1")
        #expect(TranscriptSetSwitch.runKey(for: "a", runs: runs, activeRunID: 3) == nil, "already on a batch of that set")
        #expect(TranscriptSetSwitch.runKey(for: "c", runs: runs, activeRunID: 2) == nil, "no batch was built from it")
    }

    @Test func aHighlightsBatchIsOfferedOnlyUnderItsSet() throws {
        let suite = "TranscriptSetSwitchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func batch(_ set: String, project: Int64 = 1) -> String? {
            MiniWizardMemory.highlightBatch(profileName: "P", projectID: project, videoID: 2, length: .thirty,
                                            setKey: set, defaults: defaults)
        }
        // From before sets were recorded, in two projects: offered under any set.
        for project in [Int64(1), 7] {
            defaults.set("old-\(project)", forKey: MiniWizardMemory.batchKey(profileName: "P", projectID: project,
                                                                              videoID: 2, kind: .highlights, length: .thirty))
        }
        #expect(batch("a") == "old-1" && batch("b") == "old-1")
        // Leaving set a: every project's unrecorded batch was found on it.
        MiniWizardMemory.stampLegacyHighlightBatches(profileName: "P", videoID: 2, setKey: "a", defaults: defaults)
        #expect(batch("a") == "old-1" && batch("b") == nil)
        #expect(batch("a", project: 7) == "old-7" && batch("b", project: 7) == nil)
        MiniWizardMemory.rememberHighlightBatch("new", profileName: "P", projectID: 1, videoID: 2, length: .thirty,
                                                setKey: "b", defaults: defaults)
        #expect(batch("b") == "new" && batch("a") == "old-1")
    }

    @Test func storedDatesReadShort() {
        #expect(TranscriptSetSwitch.date("2026-11-10T05:03:24.134") == "Nov 10, 05:03")
        #expect(TranscriptSetSwitch.date("whenever") == "whenever")
    }
}

extension TranscriptSetSwitchTests {
    @Test func aHistoryEntryNamesItsTranscriptWhenItRecordedOne() {
        var record = WizardHighlightRecord(id: 1, projectID: 1, flow: "express")
        #expect(TranscriptSetSwitch.transcriptKey(of: record) == nil)
        record.settingsJSON = #"{"options":{},"length":"auto"}"#
        #expect(TranscriptSetSwitch.transcriptKey(of: record) == nil, "an entry from before sets were recorded")
        record.settingsJSON = #"{"options":{},"transcriptKey":"a"}"#
        #expect(TranscriptSetSwitch.transcriptKey(of: record) == "a")
    }
}
