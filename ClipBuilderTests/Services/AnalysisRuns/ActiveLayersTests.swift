import Foundation
import Testing
@testable import Clip_Builder

@Suite("Active analysis layers")
struct ActiveLayersTests {
    private func run(_ id: Int64, key: String, date: String = "2026-10-12 10:00:00", pipeline: Int? = nil) -> AnalysisRun {
        AnalysisRun(runKey: key, id: id, videoID: 1, name: key, instructions: "", hasTranscript: false,
                    sampleInterval: 1, createdAt: date, videoFilename: "fixture.mp4", videoPath: "/tmp/fixture.mp4",
                    sceneCount: 1, settingsJSON: AISettingsJSON.encode(AnalysisRunSettings(pipeline: pipeline)))
    }

    private func pass(_ key: String, status: AnalysisPassRecord.Status) -> AnalysisPassRecord {
        AnalysisPassRecord(videoID: 1, pass: .scenes, version: 1, status: status, startedAt: "1", runKey: key)
    }

    @Test func pinPresentWinsEvenWhenNewerRunExists() {
        let result = ActiveLayers.resolve(videoID: 1, pinnedRunKey: "a", runs: [run(1, key: "a"), run(2, key: "z")], passes: [])
        #expect(result.run?.id == 1 && result.isPinned && !result.missingPin)
    }

    @Test func missingPinFallsBackWithoutLosingMissingState() {
        let result = ActiveLayers.resolve(videoID: 1, pinnedRunKey: "remote", runs: [run(1, key: "a")], passes: [])
        #expect(result.run?.id == 1 && !result.isPinned && result.missingPin)
        let empty = ActiveLayers.resolve(videoID: 1, pinnedRunKey: "remote", runs: [], passes: [])
        #expect(empty.run == nil && empty.missingPin)
    }

    @Test func automaticUsesDateThenPortableKey() {
        let a = run(999, key: "a"), z = run(1, key: "z")
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: [a, z], passes: []).run?.id == 1)
        let newer = run(3, key: "b", date: "2026-10-13 10:00:00")
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: [z, newer], passes: []).run?.id == 3)
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: [], passes: []).run == nil)
    }

    @Test func completedScenesReceiptControlsEligibility() {
        let runs = [run(1, key: "a"), run(2, key: "z")]
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: runs,
            passes: [pass("a", status: .completed), pass("z", status: .running)]).run?.id == 1)
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: runs,
            passes: [pass("a", status: .failed), pass("z", status: .cancelled)]).run == nil)
    }

    @Test func legacyRunsWithoutScenePassesRemainEligible() {
        let legacy = run(1, key: "legacy")
        let unrelated = AnalysisPassRecord(videoID: 1, pass: .fightScore, version: 2, status: .failed, startedAt: "2")
        #expect(ActiveLayers.isCompleted(legacy, passes: [unrelated]))
        #expect(ActiveLayers.resolve(videoID: 1, pinnedRunKey: nil, runs: [legacy], passes: [unrelated]).run?.id == 1)
    }

    @Test func coverageUsesActivePipelineAndSeparatesUnfinishedWork() {
        var video = Fixtures.video()
        video.videoType = VideoType.fight.rawValue
        video.activeRunKey = "old"
        let old = run(1, key: "old", pipeline: 0)
        let new = run(2, key: "new", date: "2026-10-13 10:00:00", pipeline: AnalysisPipeline.visualPass)
        var inactiveQA = Fixtures.scene(id: 2)
        inactiveQA.runID = 2
        inactiveQA.tags = ["q&a"]
        let active = ActiveLayers.resolve(videoID: video.id, pinnedRunKey: video.activeRunKey, runs: [old, new], passes: [])
        let report = AnalysisCoverage.report(video: video, activeRun: active.run, scenes: [inactiveQA],
            transcriptCount: 0, passes: [pass("new", status: .running)], hasCheckpoint: true)
        #expect(report.latestPipeline == 0 && report.qaCount == 0)
        #expect(report.state == .outdated(stage: "Visual analysis") && report.unfinishedWork)
    }

    @Test func savedTakePrefersStoredInactiveSceneOverNewIdenticalRange() throws {
        let old = Fixtures.scene()
        var latest = old
        latest.id = 99
        latest.runID = 2
        latest.cropXFrac = 0.9
        var plan = Fixtures.plan()
        plan.clips[0].areaClips = [WizardPlanAreaClip(area: "Right", sceneID: old.id, start: 2, end: 6)]
        let saved = WizardSelectionRules.snapshot(plan, scenes: [old])
        let resolved = try #require(WizardSelectionRules.resolvedPlan(saved, scenes: [latest, old]))
        #expect(resolved.clips[0].sceneID == old.id)
        #expect(resolved.clips[0].areaClips[0].sceneID == old.id)
    }

    @Test func referenceIDsRecognizeBuilderAndLegacyOutputClips() throws {
        let document = Fixtures.timelineDocument()
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        #expect(SceneReferences.ids(in: json) == [1])
        #expect(SceneReferences.ids(in: #"[{"type":"clip","id":12},{"type":"text","id":99}]"#) == [12])
    }
}
