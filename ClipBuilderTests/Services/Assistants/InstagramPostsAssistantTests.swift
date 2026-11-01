import Testing
@testable import Clip_Builder

@Suite("Instagram posts assistant")
struct InstagramPostsAssistantTests {
    private func ids(_ s: InstagramPostsAssistant.Snapshot) -> [String] {
        InstagramPostsAssistant().suggestions(for: InstagramPostsAssistant.context(s)).map(\.id)
    }

    @Test func noAccountSuggestsAddingOne() {
        let rows = InstagramPostsAssistant().suggestions(for: InstagramPostsAssistant.context(.init()))
        #expect(rows.map(\.id) == ["instagram.account.none"])
        #expect(rows.first?.actionID == "instagram.account.add")
    }

    @Test func quietWhenReelsAreStudied() {
        #expect(ids(.init(accounts: 1, account: "me", reels: 20, studied: 5)).isEmpty)
    }

    @Test func noReelsSuggestsFetchingUnlessAFetchRuns() {
        #expect(ids(.init(accounts: 1, account: "me")) == ["instagram.reels.none"])
        #expect(ids(.init(accounts: 1, account: "me", fetching: true)).isEmpty)
    }

    @Test func unstudiedReelsSuggestLearning() {
        let rows = InstagramPostsAssistant().suggestions(for: InstagramPostsAssistant.context(.init(accounts: 1, account: "me", reels: 12)))
        #expect(rows.map(\.id) == ["instagram.taste.unstudied"])
        #expect(rows.first?.actionID == "instagram.learn.top")
        #expect(ids(.init(accounts: 1, account: "me", reels: 3)).isEmpty)
        #expect(ids(.init(accounts: 1, account: "me", reels: 12, studying: true)).isEmpty)
    }

    @Test func tickedReelsSuggestLearningFromThem() {
        #expect(ids(.init(accounts: 1, account: "me", reels: 12, learnSelection: 2)) == ["instagram.learn.selected"])
    }

    @Test func summaryLine() {
        #expect(InstagramPostsAssistant.context(.init(accounts: 1, account: "me", reels: 12, studied: 3)).summaryLine
                == "Posts · @me · 12 reels · Recent · 3 studied")
    }

    @Test func routing() {
        #expect(InstagramPostsAssistant.route("Learn my taste from the top reels") == "instagram.learn.top")
        #expect(InstagramPostsAssistant.route("Refresh this account's reels") == "instagram.refresh")
        #expect(InstagramPostsAssistant.route("Open the best performing reel") == "instagram.reel.top")
        #expect(InstagramPostsAssistant.route("distill what performs") == "instagram.lessons.distill")
        #expect(InstagramPostsAssistant.route("hello") == nil)
    }
}
