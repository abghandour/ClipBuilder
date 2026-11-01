import Foundation
import Testing
@testable import Clip_Builder

@Suite("Exports assistant")
struct ExportsAssistantTests {
    private func context(_ edit: (inout ExportsAssistant.Snapshot) -> Void = { _ in }) -> AssistantContext {
        var s = ExportsAssistant.Snapshot()
        s.total = 3
        s.shown = 3
        s.hookGroups = 1
        edit(&s)
        return ExportsAssistant.context(s)
    }

    private func ids(_ context: AssistantContext) -> [String] {
        ExportsAssistant().suggestions(for: context).map(\.id)
    }

    @Test func quietWhenEveryVideoIsDone() {
        #expect(ids(context()).isEmpty)
    }

    @Test func noExportsPointsToTheWizard() {
        let rows = ExportsAssistant().suggestions(for: context { $0.total = 0; $0.shown = 0 })
        #expect(rows.map(\.id) == ["exports.none.empty"])
        #expect(rows.first?.actionID == "exports.goto.wizard")
    }

    @Test func emptyFolderIsQuiet() {
        #expect(ids(context { $0.shown = 0; $0.withoutCover = 2 }).isEmpty)
    }

    @Test func eachGapFiresItsSuggestion() {
        #expect(ids(context { $0.flagged = 1 }) == ["exports.flags.pending"])
        #expect(ids(context { $0.unpublished = 2 }) == ["exports.publish.ready"])
        #expect(ids(context { $0.withoutCover = 1 }) == ["exports.cover.missing"])
        #expect(ids(context { $0.withoutText = 1 }) == ["exports.text.missing"])
        #expect(ids(context { $0.hookGroups = 0 }) == ["exports.hooks.none"])
    }

    @Test func suggestionsRunTheCardActions() {
        let rows = ExportsAssistant().suggestions(for: context {
            $0.flagged = 1; $0.unpublished = 1; $0.withoutCover = 1; $0.withoutText = 1; $0.hookGroups = 0
        })
        #expect(rows.map(\.actionID) == ["exports.flags", "exports.publish", "exports.cover", "exports.text", "exports.builder"])
    }

    @Test func tallyCountsGapsAndPicksTheNewestTargets() {
        var a = Fixtures.generatedVideo(id: 3)
        a.coverTime = 1
        a.caption = "Hi"
        a.instagramMediaID = "ig"
        var b = Fixtures.generatedVideo(id: 2)
        b.variantGroupID = "g"
        var c = Fixtures.generatedVideo(id: 1)
        c.variantGroupID = "g"
        let tally = ExportsAssistant.tally([a, b, c])
        #expect(tally.counts["shown"] == 3)
        #expect(tally.counts["cover.missing"] == 2)
        #expect(tally.counts["text.missing"] == 2)
        #expect(tally.counts["unpublished"] == 2)
        #expect(tally.counts["hookGroups"] == 1)
        #expect(tally.counts["flagged"] == 0)
        #expect(tally.targets.newest == 3)
        #expect(tally.targets.cover == 2)
        #expect(tally.targets.noText == 2)
        #expect(tally.targets.publish == 2)
        #expect(tally.targets.hooks == 2)
        #expect(tally.targets.flagged == nil)
    }

    @Test func summaryLine() {
        #expect(context { $0.folder = "October"; $0.unpublished = 2 }.summaryLine
                == "Exports · October · 3 of 3 videos · Newest · 2 ready to publish")
    }

    @Test func routing() {
        // "Newest/latest" names the newest video itself, not the newest one with a gap.
        #expect(ExportsAssistant.route("Publish the newest one") == "exports.publish.newest")
        #expect(ExportsAssistant.route("Pick a cover frame for the latest video") == "exports.cover.newest")
        #expect(ExportsAssistant.route("write post text for the most recent export") == "exports.text.newest")
        #expect(ExportsAssistant.route("publish one that is ready") == "exports.publish")
        #expect(ExportsAssistant.route("pick a cover frame") == "exports.cover")
        #expect(ExportsAssistant.route("Write post text for videos without a caption") == "exports.text")
        #expect(ExportsAssistant.route("compare the hooks") == "exports.hooks.compare")
        #expect(ExportsAssistant.route("open it in the builder") == "exports.builder")
        #expect(ExportsAssistant.route("hello") == nil)
    }

    @Test func newestRequestsSayWhyInsteadOfSubstituting() {
        #expect(ExportsAssistant.newestProblem("exports.publish.newest", name: "a.mp4", published: true, publishable: true)
                == "The newest video, a.mp4, is already on Instagram.")
        #expect(ExportsAssistant.newestProblem("exports.publish.newest", name: "a.mp4", published: false, publishable: false)?
                    .contains("quality checks") == true)
        #expect(ExportsAssistant.newestProblem("exports.publish.newest", name: "a.mp4", published: false, publishable: true) == nil)
        #expect(ExportsAssistant.newestProblem("exports.cover.newest", name: "a.mp4", published: true, publishable: false) == nil)
    }

    @MainActor
    private func makeStore() -> AppStore {
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "ExportsAssistantTests")
        let store = AppStore(settings: settings, profiles: [profile], active: profile, ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        return store
    }

    @MainActor
    @Test func publishNewestRefusesAPublishedNewestVideo() {
        let store = makeStore()
        store.assistant.updatePageState(ExportsAssistant.pageName, AssistantPageState(
            flags: ["newest.published": true, "newest.publishable": true],
            values: ["target.newest": "5", "target.publish": "3", "newest": "new.mp4"]))
        #expect(ExportsAssistant().handle("Publish the newest one", store: store)
                == .unavailable("The newest video, new.mp4, is already on Instagram."))
        #expect(store.assistant.pendingCommand == nil)
        // The gap request still opens the older ready video, through the page.
        #expect(ExportsAssistant().handle("publish one that is ready", store: store) == .handled("Opened Publish."))
        #expect(store.assistant.pendingCommand?.actionID == "exports.publish")
    }

    @MainActor
    @Test func everyExportsActionIsResolvedByThePage() {
        let store = makeStore()
        // Post text included: a folder change in the same answer must reach it first.
        let pageActions = ExportsAssistant().actions(store: store).filter { $0.id != "exports.goto.wizard" }
        #expect(pageActions.allSatisfy { $0.handledByPage })
        store.assistant.updatePageState(ExportsAssistant.pageName, AssistantPageState(values: ["target.noText": "2"]))
        #expect(ExportsAssistant().handle("write post text", store: store) == .handled("Writing post text."))
        #expect(store.assistant.pendingCommand?.actionID == "exports.text")
    }

    @MainActor
    @Test func folderChangeAndPostTextAreOneCommandForThePage() async throws {
        let store = makeStore()
        // The current folder has no video without text; the answer switches folders first.
        store.assistant.updatePageState(ExportsAssistant.pageName, AssistantPageState(
            values: ["folders": ExportsAssistant.encodeFolders([("all", "All"), ("oct", "October")]), "target.noText": ""]))
        store.assistant.assistCall = { _ in
            AIResponse(text: #"{"action": "exports.text", "settings": {"selectedFolder": "oct"}, "reply": "Writing it."}"#,
                       provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        #expect(ExportsAssistant.route("the october ones need words") == nil)
        store.assistant.send("the october ones need words", assistant: ExportsAssistant(), store: store)
        for _ in 0..<400 where store.assistant.isAsking(ExportsAssistant.pageName) {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Nothing ran against the old folder: the page gets the action with the folder on it.
        #expect(store.assistant.pendingCommand?.actionID == "exports.text")
        #expect(store.assistant.pendingCommand?.settings == ["selectedFolder": "oct"])
        #expect(store.assistant.lastOutcome[ExportsAssistant.pageName] == .handled("Writing it."))
    }
}
