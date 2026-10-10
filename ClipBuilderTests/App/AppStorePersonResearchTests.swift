import Foundation
import Testing
@testable import Clip_Builder

extension AppStoreTests {
    private func researchStore(_ database: Database, recorder: PersonResearchRecorder) -> AppStore {
        let profile = Fixtures.brand(name: "Person Research")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: database)
        store.diagnosticLogSink = { _, _ in }
        store.personResearchRunner = { request in await recorder.run(request) }
        return store
    }

    private func finishPersonResearch(_ store: AppStore) async throws {
        for _ in 0..<500 {
            if store.jobs.latest(.personResearch) != nil && !store.jobs.hasLiveTasks { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Person research did not finish")
    }

    @Test("People review researches only newly confirmed people, excluding merged identities")
    func peopleReviewStartsResearch() async throws {
        let temp = try TempDatabase()
        try await temp.database.upsertPerson(key: "new-person", descriptor: "Red gloves")
        try await temp.database.upsertPerson(key: "duplicate", descriptor: "Blue gloves")
        let target = try await temp.database.createPerson(name: "Existing Fighter")
        let recorder = PersonResearchRecorder()
        let store = researchStore(temp.database, recorder: recorder)
        store.applyPeopleReview(names: ["new-person": " Confirmed Fighter ", "duplicate": "Duplicate Name"],
                                merges: ["duplicate": target.id])
        try await finishPersonResearch(store)
        let requests = await recorder.requests
        #expect(requests.map(\.person.key) == ["new-person"])
        #expect(requests.first?.person.name == "Confirmed Fighter")
        #expect(requests.first?.fields == TagTextWriter.profileFields)
        #expect(store.personResearchInFlight.isEmpty)
        #expect(store.jobs.latest(.personResearch)?.result?.needsReview == true)
        #expect(try await temp.database.personTagFields().isEmpty)
    }

    @Test("People pass researches stale existing fighters, excluding fresh, new and non-fighters")
    func peoplePassRefreshesStaleRecords() async throws {
        let temp = try TempDatabase()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var people: [PersonRecord] = []
        for name in ["Stale", "Fresh", "Trainer", "Missing", "New"] {
            var person = try await temp.database.createPerson(name: name)
            person.category = name == "Trainer" ? .trainer : .fighter
            try await temp.database.setPersonCategory(id: person.id, category: person.category)
            if name != "Missing" {
                try await temp.database.savePersonTagField(personKey: person.key, field: "MMA record", value: "10-2-0",
                    provenance: AIProvenance(provider: "claude", at: now.addingTimeInterval(name == "Fresh" ? -60 : -31 * 86400)))
            }
            people.append(person)
        }
        let recorder = PersonResearchRecorder()
        let store = researchStore(temp.database, recorder: recorder)
        let roster = people.map { person in
            VideoPersonRecord(videoID: 1, personID: person.id, key: person.key, name: person.name,
                              descriptor: person.descriptor, portraitAt: 0, portraitBox: nil)
        }
        await store.refreshPersonRecords(roster: roster, existingPeople: Array(people.dropLast()), now: now)
        try await finishPersonResearch(store)
        let requests = await recorder.requests
        #expect(Set(requests.map(\.person.name)) == ["Stale", "Missing"])
        #expect(requests.allSatisfy { $0.fields == ["MMA record"] })
    }

    @Test("Naming an unnamed person starts profile research")
    func namingStartsResearch() async throws {
        let temp = try TempDatabase()
        try await temp.database.upsertPerson(key: "unnamed", descriptor: "Interview guest")
        let person = try #require(try await temp.database.fetchPeople().first)
        let recorder = PersonResearchRecorder()
        let store = researchStore(temp.database, recorder: recorder)
        store.renamePerson(person, to: "Named Guest")
        try await finishPersonResearch(store)
        let requests = await recorder.requests
        #expect(requests.map(\.person.name) == ["Named Guest"])
        #expect(requests.first?.context.contains("Interview guest") == true)
    }

    @Test("Research skips unnamed people and duplicates in an in-flight batch")
    func researchDeduplicates() async throws {
        let temp = try TempDatabase()
        let named = try await temp.database.createPerson(name: "Named Fighter")
        let unnamed = PersonRecord(id: 999, key: "unconfirmed", name: "", descriptor: "")
        let recorder = PersonResearchRecorder()
        let store = researchStore(temp.database, recorder: recorder)
        store.researchPeople([named, named, unnamed], reason: "test")
        store.researchPeople([named], reason: "test duplicate")
        #expect(store.personResearchInFlight == [named.id])
        #expect(store.jobs.running.filter { $0.kind == .personResearch }.count == 1)
        try await finishPersonResearch(store)
        #expect(await recorder.requests.count == 1)
        #expect(store.personResearchInFlight.isEmpty)
    }

    @Test("Stopping research releases the in-flight person and never writes a field")
    func researchCancellation() async throws {
        let temp = try TempDatabase()
        let person = try await temp.database.createPerson(name: "Named Fighter")
        let store = researchStore(temp.database, recorder: PersonResearchRecorder())
        store.personResearchRunner = { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        store.researchPeople([person], reason: "test cancellation")
        let job = try #require(store.jobs.running.first)
        store.jobs.cancel(job.id)
        try await finishPersonResearch(store)
        #expect(store.personResearchInFlight.isEmpty)
        #expect(store.jobs.latest(.personResearch)?.status == .cancelled)
        #expect(try await temp.database.personTagFields().isEmpty)
    }
}

private actor PersonResearchRecorder {
    private(set) var requests: [PersonResearchRequest] = []

    func run(_ request: PersonResearchRequest) -> PersonResearchOutcome {
        requests.append(request)
        let proposal = PersonResearchProposal(personKey: request.person.key, field: request.fields[0], value: "Fixture value",
                                              source: "https://example.com/person", asOf: nil, confidence: 0.9)
        return PersonResearchOutcome(personKey: request.person.key, proposals: [proposal], category: nil, provenance: nil)
    }
}
