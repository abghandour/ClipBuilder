import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis comparison memo")
nonisolated struct AnalysisComparisonMemoTests {
    @Test func planKeyIgnoresUnrelatedDefaultsAndTracksCapturedSettings() throws {
        let suite = "AnalysisComparisonMemoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func key() -> String {
            AnalysisComparisonMemo.planKey(AnalysisRequest.capturePlan(defaults: defaults, singleVideo: true,
                provider: nil, model: nil, includeFightScoring: true))
        }
        let original = key()
        defaults.set(320, forKey: "pane.outputs.folders")
        defaults.set("saved-tab", forKey: "textLooks.tab")
        #expect(key() == original)
        defaults.set("Look for kicks | then \"throws\"\n", forKey: "analysis.instructions")
        let instructions = key()
        #expect(instructions != original)
        #expect(key() == instructions)
        defaults.set(true, forKey: "analysis.includeTranscript")
        #expect(key() != instructions)
    }

    @Test func everyPlanFieldContributesToTheKey() throws {
        let plan = AnalysisCheckpoint.Plan()
        let original = AnalysisComparisonMemo.planKey(plan)
        let changes: [(inout AnalysisCheckpoint.Plan) -> Void] = [
            { $0.instructions = "Look for kicks" },
            { $0.sampleInterval = 2 },
            { $0.detectPeople = false },
            { $0.autoZoomUnframed = true },
            { $0.breakdownTags = ["takedown"] },
            { $0.trimRange = [2, 12] },
            { $0.requiredPeopleKeys = ["speaker"] },
            { $0.pastedNotes = [.init(at: 3, note: "Round start")] },
            { $0.smartSampling = false },
            { $0.includeTranscript = true },
            { $0.includeFightScoring = false },
            { $0.provider = "claude" },
            { $0.model = "model" }
        ]
        for change in changes {
            var changed = plan
            change(&changed)
            let key = AnalysisComparisonMemo.planKey(changed)
            #expect(key != original)
            #expect(key == AnalysisComparisonMemo.planKey(changed))
            #expect(try JSONDecoder().decode(AnalysisCheckpoint.Plan.self, from: Data(key.utf8)) == changed)
        }
    }

    @Test func memoKeyTracksEachInputAndReusesUnchangedVideos() {
        let original = AnalysisComparisonMemo.Key(videoID: 7, planKey: "plan", videoHash: "source",
            transcriptCountsVersion: 3, videoPeopleVersion: 4)
        let changes: [(inout AnalysisComparisonMemo.Key) -> Void] = [
            { $0.videoID = 8 },
            { $0.planKey = "changed plan" },
            { $0.videoHash = "replacement source" },
            { $0.transcriptCountsVersion += 1 },
            { $0.videoPeopleVersion += 1 }
        ]
        let memo = [original: "cached"]
        let unchanged = AnalysisComparisonMemo.Key(videoID: 7, planKey: "plan", videoHash: "source",
            transcriptCountsVersion: 3, videoPeopleVersion: 4)
        #expect(memo[unchanged] == "cached")
        for change in changes {
            var changed = original
            change(&changed)
            #expect(memo[changed] == nil)
        }
    }
}
