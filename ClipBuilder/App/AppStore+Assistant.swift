import Foundation
import Observation
import Synchronization

/// A suggestion or action that needs the page's own form state (Express's
/// settings and flow, the full Wizard's cards). The visible page consumes
/// and clears it, like `pendingWizardAssistantRequest`.
nonisolated struct AssistantCommand: Equatable, Sendable {
    var id = UUID()
    var actionID: String
    var text: String?
    /// A validated Ask AI settings patch (Phase 3) the page applies before
    /// running `actionID`; `actionID` is "<page>.settings" when there is
    /// no action. Keys and values come from the page's `assistSettings`.
    var settings: [String: String]?
    /// The rough cut sheet's Apply and Generate: the Overlays tab's choices
    /// Express adopts along with the framing in `text`.
    var expressOverlays: MiniWizardSettings?
    /// The view that consumes it, as its handler prefix without the dot
    /// ("express", "full"). Nil: the action id's own prefix decides. The AI
    /// Wizard's `wizard.*` ids name Express or Full here, so a command sent
    /// in one mode is never run by the other.
    var namespace: String?

    nonisolated static func settingsID(_ namespace: String) -> String { "\(namespace).settings" }
    var isSettingsOnly: Bool { actionID.hasSuffix(".settings") }

    /// True when the handler registered for `prefix` ("sources.") owns it.
    func belongs(to prefix: String) -> Bool {
        if let namespace { return "\(namespace)." == prefix }
        return actionID.hasPrefix(prefix)
    }
}

/// One typed Ask AI request at the AI: the page, profile, project and
/// context it was asked against. The answer applies only while it is still
/// the page's latest request and all of those are unchanged.
nonisolated struct AssistRequestToken: Equatable, Sendable {
    var id = UUID()
    var page: String
    var profileGeneration: Int
    var projectID: Int64?
    var fingerprint: String
    /// `AssistantModel.navigationGeneration` when the request was sent: a
    /// page switch while the AI thinks makes the answer stale even if the
    /// originating page's context would still match.
    var navigation: Int = 0

    /// Pure check behind `AssistantModel.understand`.
    func isCurrent(latest: AssistRequestToken?, profileGeneration: Int, projectID: Int64?, fingerprint: String,
                   navigation: Int? = nil) -> Bool {
        latest?.id == id && self.profileGeneration == profileGeneration && self.projectID == projectID
            && self.fingerprint == fingerprint && (navigation == nil || navigation == self.navigation)
    }
}

/// First result wins and resumes the waiter exactly once; later results are
/// dropped. Lets `AssistantModel.withTimeout` return at its deadline
/// without waiting for a worker that is slow to honor cancellation.
private nonisolated final class FirstResultGate<T: Sendable>: Sendable {
    private struct State {
        var finished = false
        var result: Result<T, any Error>?
        var waiter: CheckedContinuation<T, any Error>?
    }
    private let state = Mutex(State())

    func finish(_ result: Result<T, any Error>) {
        let waiter: CheckedContinuation<T, any Error>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.result = result
            return nil
        }
        waiter?.resume(with: result)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, any Error>? = state.withLock { state in
                if let result = state.result {
                    state.result = nil
                    return result
                }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Ask AI state shared by every page (docs/Page-Assistant-Plan.md):
/// published page state, the last outcome per page, dismissed suggestions
/// (per profile, in UserDefaults), the ⌘⇧A open request and the page
/// commands. Suggestions are rule-based and instant; `refresh` asks
/// `AITask.assist` to rank them (a parsed ranking is cached per context
/// fingerprint for the session; a failure is not, so the next popover open
/// tries again), and `send` falls back to the AI when a page's keywords
/// miss. Both calls are short Tasks owned by the model, not AppJobs, and
/// finish by `assistTimeout` whatever the worker does.
@Observable
final class AssistantModel {
    nonisolated static let suggestionLimit = 5
    nonisolated static let defaultTimeout: Duration = .seconds(12)
    /// A typed request carries the page's whole settings whitelist and its
    /// reading rules; the CLI-backed providers need longer than a ranking.
    nonisolated static let understandTimeout: Duration = .seconds(45)

    /// One `AITask.assist` call: prompt in, reply out. Injected by tests;
    /// nil uses `store.ai`.
    typealias AssistCall = @Sendable (String) async throws -> AIResponse

    var pageState: [String: AssistantPageState] = [:]
    var lastOutcome: [String: AskAIOutcome] = [:]
    /// ⌘⇧A: the visible page's Ask AI button opens its popover and clears it.
    var openRequest: UUID?
    /// An action the visible page's view runs (see `AssistantCommand`).
    var pendingCommand: AssistantCommand?
    /// The resolved Express form as MiniWizardView shows it (effective
    /// footage kind, current run, effective settings); nil until it is on
    /// screen once.
    var expressPage: WizardAssistant.ExpressPage?
    /// The resolved full Wizard form as WizardView shows it.
    var fullPage: WizardAssistant.FullPage?
    /// An AI ranking is in flight; the popover shows a spinner beside the
    /// rule-based rows.
    private(set) var isRefreshing = false
    /// AI-ranked rows by the context fingerprint they were made for, for the
    /// session. Only answers that parsed are kept: a timeout, provider error
    /// or unreadable reply leaves no entry, so the rules show and the next
    /// refresh (popover open, context change) asks again.
    private(set) var rankings: [String: [AssistantSuggestion]] = [:]
    /// Pages with a typed request at the AI; the popover shows a spinner.
    private(set) var askingPages: Set<String> = []
    /// Bumped when an AI answer ran an action, so an open popover closes
    /// the way it does when Send runs one directly.
    private(set) var closeRequest: UUID?
    @ObservationIgnored var assistCall: AssistCall?
    @ObservationIgnored var assistTimeout: Duration = AssistantModel.defaultTimeout
    @ObservationIgnored var understandTimeout: Duration = AssistantModel.understandTimeout
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshingFingerprint: String?
    @ObservationIgnored private var askTasks: [String: Task<Void, Never>] = [:]
    /// The latest typed request per page; an answer for any other is dropped.
    @ObservationIgnored private var askTokens: [String: AssistRequestToken] = [:]
    /// Bumped by every dismiss so views reading `dismissed` refresh; the set
    /// itself lives in UserDefaults.
    private(set) var dismissedRevision = 0
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Bumped by `AppStore` on every sidebar page change; typed requests
    /// sent before a change are stale (see `AssistRequestToken`).
    var navigationGeneration = 0

    func pageChanged() { navigationGeneration &+= 1 }

    nonisolated static func dismissedKey(profileName: String) -> String {
        "assistant.dismissed.\(profileName)"
    }

    /// Dismissed rows as `AssistantSuggestion.dismissKey`s (id + reason
    /// signature): a row whose reason changes is a new key and shows again.
    func dismissed(profileName: String) -> Set<String> {
        _ = dismissedRevision
        return Set(defaults.stringArray(forKey: Self.dismissedKey(profileName: profileName)) ?? [])
    }

    func dismiss(_ suggestion: AssistantSuggestion, profileName: String) {
        var keys = dismissed(profileName: profileName)
        guard keys.insert(suggestion.dismissKey).inserted else { return }
        defaults.set(keys.sorted(), forKey: Self.dismissedKey(profileName: profileName))
        dismissedRevision &+= 1
    }

    func restoreDismissed(profileName: String) {
        defaults.removeObject(forKey: Self.dismissedKey(profileName: profileName))
        dismissedRevision &+= 1
    }

    /// Un-dismiss one suggestion ("Restore" in the popover's dismissed list).
    func restore(_ suggestion: AssistantSuggestion, profileName: String) {
        var keys = dismissed(profileName: profileName)
        guard keys.remove(suggestion.dismissKey) != nil else { return }
        let key = Self.dismissedKey(profileName: profileName)
        if keys.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(keys.sorted(), forKey: key) }
        dismissedRevision &+= 1
    }

    /// The page's suggestions the user dismissed that would show now: rows
    /// the rules (and a matching AI ranking) produce for this context whose
    /// dismiss key (id + reason) is dismissed. Dismissals whose reason no
    /// longer fires, or fires with a different reason, are not counted.
    /// Drives the popover's "Show dismissed (N)" footer.
    func dismissedSuggestions(for assistant: any PageAssistant, context: AssistantContext, actions: [AssistantAction],
                              store: AppStore) -> [AssistantSuggestion] {
        let offered = Set(actions.map(\.id))
        let rules = assistant.suggestions(for: context).filter { $0.actionID.map(offered.contains) ?? true }
        return Self.dismissedRows(rules: rules, ranked: rankings[context.fingerprint],
                                  dismissed: dismissed(profileName: store.activeProfile.profileName),
                                  offeredActions: offered)
    }

    /// Pure core of `dismissedSuggestions`: every row `merge` would show
    /// with nothing dismissed and no cap, kept only when its dismiss key is dismissed.
    nonisolated static func dismissedRows(rules: [AssistantSuggestion], ranked: [AssistantSuggestion]?,
                                          dismissed: Set<String>, offeredActions: Set<String>? = nil) -> [AssistantSuggestion] {
        guard !dismissed.isEmpty else { return [] }
        return merge(rules: rules, ranked: ranked, dismissed: [], offeredActions: offeredActions, limit: Int.max)
            .filter { dismissed.contains($0.dismissKey) }
    }

    /// Merge `state` into the page's published state.
    func updatePageState(_ page: String, _ state: AssistantPageState) {
        let merged = (pageState[page] ?? AssistantPageState()).merging(state)
        if pageState[page] != merged { pageState[page] = merged }
    }

    /// Profile switch: nothing published by the old profile's pages survives.
    func reset() {
        pageState = [:]
        lastOutcome = [:]
        pendingCommand = nil
        expressPage = nil
        fullPage = nil
        openRequest = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshingFingerprint = nil
        rankings = [:]
        isRefreshing = false
        askTasks.values.forEach { $0.cancel() }
        askTasks = [:]
        askTokens = [:]
        askingPages = []
    }

    /// Up to five suggestions for the page as it is now: the rules, with
    /// suggestions whose action the page does not offer removed, merged
    /// with a matching AI ranking (Phase 3), dismissed ids filtered out.
    func suggestions(for assistant: any PageAssistant, store: AppStore) -> [AssistantSuggestion] {
        let context = assistant.context(store: store)
        return suggestions(for: assistant, context: context, actions: assistant.actions(store: store), store: store)
    }

    func suggestions(for assistant: any PageAssistant, context: AssistantContext, actions: [AssistantAction],
                     store: AppStore) -> [AssistantSuggestion] {
        let offered = Set(actions.map(\.id))
        let rules = assistant.suggestions(for: context).filter { $0.actionID.map(offered.contains) ?? true }
        let ai = rankings[context.fingerprint]
        return Self.merge(rules: rules, ranked: ai, dismissed: dismissed(profileName: store.activeProfile.profileName),
                          offeredActions: offered)
    }

    /// Ranked rows first (an id the rules also produce keeps the rule's
    /// action and reason key), then the remaining rules in order. Unique by
    /// id, dismissed keys dropped, an action id nobody offers refused,
    /// capped at `limit`.
    nonisolated static func merge(rules: [AssistantSuggestion], ranked: [AssistantSuggestion]?, dismissed: Set<String>,
                                  offeredActions: Set<String>? = nil, limit: Int = suggestionLimit) -> [AssistantSuggestion] {
        var seen: Set<String> = []
        var result: [AssistantSuggestion] = []
        let ruleByID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var row in ranked ?? [] {
            if let rule = ruleByID[row.id] {
                row.actionID = rule.actionID
                row.kind = rule.kind
                // A cached ranking made before the reason changed must not
                // keep a stale dismissal (or dodge a current one).
                row.reasonKey = rule.reasonKey
            }
            if let action = row.actionID, let offeredActions, !offeredActions.contains(action) { continue }
            guard !dismissed.contains(row.dismissKey), seen.insert(row.id).inserted else { continue }
            result.append(row)
        }
        for row in rules where !dismissed.contains(row.dismissKey) && seen.insert(row.id).inserted {
            result.append(row)
        }
        return Array(result.prefix(max(0, limit)))
    }

    // MARK: - AI ranking

    /// Cancel the previous AI ranking and start one for the page's current
    /// fingerprint, unless that fingerprint has a parsed ranking or is
    /// already in flight. A failed one is not cached, so this retries it.
    /// The rule rows show meanwhile; the ranked rows replace their order
    /// when they land (`suggestions(for:)` reads `rankings`).
    func refresh(assistant: any PageAssistant, store: AppStore) {
        let context = assistant.context(store: store)
        let actions = assistant.actions(store: store)
        let offered = Set(actions.map(\.id))
        let rules = assistant.suggestions(for: context).filter { $0.actionID.map(offered.contains) ?? true }
        let catalogue = actions.filter { $0.isAvailable(store) }.map { PageAssistantPrompt.Action(id: $0.id, title: $0.title) }
        refresh(context: context, rules: rules, catalogue: catalogue, call: assistCall ?? Self.liveCall(store.ai))
    }

    /// Testable core of `refresh(assistant:store:)`. Returns the fetch so a
    /// caller can await it; nil when nothing needs asking.
    @discardableResult
    func refresh(context: AssistantContext, rules: [AssistantSuggestion], catalogue: [PageAssistantPrompt.Action],
                 call: @escaping AssistCall) -> Task<Void, Never>? {
        let fingerprint = context.fingerprint
        if rankings[fingerprint] != nil { return nil }
        if refreshingFingerprint == fingerprint, let refreshTask { return refreshTask }
        refreshTask?.cancel()
        refreshTask = nil
        refreshingFingerprint = nil
        isRefreshing = false
        // Nothing to rank and nothing to add: the rules are the answer.
        guard !rules.isEmpty || !catalogue.isEmpty else { return nil }
        let prompt = PageAssistantPrompt.build(context: context, actions: catalogue, settings: [], question: nil,
                                               suggestions: rules)
        let timeout = assistTimeout
        refreshingFingerprint = fingerprint
        isRefreshing = true
        let task = Task { [weak self] in
            let response = try? await Self.withTimeout(timeout) { try await call(prompt) }
            guard let self, !Task.isCancelled, self.refreshingFingerprint == fingerprint else { return }
            self.refreshingFingerprint = nil
            self.refreshTask = nil
            self.isRefreshing = false
            // Timeouts, provider errors and unreadable replies leave no
            // entry: the rules stand and the next refresh asks again.
            if let response, let rows = Self.rankedRows(reply: response.text, rules: rules, catalogue: catalogue,
                                                        provenance: response.provenance, fingerprint: context.fingerprint) {
                self.rankings[fingerprint] = rows
            }
        }
        refreshTask = task
        return task
    }

    /// The AI's ranking as suggestion rows: a rule id keeps the rule's
    /// kind, title and action and takes the AI's reason when it gave one; a
    /// catalogue action id (or an id matching a rule's action) becomes an
    /// `ai.<action>` row with the AI's reason, or the rule it matches.
    /// Anything else is dropped, so the AI can reorder and rephrase but
    /// never invent an action. Nil when the reply is not a ranking at all.
    nonisolated static func rankedRows(reply: String, rules: [AssistantSuggestion],
                                       catalogue: [PageAssistantPrompt.Action],
                                       provenance: AIProvenance?, fingerprint: String = "") -> [AssistantSuggestion]? {
        guard let ranked = PageAssistantPrompt.parseRanking(reply, suggestions: rules, actions: catalogue) else { return nil }
        var rows: [AssistantSuggestion] = []
        for item in ranked {
            var row: AssistantSuggestion
            if let rule = rules.first(where: { $0.id == item.id }) ?? rules.first(where: { $0.actionID == item.id }) {
                row = rule
                if let reason = item.reason { row.reason = reason }
            } else if let action = catalogue.first(where: { $0.id == item.id }), let reason = item.reason {
                row = AssistantSuggestion(id: "ai.\(action.id)", kind: .action, title: action.title, reason: reason,
                                          actionID: action.id)
                // The model rephrases freely; a dismissal must survive that,
                // so the key is the action plus the page's facts, not the wording.
                row.reasonKey = "ai:\(action.id):\(fingerprint)"
            } else {
                continue
            }
            guard !rows.contains(where: { $0.id == row.id }) else { continue }
            row.provenance = provenance
            rows.append(row)
        }
        return rows
    }

    /// The real `AITask.assist` call; the model's own timeout bounds it too.
    nonisolated static func liveCall(_ ai: AIService, timeout: Duration = defaultTimeout) -> AssistCall {
        let seconds = Double(timeout.components.seconds)
        return { prompt in
            try await ai.call(prompt: prompt, task: .assist, timeout: seconds)
        }
    }

    struct TimedOut: Error {}

    /// `work`, or `TimedOut` after `duration`, whichever is first. A hard
    /// bound: the worker is cancelled but never awaited (a task group would
    /// wait for it, and the live call waits for its process to exit), so a
    /// worker slow to honor cancellation cannot hold the caller past the
    /// deadline; whatever it returns later is dropped. Cancelling the caller
    /// ends the wait at once with `CancellationError`.
    nonisolated static func withTimeout<T: Sendable>(_ duration: Duration,
                                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = FirstResultGate<T>()
        let worker = Task {
            do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: duration)
                gate.finish(.failure(TimedOut()))
            } catch {
                // Cancelled: the worker or the caller finished first.
            }
        }
        defer {
            worker.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Run a suggestion's action. Records the outcome for the page and shows
    /// a notice when the page cannot do it now.
    @discardableResult
    func run(_ suggestion: AssistantSuggestion, assistant: any PageAssistant, store: AppStore) -> AskAIOutcome? {
        guard let actionID = suggestion.actionID else { return nil }
        return run(actionID: actionID, assistant: assistant, store: store)
    }

    @discardableResult
    func run(actionID: String, assistant: any PageAssistant, store: AppStore) -> AskAIOutcome {
        let outcome: AskAIOutcome
        if let action = assistant.actions(store: store).first(where: { $0.id == actionID }) {
            outcome = action.isAvailable(store) ? action.run(store) : .unavailable("\(action.title) is not available right now.")
        } else {
            outcome = .unavailable("This page cannot do that.")
        }
        record(outcome, page: assistant.page, store: store)
        return outcome
    }

    /// Free text typed into Ask AI: the assistant's own rules first; when
    /// they do not recognize it (`AssistantText.unrecognized`), the AI reads
    /// it against the page's context, actions and settings whitelist. That
    /// returns `.pending` at once and records the real outcome later.
    @discardableResult
    func send(_ text: String, assistant: any PageAssistant, store: AppStore) -> AskAIOutcome {
        let outcome = assistant.handle(text, store: store)
        guard outcome == AssistantText.unrecognized(page: assistant.page, examples: assistant.examples) else {
            record(outcome, page: assistant.page, store: store)
            return outcome
        }
        return understand(text, assistant: assistant, store: store, unrecognized: outcome,
                          call: assistCall ?? Self.liveCall(store.ai, timeout: understandTimeout))
    }

    static let askingMessage = "Asking…"
    static let staleMessage = "The page changed while Ask AI was thinking, so nothing was applied. Ask again."

    /// Ask `AITask.assist` what `text` means here, then apply its settings
    /// patch and run its action. Returns `.pending`; `unrecognized` is the
    /// outcome when the AI fails, times out or the page offers nothing.
    /// The request carries an `AssistRequestToken`: the answer is applied
    /// only if it is still the page's latest request and the profile,
    /// project and page context (fingerprint, which includes the Wizard
    /// mode) are the ones it was asked against; otherwise it is dropped
    /// with `staleMessage`. The deadline ends the wait even when the worker
    /// is slow to stop.
    @discardableResult
    func understand(_ text: String, assistant: any PageAssistant, store: AppStore, unrecognized: AskAIOutcome,
                    call: @escaping AssistCall) -> AskAIOutcome {
        let page = assistant.page
        let context = assistant.context(store: store)
        let settings = assistant.assistSettings(store: store)
        // A page command is judged by the page after the answer's settings
        // land (a new folder or filter), so with settings to change it is
        // offered even when the current state would not allow it.
        let actions = assistant.actions(store: store).filter {
            $0.isAvailable(store) || ($0.handledByPage && !settings.isEmpty)
        }
        let catalogue = actions.map { PageAssistantPrompt.Action(id: $0.id, title: $0.title) }
        guard !catalogue.isEmpty || !settings.isEmpty else {
            record(unrecognized, page: page, store: store)
            return unrecognized
        }
        let prompt = PageAssistantPrompt.build(context: context, actions: catalogue, settings: settings, question: text,
                                               guidance: assistant.understandingGuidance(store: store))
        let timeout = understandTimeout
        let token = AssistRequestToken(page: page, profileGeneration: store.profileGeneration,
                                       projectID: store.activeProjectID, fingerprint: context.fingerprint,
                                       navigation: navigationGeneration)
        askTasks[page]?.cancel()
        askTokens[page] = token
        askingPages.insert(page)
        let pending = AskAIOutcome.pending(Self.askingMessage)
        lastOutcome[page] = pending
        askTasks[page] = Task { [weak self, weak store] in
            let response = try? await Self.withTimeout(timeout) { try await call(prompt) }
            // A newer request for this page, or a profile reset, owns the
            // page's state now: leave it alone.
            guard let self, let store, self.askTokens[page]?.id == token.id else { return }
            self.askTasks[page] = nil
            self.askTokens[page] = nil
            self.askingPages.remove(page)
            guard token.isCurrent(latest: token, profileGeneration: store.profileGeneration,
                                  projectID: store.activeProjectID,
                                  fingerprint: assistant.context(store: store).fingerprint,
                                  navigation: self.navigationGeneration) else {
                // Quietly: the user has moved on, a notice would interrupt.
                self.lastOutcome[page] = .unavailable(Self.staleMessage)
                return
            }
            guard let response else {
                self.record(unrecognized, page: page, store: store)
                return
            }
            let outcome = self.applyAnswer(PageAssistantPrompt.parseAnswer(response.text, actions: catalogue, settings: settings),
                                           assistant: assistant, store: store)
            self.record(outcome, page: page, store: store)
        }
        return pending
    }

    /// Settings first, then the action, both re-checked against what the
    /// page offers now (the answer may land after the page changed).
    func applyAnswer(_ parsed: PageAssistantPrompt.Parsed, assistant: any PageAssistant,
                     store: AppStore) -> AskAIOutcome {
        let answer: PageAssistantPrompt.Answer
        switch parsed {
        case .unreadable: return .unavailable("Ask AI could not read the model's answer. Try rephrasing, or run a suggestion.")
        case .refused(let message): return .unavailable(message)
        case .answer(let value): answer = value
        }
        store.appendLog(\.wizardLog, ["Ask AI (\(assistant.page)): action \(answer.actionID ?? "none") · settings \(answer.settings) · \(answer.reply)"])
        let action = answer.actionID.flatMap { id in assistant.actions(store: store).first { $0.id == id } }
        if answer.actionID != nil {
            guard let action else { return .unavailable("This page cannot do that now.") }
            // With a settings patch, a page command is checked by the page
            // against the patched state (a new folder may have the target).
            let pageJudges = action.handledByPage && !answer.settings.isEmpty
            guard pageJudges || action.isAvailable(store) else {
                return .unavailable("\(action.title) is not available right now.")
            }
        }
        if !answer.settings.isEmpty {
            let allowed = Set(assistant.assistSettings(store: store).map(\.key))
            guard answer.settings.keys.allSatisfy(allowed.contains) else {
                return .unavailable("Ask AI cannot change that setting on \(assistant.page).")
            }
        }
        var settingsCommand: UUID?
        var outcome: AskAIOutcome = .handled(answer.reply)
        if !answer.settings.isEmpty {
            let before = pendingCommand?.id
            outcome = assistant.apply(settings: answer.settings, store: store)
            if case .unavailable = outcome { return outcome }
            if pendingCommand?.id != before { settingsCommand = pendingCommand?.id }
        }
        if let action {
            let patch = settingsCommand.flatMap { id in pendingCommand?.id == id ? pendingCommand?.settings : nil }
            outcome = action.run(store)
            // One command slot: an action that hands itself to the page
            // replaces the settings command, so it carries the patch and
            // the page applies it before running the action.
            if let patch, let command = pendingCommand, command.id != settingsCommand {
                pendingCommand?.settings = (command.settings ?? [:]).merging(patch) { current, _ in current }
            }
            if case .unavailable = outcome { return outcome }
            closeRequest = UUID()
        }
        if case .started = outcome { return outcome }
        return .handled(answer.reply.isEmpty ? outcome.summary : answer.reply)
    }

    func isAsking(_ page: String) -> Bool { askingPages.contains(page) }

    private func record(_ outcome: AskAIOutcome, page: String, store: AppStore) {
        lastOutcome[page] = outcome
        if case .unavailable(let message) = outcome { store.presentNotice("Ask AI", message) }
    }

    /// Hand an action to the visible page's view; `namespace` names the
    /// view when the action id's prefix does not (see `AssistantCommand`).
    func sendCommand(_ actionID: String, text: String? = nil, settings: [String: String]? = nil,
                     expressOverlays: MiniWizardSettings? = nil, namespace: String? = nil) {
        pendingCommand = AssistantCommand(actionID: actionID, text: text, settings: settings,
                                          expressOverlays: expressOverlays, namespace: namespace)
    }

    /// Hand a settings patch to the visible page whose settings live in view
    /// state (`namespace` is its action prefix without the dot).
    func sendSettings(_ settings: [String: String], namespace: String, message: String) -> AskAIOutcome {
        sendCommand(AssistantCommand.settingsID(namespace), settings: settings)
        return .handled(message)
    }
}
