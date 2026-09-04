import Foundation
@testable import Clip_Builder

enum Fixtures {
    static func timelineClip(
        sceneID: Int64? = 1,
        sourceStart: Double = 2,
        duration: Double = 4,
        startTime: Double = 0,
        track: Int = 0,
        speed: Double? = nil
    ) -> TimelineClip {
        var clip = TimelineClip()
        clip.sceneID = sceneID
        clip.videoFile = "/tmp/fixture.mp4"
        clip.sourceStart = sourceStart
        clip.sourceEnd = sourceStart + duration * (speed ?? 1)
        clip.duration = duration
        clip.startTime = startTime
        clip.track = track
        clip.speed = speed
        clip.sceneFullDuration = duration * (speed ?? 1)
        return clip
    }

    static func timelineDocument(clips: [TimelineClip] = [timelineClip()]) -> TimelineDocument {
        var document = TimelineDocument()
        document.videoTrack = clips
        return document
    }

    static func scene(
        id: Int64 = 1,
        start: Double = 2,
        end: Double = 6,
        wide: Bool = true
    ) -> SceneRecord {
        SceneRecord(
            id: id, videoID: 1, runID: 1, startTime: start, endTime: end,
            originalStart: start, originalEnd: end, curated: false,
            curatedProvider: nil, curatedModel: nil, narrative: "Fixture scene",
            score: 8, excitement: 0.7, parentSceneID: nil, stackChoice: false,
            excluded: false, ignored: false, favorite: false, cropXFrac: nil,
            freeCropsJSON: nil, centerStagePathJSON: nil, tags: ["fixture"],
            gradeAverage: nil, gradeCount: 0, lastGrade: nil,
            videoPath: "/tmp/fixture.mp4", videoFilename: "fixture.mp4",
            videoDuration: 10, wide: wide
        )
    }

    static func video(id: Int64 = 1) -> VideoRecord {
        VideoRecord(
            id: id, hash: "fixture", filename: "fixture.mp4", path: "/tmp/fixture.mp4",
            duration: 10, width: 1920, height: 1080, wide: true,
            discoveredAt: nil, analyzedAt: nil, visualAnalyzedAt: nil,
            speechAnalyzedAt: nil, visualAnalyzerProvider: nil, visualAnalyzerModel: nil,
            speechAnalyzerProvider: nil, speechAnalyzerModel: nil, peopleDetectedAt: nil
        )
    }

    static func brand(name: String = "Test") -> BrandProfile {
        BrandProfile(name: name)
    }

    static func planClip(sceneID: Int64 = 1, start: Double = 2, end: Double = 6) -> WizardPlanClip {
        WizardPlanClip(sceneID: sceneID, start: start, end: end)
    }

    static func plan(
        clips: [WizardPlanClip] = [planClip()],
        transitions: [String] = [],
        targetDuration: Double = 4
    ) -> WizardPlan {
        WizardPlan(targetDuration: targetDuration, rationale: "fixture", musicName: nil,
                   musicVolume: 3, clips: clips, transitions: transitions)
    }

    static func generatedVideo(id: Int64, batchID: String? = nil) -> GeneratedVideoRecord {
        GeneratedVideoRecord(id: id, path: "/tmp/reel-\(id).mp4", duration: 20,
                             timelineJSON: "{}", caption: "", batchID: batchID)
    }

    /// An empty library snapshot with the given rows, for AppStore tests.
    static func snapshot(videos: [VideoRecord] = [], scenes: [SceneRecord] = []) -> LibrarySnapshot {
        LibrarySnapshot(videos: videos, scenes: scenes, analysisRuns: [], people: [],
                        generatedVideos: [], feedback: [], lessons: [],
                        fightResearch: [], fightEvents: [])
    }
}
