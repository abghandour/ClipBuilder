import Foundation

/// A request typed into Ask AI on the AI Wizard page. The visible wizard form
/// (Express or Full) consumes it: it writes the text into its instructions
/// field and presses its own Generate.
nonisolated struct WizardAssistantRequest: Equatable, Sendable {
    var id = UUID()
    var text: String
}

nonisolated struct WizardAssistant: PageAssistant {
    let page = "AI Wizard"
    let examples = ["Make a 30-second reel of the funniest moments",
                    "Find the three best highlights about fight strategy",
                    "Build a reel around the knockout and the walkout"]

    enum Decision: Equatable, Sendable {
        case send
        case unavailable(String)
    }

    /// Pure gate so the view never receives a request it cannot run.
    static func decide(text: String, mode: WizardMode, hasVideo: Bool, hasScenes: Bool, running: Bool) -> Decision {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("Describe the reel you want.")
        }
        if running { return .unavailable("The Wizard is already working.") }
        switch mode {
        case .express:
            return hasVideo ? .send : .unavailable("Choose a source video in Express first.")
        case .full:
            return hasScenes ? .send : .unavailable("Analyze a source first so the Wizard has scenes to pick from.")
        }
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = store.activeProfile.profileName
        let videoPath = UserDefaults.standard.string(forKey: MiniWizardMemory.key(for: .videoPath, profileName: profile)) ?? ""
        switch Self.decide(text: text, mode: store.wizardMode, hasVideo: !videoPath.isEmpty,
                           hasScenes: !store.scenes.isEmpty, running: store.isWizardRunning) {
        case .unavailable(let message):
            return .unavailable(message)
        case .send:
            // The visible form consumes this and decides whether it can run
            // now; only it knows (Full mode needs chosen sources too), so this
            // reports a hand-off, not a started job.
            store.pendingWizardAssistantRequest = WizardAssistantRequest(text: text)
            return .handled(store.wizardMode == .express ? "Sent to Express." : "Sent to the Wizard.")
        }
    }
}
