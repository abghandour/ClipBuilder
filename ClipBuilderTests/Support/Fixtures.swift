import Foundation
@testable import Clip_Builder

enum Fixtures {
    /// Stored video 2 turn timings, Peace Grappler, October 31, 2026.
    /// Both voices were incorrectly named Aljo before cluster-level naming.
    static var aljoInterviewTurns: [SpeakerTurn] {
        let spans: [(Double, Double, Int, PodcastSpeakerSide)] = [
            (0.18, 23.82, 0, .left), (23.82, 25.14, 1, .right),
            (25.14, 32.04, 0, .left), (32.04, 33.18, 1, .right),
            (33.18, 49.2, 0, .left), (49.8, 61.62, 1, .left),
            (62.82, 101.16, 0, .right), (101.94, 122.76, 0, .left),
            (122.76, 123.06, 1, .right), (123.48, 124.38, 0, .left),
            (125.88, 143.1, 0, .left), (144.3, 205.38, 0, .left),
            (205.38, 205.86, 1, .right), (206.16, 210.36, 0, .left),
            (210.78, 220.14, 1, .left), (221.28, 222.36, 1, .left),
            (222.36, 223.08, 0, .left), (223.32, 223.74, 1, .right),
            (223.86, 225, 0, .left),
        ]
        let evidence: [(Double, PodcastSpeakerSide, Double)] = [
            (0.529549944798014, .right, 0.500061979916723), (0.528516181550053, .right, 1),
            (0.51430886672736, .unknown, 0), (0.457255552034269, .right, 1),
            (0.520007262264065, .left, 1), (0.592708919828924, .left, 0.745263556995877),
            (0.544290301643915, .right, 1), (0.51852837805968, .left, 0.534602166799042),
            (0.512287921008387, .right, 1), (0.511111284674503, .left, 0.51074625280976),
            (0.554892150425693, .left, 0.534512372325638), (0.527476490366204, .right, 0.507994239842946),
            (0.559529099056049, .right, 1), (0.485541094690518, .unknown, 0),
            (0.620372525614747, .left, 0.702697710040577), (0.582318937765394, .left, 1),
            (0.508226602551985, .left, 1), (0.562192151568604, .unknown, 0),
            (0.466511292347649, .left, 1),
        ]
        return spans.enumerated().map { index, span in
            let signal = evidence[index]
            return SpeakerTurn(videoID: 2, start: span.0, end: span.1, cluster: span.2,
                               confidence: signal.0, pictureSide: signal.1, pictureConfidence: signal.2,
                               resolvedSide: span.3, personKey: "aljo")
        }
    }

    static var aljoInterviewRoster: [VideoPersonRecord] {
        [VideoPersonRecord(videoID: 2, personID: 1, key: "aljo", name: "Aljo", descriptor: "",
                           portraitAt: 0, portraitBox: .init(x: 0.28, y: 0, w: 0.44, h: 1), ranges: [0...225.06]),
         VideoPersonRecord(videoID: 2, personID: 2, key: "ariel", name: "Ariel", descriptor: "",
                           portraitAt: 213, portraitBox: .init(x: 0.13, y: 0, w: 0.36, h: 1), ranges: [213...225.06])]
    }

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
