import Foundation
import Testing
@testable import Clip_Builder

@Suite("Database person tag fields")
struct DatabaseTagFieldsTests {
    @Test("Source and provenance round-trip, and manual overwrites clear them")
    func sourceRoundTrip() async throws {
        let temp = try TempDatabase()
        let person = try await temp.database.createPerson(name: "Test Fighter")
        let provenance = AIProvenance(provider: "claude", task: "person_research", at: Date(timeIntervalSince1970: 1_800_000_000))
        try await temp.database.savePersonTagField(personKey: person.key, field: "MMA record", value: "23-7-0",
                                                   provenance: provenance, source: "https://stats.example/fighter")
        let row = try #require(try await temp.database.personTagFields(personKey: person.key).first)
        #expect(row.source == "https://stats.example/fighter")
        #expect(row.provenance == provenance)
        #expect(try await temp.database.personTagFieldsByPerson()[person.key] == [row])
        try await temp.database.savePersonTagField(personKey: person.key, field: "MMA record", value: "24-7-0", provenance: nil)
        let edited = try #require(try await temp.database.personTagFields(personKey: person.key).first)
        #expect(edited.source == nil)
        #expect(edited.provenance == nil)
    }

    @Test("Version 29 databases migrate existing tag fields without losing their values")
    func existingRowsMigrate() async throws {
        let temp = try TempDatabase()
        let person = try await temp.database.createPerson(name: "Legacy Person")
        try await temp.database.savePersonTagField(personKey: person.key, field: "Role", value: "Trainer", provenance: nil)
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("ALTER TABLE person_tag_fields DROP COLUMN source")
        try raw.execute("PRAGMA user_version = 29")
        let reopened = try Database(path: temp.path)
        let row = try #require(try await reopened.personTagFields(personKey: person.key).first)
        #expect(row.value == "Trainer")
        #expect(row.source == nil)
        #expect(try raw.columnNames(of: "person_tag_fields").contains("source"))
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
    }

    @Test("Apply saves only checked values and preserves a category assigned during research")
    func selectiveApply() async throws {
        let temp = try TempDatabase()
        let person = try await temp.database.createPerson(name: "Test Fighter")
        let first = PersonResearchProposal(personKey: person.key, field: "Role", value: "Champion",
                                          source: "https://stats.example/fighter", asOf: nil, confidence: 0.9)
        let second = PersonResearchProposal(personKey: person.key, field: "Team", value: "Example Team",
                                           source: nil, asOf: nil, confidence: 0.8)
        let outcome = PersonResearchOutcome(personKey: person.key, proposals: [first, second], category: .fighter,
                                            provenance: AIProvenance(provider: "claude", task: "person_research"))
        #expect(try await temp.database.personTagFields().isEmpty)
        try await temp.database.setPersonCategory(id: person.id, category: .trainer)
        try await temp.database.applyPersonResearch([outcome], proposalIDs: [first.id], categoryKeys: [person.key])
        let rows = try await temp.database.personTagFields()
        #expect(rows.map(\.field) == ["Role"])
        #expect(rows.first?.source == first.source)
        #expect(try await temp.database.fetchPeople().first?.category == .trainer)
        try await temp.database.setPersonCategory(id: person.id, category: nil)
        try await temp.database.applyPersonResearch([outcome], proposalIDs: [], categoryKeys: [person.key])
        #expect(try await temp.database.fetchPeople().first?.category == .fighter)
    }

    @Test("Apply normalizes handles and clears invalid selected handle values")
    func applyHandles() async throws {
        let temp = try TempDatabase()
        let person = try await temp.database.createPerson(name: "Test Fighter")
        try await temp.database.savePersonTagField(personKey: person.key, field: "X", value: "old_name", provenance: nil)
        let instagram = PersonResearchProposal(personKey: person.key, field: "Instagram",
            value: "https://www.instagram.com/name/?hl=en", source: "https://instagram.com/name",
            asOf: nil, confidence: 0.9)
        let invalidX = PersonResearchProposal(personKey: person.key, field: "X", value: "Not an account",
            source: nil, asOf: nil, confidence: 0.9)
        let provenance = AIProvenance(provider: "claude", task: "person_research")
        let outcome = PersonResearchOutcome(personKey: person.key, proposals: [instagram, invalidX],
            category: nil, provenance: provenance)
        try await temp.database.applyPersonResearch([outcome], proposalIDs: [instagram.id], categoryKeys: [])
        let initial = try await temp.database.personTagFields(personKey: person.key)
        #expect(initial.first(where: { $0.field == "Instagram" })?.value == "name")
        #expect(initial.first(where: { $0.field == "Instagram" })?.source == instagram.source)
        #expect(initial.first(where: { $0.field == "Instagram" })?.provenance == provenance)
        #expect(initial.first(where: { $0.field == "X" })?.value == "old_name")
        try await temp.database.applyPersonResearch([outcome], proposalIDs: [invalidX.id], categoryKeys: [])
        let final = try await temp.database.personTagFields(personKey: person.key)
        #expect(final.map(\.field) == ["Instagram"])
    }

    @Test("Merging people carries source links with their tag fields")
    func mergePreservesSource() async throws {
        let temp = try TempDatabase()
        let source = try await temp.database.createPerson(name: "Duplicate")
        let target = try await temp.database.createPerson(name: "Survivor")
        try await temp.database.savePersonTagField(personKey: source.key, field: "Role", value: "Fighter",
                                                   provenance: nil, source: "https://stats.example/fighter")
        try await temp.database.mergePeople(source: source, into: target)
        let fields = try await temp.database.personTagFields(personKey: target.key)
        #expect(fields.first?.source == "https://stats.example/fighter")
    }
}
