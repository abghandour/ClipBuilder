import Foundation

nonisolated struct BuilderAssistant: PageAssistant {
    let page = "Builder"
    let examples = ["Put a duck face on the fighter on the left", "Add a crown sticker", "Make a 30-second reel"]

    enum Route: Equatable, Sendable {
        case image(String)
        case wizard(String)
    }

    /// An image request starts with a making verb and names a sticker, image
    /// or picture outright, or names a prop (face, hat, crown…) without also
    /// talking about a reel, video or clip. "Make a reel of the face off" is
    /// a reel; "Add a sticker to the clip" is an image.
    static func route(_ text: String) -> Route {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        guard matches(#"(?i)^(add|put|give|draw|generate|make)\b"#) else { return .wizard(text) }
        if matches(#"(?is)\b(sticker|image|picture)\b"#) { return .image(text) }
        let namesProp = matches(#"(?is)\b(face|hat|nose|glasses|crown|beak|mask)\b"#)
        let aboutFootage = matches(#"(?is)\b(reels?|videos?|clips?|timeline|highlights?|cut|edit|montage)\b"#)
        return namesProp && !aboutFootage ? .image(text) : .wizard(text)
    }

    @MainActor
    func handle(_ text: String, store: AppStore) -> AskAIOutcome {
        guard store.openTimelineID != nil else { return .unavailable("Open a timeline first.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable("Describe what you want to make.")
        }
        switch Self.route(text) {
        case .image(let prompt):
            store.builder.pendingGenerateImagePrompt = prompt
            return .handled("Choose a face and generate the image.")
        case .wizard(let request):
            if store.builderWizard?.identityMatches != true {
                store.builderWizard?.dismiss()
                store.builderWizard = WizardSheetModel(store: store)
            }
            guard let wizard = store.builderWizard, !wizard.busy,
                  !store.jobs.hasLiveTask(kind: .builderAssistant) else {
                return .unavailable("The Builder Wizard is already working.")
            }
            wizard.request = request
            store.builder.pendingAssistantWizard = UUID()
            store.jobs.start(.builderAssistant, title: "Builder — Ask AI", project: store.activeProject,
                             profileGeneration: store.profileGeneration,
                             subjectID: "builder-assistant-\(store.openTimelineID ?? 0)") { _ in
                try Task.checkCancellation()
                guard wizard.identityMatches else { throw CancellationError() }
                await withTaskCancellationHandler {
                    await wizard.run()
                } onCancel: {
                    Task { @MainActor in wizard.cancelRun() }
                }
                return nil
            }
            return .started(jobTitle: "Builder Wizard")
        }
    }
}
