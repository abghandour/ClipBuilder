import Foundation
import Testing
@testable import Clip_Builder

@Suite("Canonical analysis requests")
struct AnalysisRequestTests {
    static func request() -> AnalysisRequest {
        AnalysisRequest(sourceIdentity: "source", videoType: "fight", pipeline: 1,
                        passVersions: ["scenes": 1, "people": 1, "fightScore": 2],
                        plan: AnalysisCheckpoint.Plan(), requestedPasses: ["scenes", "people", "fightScore"])
    }

    @Test func fingerprintIsStableAcrossKeyOrderCollectionsAndAutomaticDefaults() throws {
        var first = Self.request()
        first.tags = ["b": ["two", "one"], "a": ["three"]]
        first.plan.requiredPeopleKeys = ["b", "a"]
        first.notes = [.init(at: 4, note: "four"), .init(at: 1, note: "one")]
        var second = first
        second.tags = ["a": ["three"], "b": ["one", "two", "two"]]
        second.plan.requiredPeopleKeys = ["a", "b", "a"]
        second.plan.sampleInterval = 0
        second.requestedPasses.reverse()
        second.notes.reverse()
        second.podcastJSON = AnalysisRequest.json(PodcastSettings())
        second.plan.provider = "presentation override already resolved into routing"
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint.count == 64)
        let object = try JSONSerialization.jsonObject(with: Data(first.json.utf8))
        let unordered = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AnalysisRequest.self, from: unordered)
        #expect(decoded.fingerprint == first.fingerprint)
        #expect(decoded == first.normalized)
    }

    @Test func inferredTypeResolvesIntoTheSavedRequestAndKeepsAKnownOne() {
        var untyped = Self.request()
        untyped.videoType = nil
        untyped.plan.includeFightScoring = true
        untyped.plan.detectPeople = false
        untyped.refreshPasses()
        #expect(untyped.requestedPasses == ["scenes"])
        var typed = untyped
        typed.videoType = "fight"
        typed.refreshPasses()
        let resolved = untyped.resolvingVideoType(.fight)
        #expect(resolved.fingerprint == typed.normalized.fingerprint)
        #expect(resolved.requestedPasses.contains("fightScore"))
        #expect(untyped.fingerprint != resolved.fingerprint)
        #expect(typed.resolvingVideoType(.podcast) == typed)
        var spoken = untyped
        spoken.language = "en"
        let podcast = spoken.resolvingVideoType(.podcast)
        #expect(podcast.language == "")
        #expect(podcast.pipeline == AnalysisPipeline.podcastPass)
        #expect(Set(podcast.requestedPasses) == ["scenes", "people", "transcript", "exchanges"])
    }

    @Test func everyDifferingComponentIsNamed() {
        let old = Self.request()
        let cases: [(String, (inout AnalysisRequest) -> Void)] = [
            ("request format 1 → 2", { $0.version = 2 }),
            ("source file changed", { $0.sourceIdentity = "replacement" }),
            ("video type changed", { $0.videoType = "podcast" }),
            ("pipeline 1 → 2", { $0.pipeline = 2 }),
            ("pass versions changed", { $0.passVersions["people"] = 2 }),
            ("trim range changed", { $0.plan.trimRange = [1, 4] }),
            ("sampling automatic → 1 s", { $0.plan.sampleInterval = 1 }),
            ("smart sampling changed", { $0.plan.smartSampling = false }),
            ("instructions changed", { $0.plan.instructions = "Look for kicks" }),
            ("notes added", { $0.notes = [.init(at: 2, note: "Round start")] }),
            ("required people changed", { $0.plan.requiredPeopleKeys = ["fighter"] }),
            ("identity markers changed", { $0.markers = [.init(at: 2, x: 0, y: 0, width: 1, height: 1, personKey: "fighter", ignored: false)] }),
            ("people identities changed", { $0.people = [.init(key: "fighter", descriptor: "Red gloves")] }),
            ("profile tags changed", { $0.tags = ["actions": ["kick"]] }),
            ("profile domain changed", { $0.domain = "combat sports" }),
            ("taste inputs changed", { $0.tasteRubric = "Fast exchanges" }),
            ("taste inputs changed", { $0.exemplarHashes = ["image"] }),
            ("taste inputs changed", { $0.taste = [.init(key: "fight", rubric: "Fast", exemplarHashes: [])] }),
            ("model routing changed", { $0.routing = ["analysis": [.init(provider: "claude", model: "model")]] }),
            ("on-device policy changed", { $0.onDevice = ["podcast-exchanges": true] }),
            ("transcript dependency changed", { $0.transcriptKey = "set" }),
            ("transcript dependency changed", { $0.transcriptHash = "corrected" }),
            ("transcript dependency changed", { $0.language = "pt" }),
            ("podcast settings changed", { $0.podcastJSON = "{\"highlight_threshold\":9}" }),
            ("requested passes changed", { $0.requestedPasses.append("transcript") }),
            ("requested passes changed", { $0.plan.detectPeople = false }),
            ("requested passes changed", { $0.plan.includeTranscript = true }),
            ("requested passes changed", { $0.plan.includeFightScoring = false }),
            ("automatic framing changed", { $0.plan.autoZoomUnframed = true }),
            ("breakdown tags changed", { $0.plan.breakdownTags = ["kick"] })
        ]
        for (label, mutate) in cases {
            var new = old
            mutate(&new)
            #expect(new.fingerprint != old.fingerprint)
            #expect(AnalysisRequestDiff.describe(old: old, new: new).contains(label))
        }
        var a = old, b = old
        a.plan.sampleInterval = 2; b.plan.sampleInterval = 1
        #expect(AnalysisRequestDiff.describe(old: a, new: b) == ["sampling 2 s → 1 s"])
    }

    @Test func oneShotInputsAreCapturedBeforeConsumption() throws {
        let suite = "AnalysisRequest-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3.0, forKey: "analysis.trimStart")
        defaults.set(9.0, forKey: "analysis.trimEnd")
        defaults.set("b,a", forKey: "analysis.requiredPeople")
        defaults.set("[{\"at\":4,\"note\":\"Keep this\"}]", forKey: "analysis.pastedNotes")
        let plan = AnalysisRequest.capturePlan(defaults: defaults, singleVideo: true, provider: nil, model: nil, includeFightScoring: false)
        #expect(defaults.object(forKey: "analysis.trimStart") != nil)
        AnalysisRequest.consumeOneShotDefaults(defaults)
        #expect(plan.trimRange == [3, 9])
        #expect(plan.requiredPeopleKeys == ["b", "a"])
        #expect(plan.pastedNotes == [.init(at: 4, note: "Keep this")])
        for key in ["trimStart", "trimEnd", "requiredPeople", "pastedNotes"] { #expect(defaults.object(forKey: "analysis.\(key)") == nil) }
    }

    @Test func missingPassesRespectEmptySuccessFailureVersionsAndRunIdentity() {
        let run = AnalysisRun(id: 1, videoID: 1, name: "", instructions: "", provider: nil, model: nil,
            hasTranscript: true, sampleInterval: 0, notesJSON: nil, createdAt: nil, videoFilename: "", videoPath: "", sceneCount: 0)
        var request = Self.request()
        request.requestedPasses = ["scenes", "exchanges", "people", "fightScore", "transcript"]
        let passes = [
            AnalysisPassRecord(videoID: 1, pass: .exchanges, version: 1, status: .completed, startedAt: "1"),
            AnalysisPassRecord(videoID: 1, pass: .people, version: 1, status: .failed, startedAt: "2"),
            AnalysisPassRecord(videoID: 1, pass: .fightScore, version: 2, status: .cancelled, startedAt: "3"),
            AnalysisPassRecord(videoID: 1, pass: .transcript, version: 1, status: .completed, startedAt: "4")
        ]
        #expect(AnalysisDuplicates.missingPasses(request: request, run: run, passes: passes, peopleCount: 2) == ["fightScore", "people"])
        var completedEmpty = passes
        completedEmpty[1].status = .completed
        #expect(AnalysisDuplicates.missingPasses(request: request, run: run, passes: completedEmpty) == ["fightScore"])
        var scopedRun = run
        scopedRun.runKey = "this-batch"
        completedEmpty[1].runKey = "another-batch"
        #expect(AnalysisDuplicates.missingPasses(request: request, run: scopedRun, passes: completedEmpty) == ["fightScore", "people"])
        request.passVersions["exchanges"] = 2
        #expect(AnalysisDuplicates.missingPasses(request: request, run: run, passes: passes) == ["exchanges", "fightScore", "people"])
        #expect(AnalysisDuplicates.missingPasses(request: request, run: run, passes: [], qaCount: 2, peopleCount: 2, hasTranscript: true) == ["fightScore"])
    }

    @Test func coverageKeepsExistingStatesAndIdentifiesTheEqualActiveRun() {
        var video = Fixtures.video()
        video.videoType = VideoType.podcast.rawValue
        let run = AnalysisRun(id: 1, videoID: video.id, name: "", instructions: "", provider: nil, model: nil,
            hasTranscript: true, sampleInterval: 0, notesJSON: nil, createdAt: nil, videoFilename: "", videoPath: "", sceneCount: 0,
            settingsJSON: AISettingsJSON.encode(AnalysisRunSettings(pipeline: AnalysisPipeline.podcastPass)))
        let ordinary = AnalysisCoverage.report(video: video, activeRun: run, scenes: [], transcriptCount: 1)
        let equal = AnalysisCoverage.report(video: video, activeRun: run, scenes: [], transcriptCount: 1, duplicateOf: run)
        #expect(ordinary.sameAsActive == nil)
        #expect(equal.sameAsActive == true && equal.state == ordinary.state)
        #expect(AnalysisCoverage.message(for: equal, type: video.type) == "Up to date, same settings.")
        var other = run; other.id = 2
        #expect(AnalysisCoverage.report(video: video, activeRun: run, scenes: [], transcriptCount: 1, duplicateOf: other).sameAsActive == false)
    }

}
