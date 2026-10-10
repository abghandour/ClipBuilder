import Foundation
import Testing
@testable import Clip_Builder

@Suite("Person research")
struct PersonResearchTests {
    private func request(fields: [String] = TagTextWriter.profileFields) -> PersonResearchRequest {
        .init(person: PersonRecord(id: 1, key: "test-fighter", name: "Test Fighter", descriptor: "Red gloves"),
              fields: fields, context: "Championship interview.mp4")
    }

    @Test("Parser keeps only requested, supported fields and their sources")
    func requestedFieldsAndSources() {
        let object: [String: Any] = ["found": true, "category": "fighter", "fields": [
            "MMA record": ["value": " 23-7-0 \n", "source": "https://stats.example/fighter",
                           "as_of": "2026-09-20", "confidence": 0.9],
            "Team": ["value": "Example Team", "confidence": 0.95],
        ]]
        let result = PersonResearch.parse(object, request: request(fields: ["MMA record"]))
        #expect(result.personKey == "test-fighter")
        #expect(result.category == .fighter)
        #expect(result.proposals.count == 1)
        #expect(result.proposals.first?.field == "MMA record")
        #expect(result.proposals.first?.value == "23-7-0")
        #expect(result.proposals.first?.source == "https://stats.example/fighter")
        #expect(result.proposals.first?.asOf == "2026-09-20")
        #expect(result.provenance == nil)
    }

    @Test("Ambiguous identities have neither fields nor categories")
    func notFound() {
        let result = PersonResearch.parse(["found": false, "category": "fighter",
            "fields": ["Role": ["value": "Champion", "confidence": 0.9]]], request: request())
        #expect(result.proposals.isEmpty)
        #expect(result.category == nil)
    }

    @Test("Parser rejects guesses, repeated names, blanks and overlong values")
    func rejectedValues() {
        for (value, confidence) in [("Champion", 0.49), ("Test Fighter", 0.9),
                                     ("  TEST  FIGHTER \n", 0.9), (" \n ", 0.9),
                                     (String(repeating: "a", count: 41), 0.9), ("Champion", 1.1)] {
            let result = PersonResearch.parse(["found": true,
                "fields": ["Role": ["value": value, "confidence": confidence]]], request: request())
            #expect(result.proposals.isEmpty)
        }
        let result = PersonResearch.parse(["found": true,
            "fields": ["Role": ["value": "  Former \n champion ", "confidence": 0.5]]], request: request())
        #expect(result.proposals.first?.value == "Former champion")
    }

    @Test("Parser normalizes handles before validating their length")
    func handleFields() {
        let instagramHandle = String(repeating: "a", count: 30)
        let result = PersonResearch.parse(["found": true, "fields": [
            "Instagram": ["value": "https://www.instagram.com/\(instagramHandle)/?hl=en", "confidence": 0.9],
            "X": ["value": "@name", "confidence": 0.9],
        ]], request: request())
        #expect(result.proposals.first(where: { $0.field == "Instagram" })?.value == instagramHandle)
        #expect(result.proposals.first(where: { $0.field == "X" })?.value == "name")
        for value in ["Not an account", "", "name.with.dots", String(repeating: "a", count: 16)] {
            let invalid = PersonResearch.parse(["found": true,
                "fields": ["X": ["value": value, "confidence": 0.9]]], request: request())
            #expect(invalid.proposals.isEmpty)
        }
    }

    @Test("Unsafe source links are omitted and assigned categories are not proposed again")
    func sourceAndCategoryValidation() {
        var input = request()
        input.person.category = .trainer
        let result = PersonResearch.parse(["found": true, "category": "fighter",
            "fields": ["Role": ["value": "Trainer", "source": "file:///private/data", "confidence": 0.8]]], request: input)
        #expect(result.category == nil)
        #expect(result.proposals.first?.source == nil)
        #expect(PersonResearch.sourceURL("https://") == nil)
    }

    @Test("Fighter record refresh uses category, missing values and provenance age")
    func recordStaleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var person = request().person
        person.category = .fighter
        var record = PersonTagField(personKey: person.key, field: "MMA record", value: "23-7-0",
                                    provenance: AIProvenance(provider: "claude", at: now))
        #expect(PersonResearch.needsRecordRefresh(fields: [], person: person, now: now))
        #expect(!PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        record.provenance?.at = now.addingTimeInterval(-30 * 86400)
        #expect(!PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        record.provenance?.at = now.addingTimeInterval(-31 * 86400)
        #expect(PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        person.category = .trainer
        #expect(!PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        person.category = nil
        #expect(!PersonResearch.needsRecordRefresh(fields: [], person: person, now: now))
        person.category = .fighter
        record.provenance = nil
        #expect(PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        record.provenance = AIProvenance(provider: "claude")
        #expect(PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
        record.provenance?.at = now
        record.value = ""
        #expect(PersonResearch.needsRecordRefresh(fields: [record], person: person, now: now))
    }

    @Test("Prompt includes the identity, requested fields, context and evidence rules")
    func prompt() {
        let input = request(fields: ["Role", "Team", "Instagram", "X"])
        let prompt = PersonResearch.prompt(for: input)
        for text in ["Test Fighter", "Role", "Team", "Instagram", "X", input.context, "never invent",
                     "Omit a field rather than guess", "own verified or clearly official account",
                     "bare handle", "Omit fan or news accounts"] {
            #expect(prompt.contains(text))
        }
    }

    @Test("Batch continues after one failure and keeps category-only identities")
    func batchFailure() async throws {
        let first = request(), second = request(fields: ["Role"])
        let outcomes = try await PersonResearchService().runBatch([first, second], ai: AIService(config: AIConfig()),
            runner: { input in
                if input.fields.count > 1 { throw AIError.unusableResponse("Fixture failure") }
                return PersonResearchOutcome(personKey: input.person.key, proposals: [], category: .fighter, provenance: nil)
            }, log: { _ in })
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.personKey == first.person.key)
        #expect(outcomes.first?.category == .fighter)
    }
}
