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
            originalStart: start, originalEnd: end,
            favoriteProvider: nil, favoriteModel: nil, narrative: "Fixture scene",
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

    /// Two videos with the same mistaken identity in every video-owned table.
    static func personCorrection(in temp: TempDatabase) async throws
        -> (from: PersonRecord, to: PersonRecord, video: VideoRecord, otherVideo: VideoRecord) {
        let from = try await temp.database.createPerson(name: "Original Person")
        let to = try await temp.database.createPerson(name: "Other Person")
        let firstID = try await temp.seedVideo(sceneCount: 2)
        let secondID = try await temp.seedVideo(sceneCount: 2)
        let raw = try SQLiteConnection(path: temp.path.path)
        for id in [firstID, secondID] {
            try raw.execute("""
                INSERT INTO scene_tags (scene_id, tag) SELECT id, ? FROM scenes WHERE video_id = ?
                """, [.text(from.tag), .integer(id)])
            try raw.execute("""
                INSERT INTO speaker_turns (video_id, start_time, end_time, cluster, person_key)
                VALUES (?, 0, 4, 0, ?)
                """, [.integer(id), .text(from.key)])
            try raw.execute("""
                INSERT INTO transcripts (video_id, start_time, end_time, text, speaker_key)
                VALUES (?, 0, 4, 'A hand-assigned line', ?)
                """, [.integer(id), .text(from.key)])
            try raw.execute("""
                INSERT INTO topic_ranges (video_id, title, start_time, end_time, speaker_keys_json)
                VALUES (?, 'Question', 0, 4, ?)
                """, [.integer(id), .text(String(decoding: try JSONEncoder().encode([from.key, to.key]), as: UTF8.self))])
            try raw.execute("""
                INSERT INTO voice_profiles (video_id, person_key, vector_json, windows, correction_windows)
                VALUES (?, ?, '[1,0]', 12, 2)
                """, [.integer(id), .text(from.key)])
            try raw.execute("""
                INSERT INTO person_markers (video_id, at_time, x, y, width, height, person_id)
                VALUES (?, 2, 0.1, 0.2, 0.3, 0.4, ?)
                """, [.integer(id), .integer(from.id)])
            try raw.execute("""
                INSERT INTO video_people (video_id, person_id, portrait_at, portrait_json, ranges_json)
                VALUES (?, ?, 2, '{"x":0.1,"y":0.2,"w":0.3,"h":0.4}',
                    '[{"start":8,"end":12},{"start":0,"end":4}]')
                """, [.integer(id), .integer(from.id)])
        }
        try raw.execute("INSERT INTO person_tag_fields (person_key, field, value) VALUES (?, 'role', 'Host')",
                        [.text(from.key)])
        var first = video(id: firstID), second = video(id: secondID)
        first.path = temp.directory.url.appendingPathComponent("fixture.mp4").path
        second.path = first.path
        return (from, to, first, second)
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
