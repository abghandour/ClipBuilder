import Testing
@testable import Clip_Builder

struct FightNameResolverTests {
    @Test func repeatLookupReusesPlan() {
        let row = FightResearchRecord(id: 1, videoID: 1,
            fightLabel: "Ana Silva vs Jo Smith", event: "Event", fightDate: "2026-09-07",
            summaryJSON: #"{"query_plan":{"queries":["Ana Silva vs Jo Smith reaction"],"subreddits":["MMA"]}}"#,
            sourcesJSON: "[]", researchedAt: nil, provider: nil, model: nil)
        let result = FightNameResolver.savedPlan(for: ["Ana Silva", "Jo Smith"], records: [row])
        #expect(result?.queries == ["Ana Silva vs Jo Smith reaction"])
        #expect(result?.subreddits == ["MMA"])
        #expect(FightNameResolver.savedPlan(for: ["Ana Silva", "Somebody Else"], records: [row]) == nil)
    }
    @Test func names() {
        #expect(FightNameResolver.resolve("Jan Blachowicz", known: ["Jan Blachowicz"]).resolved)
        #expect(FightNameResolver.resolve("Jan Blachowics", known: ["Jan Blachowicz"]).name == "Jan Blachowicz")
        #expect(FightNameResolver.resolve("Unknown Person", known: ["Jan Blachowicz"]).name == "Unknown Person")
        #expect(!FightNameResolver.resolve("Unknown Person", known: ["Jan Blachowicz"]).resolved)
    }
}

extension FightNameResolverTests {
    @Test func savedPlanNeedsBothQueryListsAndTheSameFighters() {
        func record(_ label: String, _ summary: String) -> FightResearchRecord {
            FightResearchRecord(id: 1, videoID: 1, fightLabel: label, event: "", fightDate: "",
                summaryJSON: summary, sourcesJSON: "[]", researchedAt: nil, provider: nil, model: nil)
        }
        let fighters = ["Ana Silva", "Jo Smith"]
        #expect(FightNameResolver.savedPlan(for: fighters, records: [record("Ana Silva vs Jo Smith", #"{"query_plan":{"queries":["q"]}}"#)]) == nil)
        #expect(FightNameResolver.savedPlan(for: fighters, records: [record("Ana Silva vs Jo Smith", #"{"query_plan":{"queries":[],"subreddits":["MMA"]}}"#)]) == nil)
        #expect(FightNameResolver.savedPlan(for: fighters, records: [record("Ana Silva vs Jo Smith", "{}")]) == nil)
        // Order and accents do not matter; a third fighter does.
        let plan = #"{"query_plan":{"queries":["q"],"subreddits":["MMA"]}}"#
        #expect(FightNameResolver.savedPlan(for: ["jo smith", "ANA SÍLVA"], records: [record("Ana Silva vs Jo Smith", plan)])?.queries == ["q"])
        #expect(FightNameResolver.savedPlan(for: fighters, records: [record("Ana Silva vs Jo Smith vs X", plan)]) == nil)
        #expect(FightNameResolver.savedPlan(for: fighters, records: []) == nil)
    }
    @Test func nameSplittingAndResolutionEdges() {
        #expect(FightNameResolver.names("  Ana Silva vs  Jo Smith ") == ["Ana Silva", "Jo Smith"])
        #expect(FightNameResolver.names("Ana Silva") == ["Ana Silva"])
        #expect(FightNameResolver.names("") == [])
        #expect(FightNameResolver.resolve("Ana", known: []).name == "Ana")
        #expect(!FightNameResolver.resolve("Ana", known: ["", "   "]).resolved)
        // A different person with a similar surname must not be "corrected".
        #expect(!FightNameResolver.resolve("Jan Silva", known: ["Ana Silva"]).resolved)
        #expect(FightNameResolver.resolve("ana silva", known: ["Ana Silva"]).name == "Ana Silva")
    }
}
