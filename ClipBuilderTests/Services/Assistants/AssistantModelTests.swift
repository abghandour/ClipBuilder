import Foundation
import Testing
@testable import Clip_Builder

/// A page with one direct action, one command action and one setting, whose
/// keywords recognize only "run".
private nonisolated struct StubAssistant: PageAssistant {
    let page = "Stub"
    let examples = ["run"]

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        AssistantContext(page: page, facts: [AssistantFact("n", "N", 1)])
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        [AssistantAction(id: "stub.run", title: "Run", systemImage: "play") { _ in .handled("Ran.") },
         .command("stub.cmd", "Open", "rectangle", message: "Opened.")]
    }

    /// One action row the page offers, one insight, and one whose action
    /// the page does not offer (never shown, so never counted as dismissed).
    func suggestions(for context: AssistantContext) -> [AssistantSuggestion] {
        [AssistantSuggestion(id: "stub.run.now", kind: .action, title: "Run it", reason: "It is ready", actionID: "stub.run"),
         AssistantSuggestion(id: "stub.note.x", kind: .insight, title: "Note", reason: "Just so you know"),
         AssistantSuggestion(id: "stub.gone.x", kind: .action, title: "Gone", reason: "Not offered", actionID: "stub.gone")]
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        text == "run" ? .handled("Ran by keyword.") : AssistantText.unrecognized(page: page, examples: examples)
    }

    @MainActor
    func assistSettings(store: AppStore) -> [AssistantSetting] { [AssistantSetting("mode", "Mode", .bool)] }

    @MainActor
    func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        store.assistant.sendSettings(settings, namespace: "stub", message: "Updated.")
    }
}

@MainActor
@Suite("Assistant model", .serialized)
struct AssistantModelTests {
    private func makeStore() -> AppStore {
        let settings = AppSettings()
        let profile = Fixtures.brand(name: "Assistant")
        let store = AppStore(settings: settings, profiles: [profile], active: profile, ai: AIService(config: settings.ai))
        store.diagnosticLogSink = { _, _ in }
        return store
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Assistant model did not reach the expected state")
    }

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The worker did not finish")
    }

    private let rules = [
        AssistantSuggestion(id: "p.a.x", kind: .action, title: "A", reason: "rule A", actionID: "p.run.a"),
        AssistantSuggestion(id: "p.b.x", kind: .setting, title: "B", reason: "rule B", actionID: "p.set.b"),
        AssistantSuggestion(id: "p.c.x", kind: .insight, title: "C", reason: "rule C"),
    ]
    private let catalogue = [PageAssistantPrompt.Action(id: "p.run.a", title: "Run A"),
                             PageAssistantPrompt.Action(id: "p.set.b", title: "Set B"),
                             PageAssistantPrompt.Action(id: "p.extra", title: "Extra")]

    // MARK: - Merge

    @Test func mergeByIdKeepsRuleActionsAndTakesAIReasons() {
        let provenance = AIProvenance(provider: "claude", task: "assist")
        let rows = AssistantModel.rankedRows(reply: """
            {"suggestions": [{"id": "p.b.x", "reason": "AI says B"}, {"id": "invented.id", "reason": "no"},
                             {"id": "p.extra", "reason": "AI adds extra"}, {"id": "p.run.a"}, {"id": "p.set.b"}]}
            """, rules: rules, catalogue: catalogue, provenance: provenance) ?? []
        #expect(rows.map(\.id) == ["p.b.x", "ai.p.extra", "p.a.x"])
        #expect(rows.map(\.reason) == ["AI says B", "AI adds extra", "rule A"])
        #expect(rows.map(\.actionID) == ["p.set.b", "p.extra", "p.run.a"])
        #expect(rows[0].kind == .setting)
        #expect(rows.allSatisfy { $0.provenance == provenance })

        let merged = AssistantModel.merge(rules: rules, ranked: rows, dismissed: [rules[0].dismissKey],
                                          offeredActions: Set(catalogue.map(\.id)))
        #expect(merged.map(\.id) == ["p.b.x", "ai.p.extra", "p.c.x"])
        #expect(merged.last?.provenance == nil)
    }

    @Test func aiCannotInventAnAction() {
        let rows = AssistantModel.rankedRows(reply: #"{"suggestions": [{"id": "p.delete", "reason": "Delete it all"}, {"id": "p.extra"}]}"#,
                                             rules: rules, catalogue: catalogue, provenance: nil)
        // An unknown id is dropped; a catalogue action needs a reason to stand on its own.
        #expect(rows == [])
        let forged = AssistantSuggestion(id: "p.a.x", kind: .action, title: "A", reason: "x", actionID: "p.delete")
        let merged = AssistantModel.merge(rules: [], ranked: [forged], dismissed: [], offeredActions: Set(catalogue.map(\.id)))
        #expect(merged.isEmpty)
        // Not a ranking at all: nil, so it is never cached as one.
        #expect(AssistantModel.rankedRows(reply: "not json", rules: rules, catalogue: catalogue, provenance: nil) == nil)
    }

    // MARK: - Dismiss and restore

    @Test func dismissHidesAndRestoreShowsAgain() throws {
        let suite = "AssistantModelTests.dismiss-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore()
        let profile = store.activeProfile.profileName
        let model = AssistantModel(defaults: defaults)
        let assistant = StubAssistant()
        let context = assistant.context(store: store)
        let actions = assistant.actions(store: store)
        func visible(_ model: AssistantModel) -> [String] {
            model.suggestions(for: assistant, context: context, actions: actions, store: store).map(\.id)
        }
        func hidden(_ model: AssistantModel) -> [String] {
            model.dismissedSuggestions(for: assistant, context: context, actions: actions, store: store).map(\.id)
        }

        #expect(visible(model) == ["stub.run.now", "stub.note.x"])
        #expect(hidden(model).isEmpty)
        let run = try #require(model.suggestions(for: assistant, context: context, actions: actions, store: store).first)

        model.dismiss(run, profileName: profile)
        #expect(visible(model) == ["stub.note.x"])
        #expect(hidden(model) == ["stub.run.now"])
        // Survives a relaunch: a fresh model on the same defaults reads the profile's key.
        #expect(hidden(AssistantModel(defaults: defaults)) == ["stub.run.now"])
        #expect(defaults.stringArray(forKey: AssistantModel.dismissedKey(profileName: profile)) == [run.dismissKey])

        model.restore(run, profileName: profile)
        #expect(visible(model) == ["stub.run.now", "stub.note.x"])
        #expect(hidden(model).isEmpty)
        #expect(defaults.object(forKey: AssistantModel.dismissedKey(profileName: profile)) == nil)
    }

    @Test func dismissedCountIsOnlyThisPagesCurrentRows() throws {
        let suite = "AssistantModelTests.count-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore()
        let profile = store.activeProfile.profileName
        let model = AssistantModel(defaults: defaults)
        let assistant = StubAssistant()
        let context = assistant.context(store: store)
        let actions = assistant.actions(store: store)
        func count() -> Int {
            model.dismissedSuggestions(for: assistant, context: context, actions: actions, store: store).count
        }

        let rows = assistant.suggestions(for: context)
        let (run, note, gone) = (rows[0], rows[1], rows[2])
        let elsewhere = AssistantSuggestion(id: "express.captions.on", kind: .setting, title: "Captions", reason: "r")
        // Another page's id, a rule whose action is not offered, and another profile do not count.
        model.dismiss(elsewhere, profileName: profile)
        model.dismiss(gone, profileName: profile)
        model.dismiss(note, profileName: "Someone else")
        #expect(count() == 0)
        model.dismiss(note, profileName: profile)
        #expect(count() == 1)
        model.dismiss(run, profileName: profile)
        #expect(count() == 2)
        model.restore(note, profileName: profile)
        #expect(count() == 1)
        // Restoring one row leaves the other dismissed rows alone.
        #expect(model.dismissed(profileName: profile) == [elsewhere.dismissKey, gone.dismissKey, run.dismissKey])
        // The same id with another reason is not the dismissed row.
        var changed = note
        changed.reason = "Something new"
        changed.reasonKey = "Something new"
        model.dismiss(note, profileName: profile)
        #expect(AssistantModel.merge(rules: [changed], ranked: nil, dismissed: model.dismissed(profileName: profile))
                .map(\.id) == ["stub.note.x"])

        // Pure core: rows the five-row cap would hide still count.
        let many = (0..<7).map { AssistantSuggestion(id: "p.r\($0)", kind: .insight, title: "R\($0)", reason: "r") }
        #expect(AssistantModel.dismissedRows(rules: many, ranked: nil,
                                             dismissed: [many[6].dismissKey, many[0].dismissKey, "other"]).map(\.id)
                == ["p.r0", "p.r6"])
        #expect(AssistantModel.dismissedRows(rules: many, ranked: nil, dismissed: []).isEmpty)
    }

    // MARK: - Refresh

    @Test func refreshCachesPerFingerprint() async {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "AssistantModelTests.cache")!)
        let context = AssistantContext(page: "P", facts: [AssistantFact("n", "N", 1)])
        let calls = Counter()
        let call: AssistantModel.AssistCall = { _ in
            await calls.bump()
            return AIResponse(text: #"{"suggestions": [{"id": "p.c.x"}, {"id": "p.a.x"}]}"#, provider: "claude",
                              model: nil, task: "assist", fellBack: false)
        }
        await model.refresh(context: context, rules: rules, catalogue: catalogue, call: call)?.value
        #expect(model.rankings[context.fingerprint]?.map(\.id) == ["p.c.x", "p.a.x"])
        #expect(!model.isRefreshing)
        #expect(model.refresh(context: context, rules: rules, catalogue: catalogue, call: call) == nil)
        #expect(await calls.value == 1)
    }

    @Test func staleFingerprintIsDiscarded() async {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "AssistantModelTests.stale")!)
        let old = AssistantContext(page: "P", facts: [AssistantFact("n", "N", 1)])
        let new = AssistantContext(page: "P", facts: [AssistantFact("n", "N", 2)])
        let slow: AssistantModel.AssistCall = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return AIResponse(text: #"{"suggestions": [{"id": "p.a.x"}]}"#, provider: "claude", model: nil,
                              task: "assist", fellBack: false)
        }
        let fast: AssistantModel.AssistCall = { _ in
            AIResponse(text: #"{"suggestions": [{"id": "p.b.x"}]}"#, provider: "claude", model: nil,
                       task: "assist", fellBack: false)
        }
        let first = model.refresh(context: old, rules: rules, catalogue: catalogue, call: slow)
        let second = model.refresh(context: new, rules: rules, catalogue: catalogue, call: fast)
        await first?.value
        await second?.value
        #expect(model.rankings[old.fingerprint] == nil)
        #expect(model.rankings[new.fingerprint]?.map(\.id) == ["p.b.x"])
    }

    @Test func timeoutFallsBackToRules() async {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "AssistantModelTests.timeout")!)
        model.assistTimeout = .milliseconds(30)
        let context = AssistantContext(page: "P", facts: [AssistantFact("n", "N", 3)])
        let hang: AssistantModel.AssistCall = { _ in
            try await Task.sleep(for: .seconds(30))
            return AIResponse(text: "{}", provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        let started = ContinuousClock.now
        await model.refresh(context: context, rules: rules, catalogue: catalogue, call: hang)?.value
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!model.isRefreshing)
        // Nothing cached: the rules stand, and the next refresh (reopening the popover) asks again.
        #expect(model.rankings[context.fingerprint] == nil)
        #expect(AssistantModel.merge(rules: rules, ranked: model.rankings[context.fingerprint], dismissed: []).map(\.id)
                == rules.map(\.id))
        let retry = model.refresh(context: context, rules: rules, catalogue: catalogue, call: { _ in
            AIResponse(text: #"{"suggestions": [{"id": "p.c.x"}]}"#, provider: "claude", model: nil, task: "assist", fellBack: false)
        })
        #expect(retry != nil)
        await retry?.value
        #expect(model.rankings[context.fingerprint]?.map(\.id) == ["p.c.x"])
    }

    @Test func failedRankingsAreNotCached() async {
        let model = AssistantModel(defaults: UserDefaults(suiteName: "AssistantModelTests.failures")!)
        let context = AssistantContext(page: "P", facts: [AssistantFact("n", "N", 4)])
        let calls = Counter()
        let failing: AssistantModel.AssistCall = { _ in
            await calls.bump()
            throw AIError.unusableResponse("provider down")
        }
        await model.refresh(context: context, rules: rules, catalogue: catalogue, call: failing)?.value
        #expect(model.rankings[context.fingerprint] == nil)
        let unreadable: AssistantModel.AssistCall = { _ in
            await calls.bump()
            return AIResponse(text: "Sorry, I can't help.", provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        await model.refresh(context: context, rules: rules, catalogue: catalogue, call: unreadable)?.value
        #expect(model.rankings[context.fingerprint] == nil)
        #expect(!model.isRefreshing)
        // Each failure retried; a parsed (even empty) ranking is what sticks.
        let empty: AssistantModel.AssistCall = { _ in
            await calls.bump()
            return AIResponse(text: #"{"suggestions": []}"#, provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        await model.refresh(context: context, rules: rules, catalogue: catalogue, call: empty)?.value
        #expect(model.rankings[context.fingerprint] == [])
        #expect(model.refresh(context: context, rules: rules, catalogue: catalogue, call: empty) == nil)
        #expect(await calls.value == 3)
    }

    // MARK: - Deadline

    @Test func deadlineDoesNotWaitForAWorkerSlowToCancel() async {
        let finished = Counter()
        let started = ContinuousClock.now
        do {
            _ = try await AssistantModel.withTimeout(.milliseconds(40)) {
                await ignoringCancellation(for: .milliseconds(600))
                await finished.bump()
                return 1
            }
            Issue.record("Expected a timeout")
        } catch {
            #expect(error is AssistantModel.TimedOut)
        }
        // Back at the deadline, not when the worker finally stops.
        #expect(ContinuousClock.now - started < .milliseconds(450))
        #expect(await finished.value == 0)
        // A fast worker still wins.
        let value = try? await AssistantModel.withTimeout(.seconds(5)) { 7 }
        #expect(value == 7)
    }

    // MARK: - Free text

    @Test func keywordMatchesNeverAskTheAI() {
        let store = makeStore()
        store.assistant.assistCall = { _ in
            Issue.record("The AI was asked")
            return AIResponse(text: "{}", provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        #expect(store.assistant.send("run", assistant: StubAssistant(), store: store) == .handled("Ran by keyword."))
    }

    @Test func unknownActionIsRefused() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in assistReply(#"{"action": "stub.delete", "settings": {}, "reply": "Deleted."}"#) }
        let outcome = store.assistant.send("delete everything", assistant: StubAssistant(), store: store)
        #expect(outcome == .pending(AssistantModel.askingMessage))
        #expect(store.assistant.isAsking("Stub"))
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(store.assistant.lastOutcome["Stub"] == .unavailable("Ask AI picked an action this page does not offer."))
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func unknownSettingKeyIsRefused() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in assistReply(#"{"action": null, "settings": {"volume": 11}, "reply": "Louder."}"#) }
        store.assistant.send("louder", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(store.assistant.lastOutcome["Stub"] == .unavailable("Ask AI cannot change “volume” on this page."))
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func answerAppliesSettingsThenRunsTheAction() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in assistReply(#"{"action": "stub.run", "settings": {"mode": "on"}, "reply": "Mode on, ran."}"#) }
        store.assistant.send("switch mode on and go", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(store.assistant.lastOutcome["Stub"] == .handled("Mode on, ran."))
        #expect(store.assistant.pendingCommand?.actionID == "stub.settings")
        #expect(store.assistant.pendingCommand?.settings == ["mode": "true"])
        #expect(store.assistant.closeRequest != nil)
    }

    @Test func aCommandActionCarriesTheSettingsPatch() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in assistReply(#"{"action": "stub.cmd", "settings": {"mode": false}, "reply": ""}"#) }
        store.assistant.send("open it without mode", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        // One command slot: the page gets the action with the patch on it.
        #expect(store.assistant.pendingCommand?.actionID == "stub.cmd")
        #expect(store.assistant.pendingCommand?.settings == ["mode": "false"])
        #expect(store.assistant.lastOutcome["Stub"] == .handled("Opened."))
    }

    @Test func typedRequestDeadlineIgnoresASlowWorkerAndItsLateAnswer() async throws {
        let store = makeStore()
        store.assistant.assistTimeout = .milliseconds(40)
        let late = Counter()
        store.assistant.assistCall = { _ in
            // Like ProcessRunner: keeps running well after it is cancelled, then answers.
            await ignoringCancellation(for: .milliseconds(500))
            await late.bump()
            return assistReply(#"{"action": "stub.cmd", "settings": {}, "reply": "Late."}"#)
        }
        let started = ContinuousClock.now
        store.assistant.send("something odd", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(ContinuousClock.now - started < .milliseconds(400))
        let unrecognized = AssistantText.unrecognized(page: "Stub", examples: ["run"])
        #expect(store.assistant.lastOutcome["Stub"] == unrecognized)
        // The worker answers later; nothing it says is applied.
        try await waitUntilAsync { await late.value == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.assistant.lastOutcome["Stub"] == unrecognized)
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func aNewerRequestRejectsTheOlderAnswer() async throws {
        let store = makeStore()
        let answers = Counter()
        store.assistant.assistCall = { prompt in
            if prompt.contains("alpha-request") {
                await ignoringCancellation(for: .milliseconds(150))
                await answers.bump()
                return assistReply(#"{"action": "stub.cmd", "settings": {}, "reply": "First."}"#)
            }
            return assistReply(#"{"action": "stub.run", "settings": {}, "reply": "Second."}"#)
        }
        store.assistant.send("alpha-request", assistant: StubAssistant(), store: store)
        store.assistant.send("beta-request", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(store.assistant.lastOutcome["Stub"] == .handled("Second."))
        try await waitUntilAsync { await answers.value == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.assistant.lastOutcome["Stub"] == .handled("Second."))
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func anAnswerForAChangedPageIsDropped() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in
            try await Task.sleep(for: .milliseconds(80))
            return assistReply(#"{"action": "stub.cmd", "settings": {"mode": true}, "reply": "Done."}"#)
        }
        store.assistant.send("do the thing", assistant: StateStub(), store: store)
        #expect(store.assistant.isAsking(StateStub.pageName))
        // The selection (and so the context fingerprint) changes while the AI thinks.
        store.assistant.updatePageState(StateStub.pageName, AssistantPageState(counts: ["n": 2], selection: []))
        try await waitUntil { !store.assistant.isAsking(StateStub.pageName) }
        #expect(store.assistant.lastOutcome[StateStub.pageName] == .unavailable(AssistantModel.staleMessage))
        #expect(store.assistant.pendingCommand == nil)
        #expect(store.assistant.closeRequest == nil)
    }

    @Test func anAnswerAfterAProjectSwitchIsDropped() async throws {
        let store = makeStore()
        store.assistant.assistCall = { _ in
            try await Task.sleep(for: .milliseconds(80))
            return assistReply(#"{"action": "stub.cmd", "settings": {}, "reply": "Done."}"#)
        }
        store.assistant.send("do the thing", assistant: StateStub(), store: store)
        store.activeProjectID = 4242
        try await waitUntil { !store.assistant.isAsking(StateStub.pageName) }
        #expect(store.assistant.lastOutcome[StateStub.pageName] == .unavailable(AssistantModel.staleMessage))
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func requestTokenChecksEveryPart() {
        let token = AssistRequestToken(page: "P", profileGeneration: 3, projectID: 7, fingerprint: "abc")
        #expect(token.isCurrent(latest: token, profileGeneration: 3, projectID: 7, fingerprint: "abc"))
        #expect(!token.isCurrent(latest: AssistRequestToken(page: "P", profileGeneration: 3, projectID: 7, fingerprint: "abc"),
                                 profileGeneration: 3, projectID: 7, fingerprint: "abc"))
        #expect(!token.isCurrent(latest: nil, profileGeneration: 3, projectID: 7, fingerprint: "abc"))
        #expect(!token.isCurrent(latest: token, profileGeneration: 4, projectID: 7, fingerprint: "abc"))
        #expect(!token.isCurrent(latest: token, profileGeneration: 3, projectID: 8, fingerprint: "abc"))
        #expect(!token.isCurrent(latest: token, profileGeneration: 3, projectID: 7, fingerprint: "abd"))
    }

    // MARK: - Page commands

    @Test func commandsGoOnlyToTheirNamespace() {
        let express = AssistantCommand(actionID: "wizard.generate", namespace: "express")
        #expect(express.belongs(to: "express."))
        #expect(!express.belongs(to: "full."))
        #expect(!express.belongs(to: "wizard."))
        let scenes = AssistantCommand(actionID: "scenes.sort.score")
        #expect(scenes.belongs(to: "scenes."))
        #expect(!scenes.belongs(to: "sources."))
        #expect(AssistantCommand(actionID: "express.settings").belongs(to: "express."))
    }

    @Test func aPageCommandWithASettingsPatchIsJudgedByThePage() async throws {
        let store = makeStore()
        // Unavailable in the current state; the patch may change that, so the page decides.
        store.assistant.assistCall = { _ in assistReply(#"{"action": "state.cmd", "settings": {"mode": true}, "reply": ""}"#) }
        store.assistant.send("switch mode and open", assistant: StateStub(), store: store)
        try await waitUntil { !store.assistant.isAsking(StateStub.pageName) }
        #expect(store.assistant.pendingCommand?.actionID == "state.cmd")
        #expect(store.assistant.pendingCommand?.settings == ["mode": "true"])
        // Without a patch the action's own availability still applies.
        store.assistant.pendingCommand = nil
        store.assistant.assistCall = { _ in assistReply(#"{"action": "state.cmd", "settings": {}, "reply": ""}"#) }
        store.assistant.send("open", assistant: StateStub(), store: store)
        try await waitUntil { !store.assistant.isAsking(StateStub.pageName) }
        #expect(store.assistant.pendingCommand == nil)
    }

    @Test func aFailedCallKeepsTheUnrecognizedOutcome() async throws {
        let store = makeStore()
        store.assistant.assistTimeout = .milliseconds(30)
        store.assistant.assistCall = { _ in
            try await Task.sleep(for: .seconds(30))
            return AIResponse(text: "{}", provider: "claude", model: nil, task: "assist", fellBack: false)
        }
        store.assistant.send("something odd", assistant: StubAssistant(), store: store)
        try await waitUntil { !store.assistant.isAsking("Stub") }
        #expect(store.assistant.lastOutcome["Stub"] == AssistantText.unrecognized(page: "Stub", examples: ["run"]))
    }
}

private func assistReply(_ text: String) -> AIResponse {
    AIResponse(text: text, provider: "claude", model: "claude-sonnet-5-5", task: AITask.assist.rawValue, fellBack: false)
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Waits `duration` without noticing cancellation, like a process runner
/// that waits for its child to exit after being told to stop.
private func ignoringCancellation(for duration: Duration) async {
    let nanoseconds = duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { continuation.resume() }
    }
}

/// A page whose context is its published state (count "n" and the
/// selection), with one command that is never available on its own.
private nonisolated struct StateStub: PageAssistant {
    static let pageName = "StateStub"
    let page = Self.pageName
    let examples: [String] = []

    @MainActor
    func context(store: AppStore) -> AssistantContext {
        let state = store.assistant.state(page)
        return AssistantContext(page: page, facts: [AssistantFact("n", "N", state.count("n"))], selection: state.selection ?? [])
    }

    @MainActor
    func actions(store: AppStore) -> [AssistantAction] {
        [.command("state.cmd", "Open", "rectangle", message: "Opened.", available: { _ in false }),
         .command("stub.cmd", "Other", "rectangle", message: "Opened other.")]
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        AssistantText.unrecognized(page: page, examples: examples)
    }

    @MainActor
    func assistSettings(store: AppStore) -> [AssistantSetting] { [AssistantSetting("mode", "Mode", .bool)] }

    @MainActor
    func apply(settings: [String: String], store: AppStore) -> AskAIOutcome {
        store.assistant.sendSettings(settings, namespace: "state", message: "Updated.")
    }
}

@Suite("Assistant model: final review fixes")
struct AssistantModelReviewFixTests {
    @Test func pageSwitchMakesATokenStale() {
        let token = AssistRequestToken(page: "Scenes", profileGeneration: 1, projectID: 7, fingerprint: "f", navigation: 3)
        #expect(token.isCurrent(latest: token, profileGeneration: 1, projectID: 7, fingerprint: "f", navigation: 3))
        #expect(!token.isCurrent(latest: token, profileGeneration: 1, projectID: 7, fingerprint: "f", navigation: 4))
    }

    @Test func fingerprintCoversTheWholeSelection() {
        let base = (0..<20).map { "item\($0)" }
        let a = AssistantContext(page: "Scenes", selection: base + ["tail-a"])
        let b = AssistantContext(page: "Scenes", selection: base + ["tail-b"])
        #expect(a.selection == b.selection, "the shown prefix is the same")
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test func aiOnlyRowsKeepTheirDismissKeyWhenRephrased() {
        let catalogue = [PageAssistantPrompt.Action(id: "p.go", title: "Go")]
        let first = AssistantModel.rankedRows(reply: #"{"suggestions": [{"id": "p.go", "reason": "Because A"}]}"#,
                                              rules: [], catalogue: catalogue, provenance: nil, fingerprint: "ctx")
        let second = AssistantModel.rankedRows(reply: #"{"suggestions": [{"id": "p.go", "reason": "Because B"}]}"#,
                                               rules: [], catalogue: catalogue, provenance: nil, fingerprint: "ctx")
        #expect(first?.first?.dismissKey == second?.first?.dismissKey)
        let other = AssistantModel.rankedRows(reply: #"{"suggestions": [{"id": "p.go", "reason": "Because A"}]}"#,
                                              rules: [], catalogue: catalogue, provenance: nil, fingerprint: "other")
        #expect(first?.first?.dismissKey != other?.first?.dismissKey)
    }
}
