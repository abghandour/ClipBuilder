import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Saved script request matching")
struct ScriptRequestMatcherTests {
    static func record(_ source: String, id: UUID = UUID()) throws -> BuilderScriptRecord {
        let header = try ScriptHeader.parse(source)
        let metadata = try header.metadataJSON()
        return .init(id: id, name: header.name, description: header.description, source: source,
                     paramsJSON: metadata.params, requiresJSON: metadata.requires, mode: header.mode,
                     origin: .human, createdAt: "", updatedAt: "", lastRunAt: nil, lastRunStatus: nil)
    }

    static func capture() -> ScriptCapture {
        var library = ScriptFixtures.library()
        library.people = [.init(id: 1, key: "aljo-roster", name: "Aljo", descriptor: "")]
        library.tags = ["training", "interview"]
        return ScriptCapture(model: ScriptFixtures.model(), library: library)
    }

    @Test func exactMuteNeedsNoParameters() throws {
        let records = try ScriptExamples.all.map { try Self.record($0.source) }
        let matches = ScriptRequestMatcher.match(request: "mute all b-roll", scripts: records, capture: Self.capture())
        let best = try #require(matches.first)
        #expect(best.record.name == "Mute all B-roll")
        #expect(ScriptRequestMatcher.confidence(matches) == .confident)
        #expect(best.runnable && best.extractedParameters.isEmpty)
    }

    @Test func splitExtractsSixParts() throws {
        let script = try Self.record(ScriptExamples.splitSelection)
        let matches = ScriptRequestMatcher.match(request: "split the selected clip into 6 parts", scripts: [script], capture: Self.capture())
        let best = try #require(matches.first)
        #expect(best.extractedParameters["parts"] == .number(6))
        #expect(best.runnable && ScriptRequestMatcher.confidence(matches) == .confident)
    }

    @Test func personNameResolvesRosterKey() throws {
        let script = try Self.record(ScriptExamples.removePerson)
        let matches = ScriptRequestMatcher.match(request: "remove clips with Aljo", scripts: [script], capture: Self.capture())
        let best = try #require(matches.first)
        #expect(best.extractedParameters["person"] == .string("aljo-roster"))
        #expect(best.runnable && ScriptRequestMatcher.confidence(matches) == .confident)
    }

    @Test func unrelatedRequestHasNoCandidate() throws {
        let scripts = try ScriptExamples.all.map { try Self.record($0.source) }
        #expect(ScriptRequestMatcher.match(request: "make the intro punchier", scripts: scripts, capture: Self.capture()).isEmpty)
    }

    @Test func equalCandidatesAreAmbiguous() throws {
        let scripts = try [Self.record(ScriptExamples.muteBRoll), Self.record(ScriptExamples.muteBRoll)]
        let matches = ScriptRequestMatcher.match(request: "mute all b-roll", scripts: scripts, capture: Self.capture())
        #expect(matches.count == 2)
        #expect(ScriptRequestMatcher.confidence(matches) == .ambiguous)
    }

    @Test func requiredPersonMissingIsNotRunnable() throws {
        let script = try Self.record(ScriptExamples.removePerson)
        let matches = ScriptRequestMatcher.match(request: "Remove clips with a person", scripts: [script], capture: Self.capture())
        #expect(try #require(matches.first).runnable == false)
    }

    @Test func invalidNumberCannotFallBackToDefault() throws {
        let script = try Self.record(ScriptExamples.splitSelection)
        let matches = ScriptRequestMatcher.match(request: "split the selected clip into 99 parts", scripts: [script], capture: Self.capture())
        #expect(try #require(matches.first).runnable == false)
    }

    @Test func choicesTagsAndDuplicatePeople() throws {
        let source = ScriptHeaderTests.source(params: #"[{"name":"style","type":"choice","choices":["training","interview"]}]"#)
        let matches = ScriptRequestMatcher.match(request: "Test script training", scripts: [try Self.record(source)], capture: Self.capture())
        #expect(try #require(matches.first).extractedParameters["style"] == .string("training"))
        var capture = Self.capture()
        capture.library.people.append(.init(id: 2, key: "another", name: "Aljo", descriptor: ""))
        let people = ScriptRequestMatcher.match(request: "remove clips with Aljo", scripts: [try Self.record(ScriptExamples.removePerson)], capture: capture)
        #expect(people.allSatisfy { !$0.runnable })
        let tagSource = ScriptHeaderTests.source(params: #"[{"name":"tag","type":"string"}]"#)
        let tags = ScriptRequestMatcher.match(request: "Test script training", scripts: [try Self.record(tagSource)], capture: Self.capture())
        #expect(try #require(tags.first).extractedParameters["tag"] == .string("training"))
    }

    @Test(arguments: ["do not mute all b-roll", "mute all b-roll and remove the intro", "mute all b-roll except interviews"])
    func qualifiedRequestsNeverRouteDeterministically(request: String) throws {
        let matches = ScriptRequestMatcher.match(request: request, scripts: [try Self.record(ScriptExamples.muteBRoll)], capture: Self.capture())
        #expect(ScriptRequestMatcher.confidence(matches) != .confident)
    }
}
