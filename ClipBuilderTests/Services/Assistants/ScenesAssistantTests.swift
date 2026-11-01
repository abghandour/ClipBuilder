import Testing
@testable import Clip_Builder

@Suite("Scenes assistant")
struct ScenesAssistantTests {
    private func context(_ edit: (inout ScenesAssistant.Snapshot) -> Void = { _ in }) -> AssistantContext {
        var s = ScenesAssistant.Snapshot()
        s.sceneCount = 12
        s.visible = 12
        s.favorites = 2
        edit(&s)
        return ScenesAssistant.context(s)
    }

    private func ids(_ context: AssistantContext) -> [String] {
        ScenesAssistant().suggestions(for: context).map(\.id)
    }

    @Test func quietOnASmallLibrary() {
        #expect(ids(context()).isEmpty)
    }

    @Test func noScenesPointsToSources() {
        let rows = ScenesAssistant().suggestions(for: context { $0.sceneCount = 0; $0.visible = 0 })
        #expect(rows.map(\.id) == ["scenes.analyze.none"])
        #expect(rows.first?.actionID == "scenes.goto.sources")
    }

    @Test func filterHidingMostScenesSuggestsClearing() {
        let rows = ScenesAssistant().suggestions(for: context { $0.visible = 3; $0.tag = "fight" ; $0.filtersActive = true })
        #expect(rows.map(\.id) == ["scenes.filter.active"])
        #expect(rows.first?.reason == "Filters hide 9 of 12 scenes")
        // A filter that hides little, or a small grid without a filter, stays quiet.
        #expect(ids(context { $0.visible = 10; $0.filtersActive = true }).isEmpty)
        #expect(ids(context { $0.visible = 3 }).isEmpty)
        #expect(ids(context { $0.visible = 3; $0.searchText = "jon" }) == ["scenes.filter.active"])
    }

    @Test func manyScenesWithoutFavoritesSuggestsAIFavorites() {
        let many = context { $0.sceneCount = 40; $0.visible = 40; $0.favorites = 0; $0.favoriteCandidates = 40; $0.aiSearch = true }
        #expect(ids(many) == ["scenes.favorites.none"])
        #expect(!ids(context { $0.sceneCount = 40; $0.visible = 40; $0.favorites = 0; $0.aiSearch = true }).contains("scenes.favorites.none"))
        #expect(!ids(context { $0.sceneCount = 20; $0.visible = 20; $0.favorites = 0; $0.favoriteCandidates = 20 }).contains("scenes.favorites.none"))
    }

    @Test func scoredScenesInTimeOrderSuggestSort() {
        let rows = ScenesAssistant().suggestions(for: context { $0.sceneCount = 40; $0.visible = 40; $0.scored = 25; $0.aiSearch = true })
        #expect(rows.map(\.id) == ["scenes.sort.time"])
        #expect(rows.first?.kind == .setting)
        #expect(ids(context { $0.sceneCount = 40; $0.visible = 40; $0.scored = 25; $0.sortByScore = true; $0.aiSearch = true }).isEmpty)
    }

    @Test func largeLibrarySuggestsSearchUntilASearchRuns() {
        #expect(ids(context { $0.sceneCount = 40; $0.visible = 40 }) == ["scenes.search.example"])
        #expect(ids(context { $0.sceneCount = 40; $0.visible = 40; $0.aiSearch = true }).isEmpty)
    }

    @Test func summaryLine() {
        #expect(context { $0.visible = 5; $0.tag = "fight"; $0.sortByScore = true }.summaryLine
                == "Scenes · 5 of 12 scenes · 2 favorites · fight · top scored")
    }

    @Test func routing() {
        #expect(ScenesAssistant.route("Find scenes about the knockout") == .search("the knockout"))
        #expect(ScenesAssistant.route("show me the walkout") == .search("the walkout"))
        #expect(ScenesAssistant.route("find") == .action("scenes.search"))
        #expect(ScenesAssistant.route("Pick my favorite scenes with AI") == .action("scenes.favorites.ai"))
        // Settings, negations and compound requests go to the AI's settings parser.
        #expect(ScenesAssistant.route("Sort by score and clear the filters") == nil)
        #expect(ScenesAssistant.route("Show only favorites") == nil)
        #expect(ScenesAssistant.route("turn off sort by score") == nil)
        #expect(ScenesAssistant.route("don't sort by score") == nil)
        #expect(ScenesAssistant.route("show me only the favorites") == nil)
        #expect(ScenesAssistant.route("favorites only") == nil)
        #expect(ScenesAssistant.route("clear filters") == .action("scenes.filters.clear"))
        #expect(ScenesAssistant.route("Show all scenes") == .action("scenes.filters.clear"))
        #expect(ScenesAssistant.route("top scored first") == .action("scenes.sort.score"))
        #expect(ScenesAssistant.route("find the knockout and the walkout") == .search("the knockout and the walkout"))
        #expect(ScenesAssistant.route("sort by score") == .action("scenes.sort.score"))
        #expect(ScenesAssistant.route("make a reel from these") == .action("scenes.generate"))
        #expect(ScenesAssistant.route("hello") == nil)
    }
}
