import Foundation

/// Navigation only: the seven UI steps still submit the existing two engine phases.
/// Confirmations are session-local; all editing answers keep their existing storage.
nonisolated struct WizardStepFlow: Sendable {
    enum Step: Int, CaseIterable, Sendable {
        case start = 1, sources, outcome, planning, moments, look, render

        var title: String {
            switch self {
            case .start: "Start"
            case .sources: "Sources"
            case .outcome: "Outcome"
            case .planning: "Brief & planning"
            case .moments: "Find the moments"
            case .look: "Look"
            case .render: "Render"
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
        var look = "Profile defaults"
    }

    var answers = Answers()
    var confirmed: Set<Step> = []
    var requestedStep: Step?
    /// The open step the user collapsed by clicking its header; cleared by
    /// the next header click or Change.
    var collapsedStep: Step?
    var sourcesReady = false
    var needsFootageProposal = false
    var automatic = true
    var hasTake = false
    var takeIsValid = false
    var isBusy = false

    private var setupReady: Bool {
        confirmed.contains(.start) && confirmed.contains(.sources) && sourcesReady
            && !needsFootageProposal && confirmed.contains(.outcome)
    }

    func prerequisite(for step: Step) -> String? {
        switch step {
        case .start: return nil
        case .sources, .outcome:
            return confirmed.contains(.start) ? nil : "Choose how to start first"
        case .planning:
            if !confirmed.contains(.start) { return "Choose how to start first" }
            if needsFootageProposal { return "Find and confirm matching footage first" }
            if !sourcesReady || !confirmed.contains(.sources) { return "Confirm sources first" }
            return confirmed.contains(.outcome) ? nil : "Choose the outcome first"
        case .moments:
            // Existing selections remain reachable independently of new-run setup.
            if answers.savedSelectionCount > 0 { return nil }
            if let reason = prerequisite(for: .planning) { return reason }
            return confirmed.contains(.planning) ? nil : "Confirm the brief and planning first"
        case .look:
            if hasTake { return nil }
            if !automatic { return "Find the moments first" }
            if let reason = prerequisite(for: .planning) { return reason }
            return confirmed.contains(.planning) ? nil : "Confirm the brief and planning first"
        case .render:
            if let reason = prerequisite(for: .look) { return reason }
            return confirmed.contains(.look) ? nil : "Confirm the look first"
        }
    }

    func canExpand(_ step: Step) -> Bool { prerequisite(for: step) == nil }

    func isComplete(_ step: Step) -> Bool {
        switch step {
        case .sources: confirmed.contains(step) && sourcesReady && !needsFootageProposal
        case .moments: hasTake || (automatic && setupReady && confirmed.contains(step))
        case .render: false
        default: confirmed.contains(step)
        }
    }

    /// Change is explicit. A stale request falls back to the next real prerequisite.
    var openStep: Step {
        if let requestedStep, canExpand(requestedStep) { return requestedStep }
        // A saved take is reusable even when the new-run source pool is empty.
        if hasTake { return confirmed.contains(.look) ? .render : .look }
        return Step.allCases.first { canExpand($0) && !isComplete($0) } ?? .start
    }

    /// What the page shows open: the open step unless the user collapsed it.
    var visibleStep: Step? { collapsedStep == openStep ? nil : openStep }

    func isCollapsed(_ step: Step) -> Bool { step != visibleStep }

    /// A header click: an expandable collapsed step opens; the open step collapses.
    func headerClick(_ step: Step) -> (requested: Step?, collapsed: Step?)? {
        guard canExpand(step) else { return nil }
        if visibleStep == step { return (requestedStep, step) }
        return (step, nil)
    }

    func canContinue(_ step: Step) -> Bool {
        guard !isBusy, canExpand(step) else { return false }
        switch step {
        case .start, .outcome: return true
        case .sources: return sourcesReady && !needsFootageProposal
        case .planning: return setupReady
        case .moments: return hasTake || (automatic && setupReady && confirmed.contains(.planning))
        case .look: return hasTake || (automatic && setupReady && confirmed.contains(.planning))
        case .render: return false
        }
    }

    func nextStep(after step: Step) -> Step {
        switch step {
        case .start: .sources
        case .sources: confirmed.contains(.outcome) ? .planning : .outcome
        case .outcome: isComplete(.sources) ? .planning : .sources
        case .planning: .moments
        case .moments: .look
        case .look, .render: .render
        }
    }

    var canRenderTake: Bool { hasTake && takeIsValid && !isBusy }

    func summary(for step: Step) -> String {
        switch step {
        case .start:
            var parts = [answers.fromIdea ? "From an idea" : "From footage", answers.workflow]
            if let source = answers.pastedFrom { parts.append("Pasted from \(source)") }
            if let status = answers.requestStatus { parts.append(status) }
            return parts.joined(separator: " · ")
        case .sources:
            if needsFootageProposal { return "Find matching footage for your idea" }
            if let name = answers.recordingName { return "1 recording · \(name)" }
            if answers.videoCount == 0 { return "No footage selected" }
            return "\(answers.sourceCount) \(answers.sourceCount == 1 ? "scene" : "scenes") · "
                + "\(answers.videoCount) \(answers.videoCount == 1 ? "video" : "videos") · \(answers.sourceDetail)"
        case .outcome:
            return [answers.outcome, answers.recipe, answers.length, answers.format]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .planning:
            let brief = answers.brief.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return [brief ?? "Recipe guidance", answers.planning]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .moments:
            if hasTake { return takeSummary + " · \(answers.takeCount) \(answers.takeCount == 1 ? "take" : "takes")" }
            if answers.savedSelectionCount > 0 { return "\(answers.savedSelectionCount) saved selections · choose a take" }
            return "No saved selection yet"
        case .look: return answers.look
        case .render:
            if hasTake { return takeIsValid ? takeSummary : "Footage changed · open the selection for another take" }
            return automatic ? "Generate a new reel with these settings" : "Find the moments first"
        }
    }

    private var takeSummary: String {
        [answers.selectionName, answers.takeLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
