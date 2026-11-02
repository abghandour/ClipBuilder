import Foundation
import Testing
@testable import Clip_Builder

struct HomeVideoFilterTests {
    private func candidate(_ id: Int64, _ name: String, scenes: Bool = false,
                           transcript: Bool = false, projects: [Int64] = []) -> HomeVideoCandidate {
        var video = Fixtures.video(id: id)
        video.filename = name
        return HomeVideoCandidate(video: video, hasScenes: scenes, hasTranscript: transcript,
                                  projectIDs: projects, projectNames: [])
    }

    @Test func filtersUseProfileFactsAndPreserveOrder() {
        let candidates = [candidate(1, "Interview.mov", scenes: true, projects: [10, 20]),
                          candidate(2, "B-roll.mp4", transcript: true),
                          candidate(3, "Final.mov", scenes: true, transcript: true, projects: [20]),
                          candidate(4, "Untouched.mov")]
        #expect(HomeVideoFilter.apply(.all, search: "", to: candidates).map(\.id) == [1, 2, 3, 4])
        #expect(HomeVideoFilter.apply(.analyzed, search: "", to: candidates).map(\.id) == [1, 3])
        #expect(HomeVideoFilter.apply(.transcribed, search: "", to: candidates).map(\.id) == [2, 3])
        #expect(HomeVideoFilter.apply(.unassigned, search: "", to: candidates).map(\.id) == [2, 4])
    }

    @Test func searchCombinesWithFilterAndTrimsWhitespace() {
        let candidates = [candidate(1, "Café Interview.MOV", scenes: true),
                          candidate(2, "Interview.mp4", transcript: true)]
        #expect(HomeVideoFilter.apply(.all, search: "  CAFÉ  ", to: candidates).map(\.id) == [1])
        #expect(HomeVideoFilter.apply(.transcribed, search: "interview", to: candidates).map(\.id) == [2])
        #expect(HomeVideoFilter.apply(.all, search: " \n ", to: candidates).map(\.id) == [1, 2])
        #expect(HomeVideoFilter.apply(.analyzed, search: "missing", to: candidates).isEmpty)
        #expect(HomeVideoFilter.apply(.all, search: "", to: []).isEmpty)
    }

    @Test func batchedQueriesIncludeSharedAndUnassignedVideos() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        try await db.ensureDefaultProject(profileName: "Test", legacyTimelineJSON: nil)
        let home = try #require(try await db.homeProjectID())
        let shared = try await temp.seedVideo(sceneCount: 2)
        let unassigned = try await temp.seedVideo(sceneCount: 0)
        let untouched = try await temp.seedVideo(sceneCount: 0)
        let hidden = try await temp.seedVideo(sceneCount: 0)
        try await db.setVideosHidden([hidden], true)
        let alpha = try await db.createProject(profileName: "Test", name: "Alpha", videoIDs: [shared])
        let beta = try await db.createProject(profileName: "Test", name: "Beta", videoIDs: [shared])
        let empty = try await db.createProject(profileName: "Test", name: "Empty")
        try await db.setProjectArchived(id: beta, archived: true)
        try await db.replaceTranscripts(videoID: unassigned, transcriptionKey: "test", language: "en", isTranslation: false,
                                        segments: [TranscriptSegment(start: 0, end: 1, text: "Hello", words: nil)],
                                        provider: "test", model: "test")

        #expect(try await db.countVideosNotInProject(alpha) == 2)
        #expect(try await db.countVideosNotInProject(empty) == 3)
        #expect(try await db.countVideosNotInProject(home) == 0)
        #expect(try await db.fetchVideosNotInProject(home).isEmpty)
        #expect(Set(try await db.fetchVideosNotInProject(alpha).map(\.id)) == [unassigned, untouched])

        let names = try await db.projectNames(forVideos: [shared, unassigned, untouched])
        #expect(names[shared] == ["Alpha", "Beta"])
        #expect(names[unassigned, default: []].isEmpty)
        #expect(names[untouched, default: []].isEmpty)
        #expect(try await db.projectNames(forVideos: []).isEmpty)

        let facts = try await db.fetchVideoFacts(ids: [shared, unassigned, untouched, shared])
        #expect(facts.count == 3)
        #expect(facts[shared]?.hasScenes == true)
        #expect(facts[shared]?.hasTranscript == false)
        #expect(facts[shared]?.projectIDs == [alpha, beta])
        #expect(facts[unassigned]?.hasScenes == false)
        #expect(facts[unassigned]?.hasTranscript == true)
        #expect(facts[unassigned]?.projectIDs == [])
        #expect(facts[untouched] == HomeVideoCandidate.Facts())
        #expect(try await db.fetchVideoFacts(ids: []).isEmpty)

        try await db.assignVideos([unassigned], to: alpha)
        #expect(try await db.countVideosNotInProject(alpha) == 1)
        try await db.removeVideos([unassigned], from: alpha)
        #expect(try await db.countVideosNotInProject(alpha) == 2)
        try await db.setVideosHidden([unassigned], true)
        #expect(try await db.countVideosNotInProject(alpha) == 1)
    }
}
