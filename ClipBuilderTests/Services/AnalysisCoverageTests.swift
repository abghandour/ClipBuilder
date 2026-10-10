import Foundation
import Testing
@testable import Clip_Builder

@Suite("Analysis coverage")
struct AnalysisCoverageTests {
    private func video(_ type: VideoType?, duration: Double = 120) -> VideoRecord {
        var video = Fixtures.video()
        video.videoType = type?.rawValue
        video.duration = duration
        return video
    }

    private func run(id: Int64 = 1, videoID: Int64 = 1, pipeline: Int? = nil,
                     createdAt: String = "2026-10-09 12:00:00") -> AnalysisRun {
        AnalysisRun(id: id, videoID: videoID, name: "Coverage", instructions: "",
                    provider: nil, model: nil, hasTranscript: true, sampleInterval: 0,
                    notesJSON: nil, createdAt: createdAt, videoFilename: "fixture.mp4",
                    videoPath: "/tmp/fixture.mp4", sceneCount: 0,
                    settingsJSON: AISettingsJSON.encode(AnalysisRunSettings(pipeline: pipeline)))
    }

    private func qa(id: Int64 = 1, ignored: Bool = false, excluded: Bool = false) -> SceneRecord {
        var scene = Fixtures.scene(id: id)
        scene.tags = ["q&a"]
        scene.ignored = ignored
        scene.excluded = excluded
        return scene
    }

    @Test("No run takes priority over type and exchange coverage")
    func noRun() {
        for type in [nil, VideoType.interview, .podcast, .fight] {
            let empty = AnalysisCoverage.report(video: video(type), runs: [], scenes: [], transcriptCount: 0)
            #expect(empty.state == .needsAnalysis)
            #expect(!empty.hasRun && !empty.hasTranscript && empty.latestPipeline == nil)
            let transcript = AnalysisCoverage.report(video: video(type), runs: [], scenes: [qa()], transcriptCount: 2)
            #expect(transcript.state == .transcriptOnly)
            #expect(transcript.hasTranscript && !transcript.hasRun && transcript.qaCount == 1)
        }
    }

    @Test("Untyped requires a run, no exchanges and strictly less than 300 seconds")
    func untyped() {
        #expect(AnalysisCoverage.report(video: video(nil, duration: 299.9), runs: [run()],
                                        scenes: [], transcriptCount: 1).state == .untyped)
        for duration in [300.0, 600] {
            #expect(AnalysisCoverage.report(video: video(nil, duration: duration), runs: [run()],
                                            scenes: [], transcriptCount: 1).state == .outdated(stage: "Visual analysis"))
        }
        #expect(AnalysisCoverage.report(video: video(nil), runs: [run(pipeline: AnalysisPipeline.visualPass)],
                                        scenes: [qa()], transcriptCount: 1).state == .upToDate)
    }

    @Test("Podcast and Interview share exchange coverage and current zero-result messaging",
          arguments: [VideoType.podcast, .interview])
    func talkingFootage(type: VideoType) {
        let old = AnalysisCoverage.report(video: video(type), runs: [run()], scenes: [], transcriptCount: 1)
        #expect(old.state == .missingExchanges)
        #expect(old.latestPipeline == nil)
        #expect(AnalysisCoverage.message(for: old, type: type).contains("Exchanges were never grouped"))
        let empty = AnalysisCoverage.report(video: video(type), runs: [run(pipeline: AnalysisPipeline.podcastPass)],
                                            scenes: [qa(ignored: true)], transcriptCount: 1)
        #expect(empty.state == .missingExchanges && empty.qaCount == 0)
        #expect(AnalysisCoverage.message(for: empty, type: type).contains("No exchanges were found"))
        let current = AnalysisCoverage.report(video: video(type), runs: [run(pipeline: AnalysisPipeline.podcastPass)],
                                              scenes: [qa(), qa(id: 2, ignored: true), qa(id: 3, excluded: true)],
                                              transcriptCount: 1)
        #expect(current.state == .upToDate && current.qaCount == 2)
        #expect(SceneIndex([qa(), qa(id: 2, ignored: true), qa(id: 3, excluded: true)]).qaCountsByVideo[1] == 2)
    }

    @Test("Legacy nil pipelines count as zero after the missing-exchanges rule")
    func legacyAndCurrent() {
        for pipeline in [nil, 0] as [Int?] {
            #expect(AnalysisCoverage.report(video: video(.interview), runs: [run(pipeline: pipeline)],
                                            scenes: [qa()], transcriptCount: 1).state == .outdated(stage: "Podcast exchanges"))
            #expect(AnalysisCoverage.report(video: video(.fight), runs: [run(pipeline: pipeline)],
                                            scenes: [], transcriptCount: 0).state == .outdated(stage: "Visual analysis"))
        }
        for pipeline in [AnalysisPipeline.visualPass, AnalysisPipeline.visualPass + 1] {
            let report = AnalysisCoverage.report(video: video(.fight), runs: [run(pipeline: pipeline)],
                                                 scenes: [], transcriptCount: 0)
            #expect(report.state == .upToDate && !report.hasTranscript && report.hasRun)
        }
        var legacy = run()
        legacy.settingsJSON = nil
        #expect(AnalysisCoverage.report(video: video(.fight), runs: [legacy], scenes: [],
                                        transcriptCount: 0).state == .outdated(stage: "Visual analysis"))
    }

    @Test("Latest run wins by date then id, and other videos cannot contribute coverage")
    func latestAndScope() {
        let older = run(id: 10, pipeline: AnalysisPipeline.podcastPass, createdAt: "2026-10-08 12:00:00")
        let latest = run(id: 2)
        let foreign = run(id: 99, videoID: 2, pipeline: AnalysisPipeline.podcastPass)
        var foreignQA = qa()
        foreignQA.videoID = 2
        let report = AnalysisCoverage.report(video: video(.interview), runs: [latest, foreign, older],
                                             scenes: [foreignQA], transcriptCount: 0)
        #expect(report.state == .missingExchanges && report.latestPipeline == nil && report.qaCount == 0)
        let tied = AnalysisCoverage.report(video: video(.fight), runs: [run(id: 2), run(id: 1, pipeline: 1)],
                                           scenes: [], transcriptCount: 0)
        #expect(tied.latestPipeline == nil)
        let unrelated = AnalysisCoverage.report(video: video(.interview), runs: [foreign], scenes: [], transcriptCount: 1)
        #expect(unrelated.state == .transcriptOnly)
    }

    @Test("Library snapshots count transcripts even when no analysis run exists")
    func transcriptOnlySnapshot() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.database.registerVideo(
            hash: "transcript-only", filename: "transcript.mp4",
            path: temp.directory.url.appendingPathComponent("transcript.mp4").path,
            duration: 10, width: 1920, height: 1080, wide: true)
        try await temp.database.replaceTranscripts(
            videoID: videoID, language: "en", isTranslation: false,
            segments: [.init(start: 0, end: 2, text: "Question?", words: nil),
                       .init(start: 2, end: 5, text: "Answer.", words: nil)],
            provider: "fixture", model: nil)
        let snapshot = try await temp.database.fetchLibrarySnapshot()
        let video = try #require(snapshot.videos.first { $0.id == videoID })
        #expect(snapshot.transcriptCounts[videoID] == 2)
        #expect(AnalysisCoverage.report(video: video, runs: snapshot.analysisRuns, scenes: snapshot.scenes,
                                        transcriptCount: snapshot.transcriptCounts[videoID] ?? 0).state == .transcriptOnly)
    }

    @Test("Every state supplies the intended visible action and a message")
    func actions() {
        let cases: [(AnalysisCoverage.State, AnalysisCoverage.Action?)] = [
            (.upToDate, nil), (.needsAnalysis, .analyze), (.transcriptOnly, .analyze),
            (.missingExchanges, .runExchanges), (.untyped, .setType),
            (.outdated(stage: "Podcast exchanges"), .runExchanges),
            (.outdated(stage: "Visual analysis"), .analyze),
        ]
        for (state, action) in cases {
            #expect(AnalysisCoverage.action(for: state) == action)
            #expect(!AnalysisCoverage.message(for: state, type: .interview).isEmpty)
        }
        #expect(AnalysisCoverage.message(for: .untyped, type: nil).contains("Podcast or Interview"))
    }
}
