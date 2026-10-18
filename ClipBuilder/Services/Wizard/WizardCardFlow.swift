import Foundation

/// Navigation and summaries for the AI Wizard's four cards, with the Express
/// rules: any header opens at any time, and a card that lacks its inputs
/// explains what to do first instead of refusing to open. Pure; the view
/// owns the answers and the engine still receives the same two phases.
nonisolated struct WizardCardFlow: Sendable {
    enum Card: Int, CaseIterable, Sendable {
        case source = 1, plan, footage, settings

        var title: String {
            switch self {
            case .source: "Source"
            case .plan: "Plan"
            case .footage: "Footage"
            case .settings: "Settings"
            }
        }
    }

    struct Answers: Sendable {
        var fromIdea = false
        var workflow = "Automatic"
        var pastedFrom: String?
        var requestStatus: String?
        var sourceCount = 0
        var videoCount = 0
        var recordingName: String?
        var sourceDetail = "All analyzed scenes"
        var outcome = "One reel"
        var recipe = "Custom"
        var length = "Automatic length"
        var format = ""
        var brief = ""
        var planning = ""
        var selectionName: String?
        var takeLabel: String?
        var takeCount = 0
        var savedSelectionCount = 0
        /// Selections with a best take: what Generate renders.
        var keptSelectionCount = 0
        var look = "Profile defaults"
    }

    var answers = Answers()
    /// The card the user asked for; the page opens it even without its inputs.
    var requestedCard: Card = .source
    /// The open card the user collapsed by clicking its header; cleared by
    /// the next header click or navigation.
    var collapsedCard: Card?
    var sourcesReady = false
    var needsFootageProposal = false
    var automatic = true
    var hasTake = false
    var takeIsValid = false
    var isBusy = false

    /// What a card still needs before its controls do anything useful; nil
    /// when it is ready. Shown as the card's first line, never as a lock.
    func prerequisite(for card: Card) -> String? {
        switch card {
        case .source, .plan, .settings:
            return nil
        case .footage:
            if needsFootageProposal { return "Describe the idea and find matching footage in 1 Source first." }
            if !sourcesReady && answers.savedSelectionCount == 0 { return "Choose usable sources in 1 Source first." }
            return nil
        }
    }

    /// Whether the card's controls are live; the header always opens.
    func canExpand(_ card: Card) -> Bool { prerequisite(for: card) == nil }

    var openCard: Card { requestedCard }

    /// What the page shows open: the open card unless the user collapsed it.
    var visibleCard: Card? { collapsedCard == openCard ? nil : openCard }

    func isCollapsed(_ card: Card) -> Bool { card != visibleCard }

    /// A header click: a collapsed card opens; the open card collapses.
    func headerClick(_ card: Card) -> (requested: Card, collapsed: Card?) {
        if visibleCard == card { return (requestedCard, card) }
        return (card, nil)
    }

    var canRenderTake: Bool { hasTake && takeIsValid && !isBusy }

    /// The settings card renders the kept takes when there are any and
    /// otherwise generates a new reel from the plan.
    var settingsRenders: Bool { answers.keptSelectionCount > 0 }

    /// The generation button's title for kept selections, as Express words it.
    func generateTitle(oneReel: Bool) -> String {
        oneReel || answers.keptSelectionCount == 1 ? "Generate Video" : "Generate Videos"
    }

    /// How many videos Generate makes from the kept selections.
    func outputCount(oneReel: Bool) -> Int {
        answers.keptSelectionCount > 0 && oneReel ? 1 : answers.keptSelectionCount
    }

    func summary(for card: Card) -> String {
        switch card {
        case .source:
            if needsFootageProposal { return "Find matching footage for your idea" }
            var parts: [String] = []
            if let name = answers.recordingName { parts.append("1 recording · \(name)") }
            else if answers.videoCount == 0 { parts.append("No footage selected") }
            else {
                parts.append("\(answers.sourceCount) \(answers.sourceCount == 1 ? "scene" : "scenes") · "
                    + "\(answers.videoCount) \(answers.videoCount == 1 ? "video" : "videos") · \(answers.sourceDetail)")
            }
            if answers.fromIdea { parts.append("From an idea") }
            if let source = answers.pastedFrom { parts.append("Pasted from \(source)") }
            if let status = answers.requestStatus { parts.append(status) }
            return parts.joined(separator: " · ")
        case .plan:
            let brief = answers.brief.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return [answers.outcome, answers.recipe, answers.length, answers.format, brief ?? "", answers.planning]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .footage:
            if hasTake {
                let kept = answers.keptSelectionCount
                return takeSummary + " · \(answers.takeCount) \(answers.takeCount == 1 ? "take" : "takes")"
                    + (answers.savedSelectionCount > 1 ? " · \(kept) of \(answers.savedSelectionCount) selections kept" : "")
            }
            if answers.savedSelectionCount > 0 { return "\(answers.savedSelectionCount) saved selections · choose a take" }
            return automatic ? "Generate finds the moments, or find them here first" : "No saved selection yet"
        case .settings:
            if hasTake {
                return (takeIsValid ? takeSummary : "Footage changed · open the selection for another take")
                    + " · " + answers.look
            }
            return answers.look
        }
    }

    private var takeSummary: String {
        [answers.selectionName, answers.takeLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
