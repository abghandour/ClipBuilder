import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Script filters and queries", .serialized)
struct ClipFilterTests {
    @Test("People/tags are all-of, any-tags is any-of, and time overlap is half-open")
    func predicates() throws {
        var scene = Fixtures.scene()
        scene.tags = ["person:alice", "person:bob", "action", "highlight"]
        scene.score = 4
        var clip = Fixtures.timelineClip(duration: 4, startTime: 2, track: 1)
        clip.role = .cutaway
        var filter = ClipFilter()
        filter.track = 1; filter.role = .cutaway
        filter.people = ["alice", "bob"]; filter.tags = ["action", "highlight"]
        filter.anyTags = ["missing", "action"]; filter.sceneScoreBelow = 5
        filter.between = ScriptTimeRange(start: 1, end: 3)
        #expect(filter.matches(clip, scene: scene))
        #expect(try JSONDecoder().decode(ClipFilter.self, from: JSONEncoder().encode(filter)) == filter)
        filter.between = ScriptTimeRange(start: 0, end: 2)
        #expect(!filter.matches(clip, scene: scene))
        filter.between = ScriptTimeRange(start: 6, end: 8)
        #expect(!filter.matches(clip, scene: scene))
        filter.between = nil; filter.people.append("unknown")
        #expect(!filter.matches(clip, scene: scene))
        filter.people = []; filter.tags.append("missing")
        #expect(!filter.matches(clip, scene: scene))
    }

    @Test("Bumpers opt in; unknown scores never satisfy comparisons")
    func unknownData() {
        var clip = Fixtures.timelineClip()
        var scene = Fixtures.scene()
        var filter = ClipFilter()
        clip.bumper = true
        #expect(!filter.matches(clip, scene: scene))
        filter.includeBumpers = true
        #expect(filter.matches(clip, scene: scene))
        filter.sceneScoreBelow = 10
        scene.score = nil
        #expect(!filter.matches(clip, scene: scene))
        scene.score = .nan
        #expect(!filter.matches(clip, scene: scene))
        #expect(!filter.matches(clip, scene: nil))
    }

    @Test("Scene and people query scopes, excluded/hidden defaults and deterministic pagination")
    func queryDefaults() throws {
        let model = ScriptFixtures.model()
        var library = ScriptFixtures.library()
        var excluded = Fixtures.scene(id: 2)
        excluded.excluded = true; excluded.score = 10
        var unknown = Fixtures.scene(id: 3)
        unknown.score = nil
        library.scenes += [excluded, unknown]
        library.people = [PersonRecord(id: 1, key: "a", name: "Alice", descriptor: "One"),
                          PersonRecord(id: 2, key: "b", name: "Bob", descriptor: "Two", hidden: true)]
        let resolve: (String) throws -> UUID = { _ in throw ScriptError.invalid("unused") }
        let query = BuilderQuery(.scenes, limit: 1)
        let first = try query.execute(model: model, library: library, resolve: resolve)
        #expect(first.scenes.map(\.id) == [1] && first.total == 2 && first.nextOffset == 1)
        let last = try BuilderQuery(.scenes, offset: 1, limit: 1).execute(model: model, library: library, resolve: resolve)
        #expect(last.scenes.map(\.id) == [3] && last.nextOffset == nil)
        var all = BuilderQuery(.scenes)
        all.sceneFilter = SceneFilter(); all.sceneFilter?.includeExcluded = true
        #expect(try all.execute(model: model, library: library, resolve: resolve).scenes.map(\.id) == [2, 1, 3])
        var people = BuilderQuery(.people)
        #expect(try people.execute(model: model, library: library, resolve: resolve).people.map(\.key) == ["a"])
        people.includeHidden = true
        #expect(try people.execute(model: model, library: library, resolve: resolve).people.count == 2)
        var outside = BuilderQuery(.transcript); outside.video = 99
        #expect(throws: ScriptError.self) { try outside.execute(model: model, library: library, resolve: resolve) }
        var invalid = BuilderQuery(.scenes); invalid.limit = 201
        #expect(throws: ScriptError.self) { try invalid.execute(model: model, library: library, resolve: resolve) }
    }

    @Test("Scene filter excludes timeline fields and uses score, video, people and text")
    func sceneSchema() throws {
        let json = Data(#"{"people":["alice"],"tags":["action"],"video":1,"text":"fixture","min_score":7}"#.utf8)
        let filter = try JSONDecoder().decode(SceneFilter.self, from: json)
        var scene = Fixtures.scene(); scene.tags = ["person:alice", "action"]
        #expect(filter.matches(scene))
        scene.score = nil
        #expect(!filter.matches(scene))
        #expect(throws: ScriptError.self) {
            try JSONDecoder().decode(SceneFilter.self, from: Data(#"{"track":0}"#.utf8))
        }
    }

    @Test("Original-language transcript words are decoded and clipped to the source window")
    func transcriptWords() throws {
        let model = ScriptFixtures.model()
        var library = ScriptFixtures.library()
        var row = transcript(words: #"[{"word":"one","start":2,"end":3},{"word":"two","start":4,"end":5}]"#)
        library.transcripts = [row]
        row.id = 2; row.isTranslation = true; row.text = "Translation"
        library.transcripts.append(row)
        var query = BuilderQuery(.transcript)
        query.video = 1; query.range = ScriptTimeRange(start: 2.5, end: 4.5)
        let result = try query.execute(model: model, library: library, resolve: { _ in UUID() })
        #expect(result.transcripts.count == 1)
        #expect(result.transcripts[0].start == 2.5 && result.transcripts[0].end == 4.5)
        #expect(result.transcripts[0].words?.first?.start == 2.5)
        #expect(result.transcripts[0].words?.last?.end == 4.5)
        #expect(result.unknown.isEmpty)
    }

    @Test("Silence uses evidence, honors rejected proposals and maps through speed")
    func silences() throws {
        let clip = Fixtures.timelineClip(sourceStart: 2, duration: 4, startTime: 10, speed: 0.5)
        let model = ScriptFixtures.model(clips: [clip])
        var library = ScriptFixtures.library()
        library.transcripts = [transcript(words: #"[{"word":"one","start":2,"end":2.5},{"word":"two","start":3.5,"end":4}]"#)]
        var query = BuilderQuery(.silences)
        query.clip = clip.uid.uuidString
        let result = try query.execute(model: model, library: library, resolve: { _ in clip.uid })
        let silence = try #require(result.silences.first)
        #expect(silence.source == ScriptTimeRange(start: 2.5, end: 3.5))
        #expect(silence.timeline == ScriptTimeRange(start: 11, end: 13))
        #expect(silence.evidence == "word_gap" && silence.precision == .speech)
        library.proposals = [EditProposal(id: 1, videoID: 1, kind: .silence, startTime: 2.5,
                                         endTime: 3.5, reason: "Keep", decision: .rejected)]
        #expect(try query.execute(model: model, library: library, resolve: { _ in clip.uid }).silences.isEmpty)
        library.proposals = []; library.transcripts = [transcript(words: nil)]
        let unknown = try query.execute(model: model, library: library, resolve: { _ in clip.uid })
        #expect(unknown.silences.isEmpty && unknown.unknown == ["word_timings"])
        library.features = [TranscriptFeatureSegment(id: 1, videoID: 1, startTime: 2.2, endTime: 2.7,
                                                      text: "", speakerKey: nil, energy: 0, kind: .silence)]
        #expect(try query.execute(model: model, library: library, resolve: { _ in clip.uid })
            .silences.first?.evidence == "classified_silence")
    }

    @Test("Capabilities distinguish completed empty from unavailable; layouts/tags are snapshots")
    func capabilities() throws {
        let model = ScriptFixtures.model()
        var library = ScriptFixtures.library()
        library.videos[0].speechSeconds = 2
        library.videos[0].peopleDetectedAt = "2026-09-10"
        library.tags = ["custom"]
        let result = try BuilderQuery(.capabilities).execute(model: model, library: library, resolve: { _ in UUID() })
        #expect(result.capabilities.first?.transcript == .completedEmpty)
        #expect(result.capabilities.first?.people == .completedEmpty)
        #expect(result.capabilities.first?.analysis == .completedWithData)
        #expect(try BuilderQuery(.tags).execute(model: model, library: library, resolve: { _ in UUID() }).tags.contains("custom"))
        #expect(try BuilderQuery(.layouts).execute(model: model, library: library, resolve: { _ in UUID() }).layouts.count == 4)
    }

    private func transcript(words: String?) -> TranscriptRow {
        TranscriptRow(id: 1, videoID: 1, language: "en", isTranslation: false, startTime: 2, endTime: 5,
                      text: "one two", originalText: nil, wordsJSON: words, provider: nil, model: nil)
    }
}

extension ClipFilterTests {
    @Test func rosterRangeFallbackAndCaseInsensitiveNames() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 4, speed: 0.5)
        var library = ScriptFixtures.library()
        library.scenes = []
        library.videoPeople = [1: [.init(key: "aljo_key", name: "Aljo", ranges: [.init(start: 3, end: 5)])]]
        var filter = ClipFilter()
        for name in ["ALJO_KEY", "aLjO"] {
            filter.people = [name]
            #expect(filter.matches(clip, scene: nil, library: library))
        }
        let model = ScriptFixtures.model(clips: [clip])
        var query = BuilderQuery(.clips); query.filter = filter
        let result = try query.execute(model: model, library: library, resolve: { _ in clip.uid })
        let row = try #require(result.clips.first)
        #expect(row.people == ["aljo_key"])
        #expect(row.unknown.contains("people derived from the video roster; clip has no scene link"))
        // Source span ends at 4 despite the four-second screen duration.
        library.videoPeople[1] = [.init(key: "aljo_key", name: "Aljo", ranges: [.init(start: 4, end: 6)])]
        #expect(!filter.matches(clip, scene: nil, library: library))
        #expect(ClipQueryRow(clip, scene: nil, library: library).people.isEmpty)
        library.videoPeople[1] = [.init(key: "aljo_key", name: "Aljo", ranges: [])]
        #expect(filter.matches(clip, scene: nil, library: library))
        var missingScene = clip; missingScene.sceneID = 999
        #expect(filter.matches(missingScene, scene: nil, library: library))
        var linked = Fixtures.scene(); linked.tags = ["person:aljo_key"]
        let linkedClip = Fixtures.timelineClip()
        filter.people = ["ALJO_KEY"]
        library.videoPeople = [:]
        #expect(filter.matches(linkedClip, scene: linked, library: library))
        #expect(ClipQueryRow(linkedClip, scene: linked, library: library)
            == ClipQueryRow(linkedClip, scene: linked))
    }

    @Test func sceneInferenceRequiresUniqueHalfSpanOverlapAndDoesNotMutate() {
        let clip = Fixtures.timelineClip(sceneID: nil)
        var library = ScriptFixtures.library()
        library.scenes = [Fixtures.scene(start: 4, end: 8)]
        let row = ClipQueryRow(clip, scene: nil, library: library)
        #expect(row.tags == ["fixture"] && row.score == 8)
        #expect(row.unknown.contains("scene inferred from source overlap"))
        #expect(row.scene == nil && clip.sceneID == nil)
        library.scenes.append(Fixtures.scene(id: 2))
        #expect(ClipQueryRow(clip, scene: nil, library: library).score == nil)
        library.scenes = [Fixtures.scene(start: 4.01, end: 8)]
        #expect(ClipQueryRow(clip, scene: nil, library: library).score == nil)
    }
}

extension ClipFilterTests {
    @Test func snapshotLoadsAndRefreshesPersistedRosterRanges() async throws {
        let temp = try TempDatabase()
        let video = try await temp.seedVideo(sceneCount: 0)
        try await temp.database.upsertPerson(key: "aljo_key", descriptor: "fixture")
        let people = try await temp.database.fetchPeople()
        let person = try #require(people.first { $0.key == "aljo_key" })
        try await temp.database.renamePerson(id: person.id, name: "Aljo")
        try await temp.database.replaceVideoPeople(videoID: video,
            entries: [(person.id, 2, nil, #"[{"start":2,"end":4}]"#)])
        let snapshot = try await ScriptLibrarySnapshot().refreshed(database: temp.database)
        #expect(snapshot.videoPeople[video] == [.init(key: "aljo_key", name: "Aljo", ranges: [.init(start: 2, end: 4)])])
        #expect(snapshot.videosWithPeople.contains(video))
        try await temp.database.replaceVideoPeople(videoID: video, entries: [(person.id, 2, nil, nil)])
        let wholeVideo = try await snapshot.refreshed(database: temp.database)
        #expect(wholeVideo.videoPeople[video]?.first?.ranges == [])
        try await temp.database.replaceVideoPeople(videoID: video, entries: [])
        let empty = try await wholeVideo.refreshed(database: temp.database)
        #expect(empty.videoPeople[video] == [])
        #expect(!empty.videosWithPeople.contains(video))
    }
}
