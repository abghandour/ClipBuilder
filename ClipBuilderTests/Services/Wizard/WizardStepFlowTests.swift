import Testing
@testable import Clip_Builder

@Suite("Full Wizard step flow")
struct WizardStepFlowTests {
    private func prepared(automatic: Bool = true) -> WizardStepFlow {
        WizardStepFlow(confirmed: [.start, .sources, .outcome, .planning],
                       sourcesReady: true, automatic: automatic)
    }

    @Test func initialStepRequiresAcknowledgementEvenWithSavedDefaults() {
        let flow = WizardStepFlow(sourcesReady: true)
        #expect(flow.openStep == .start)
        #expect(flow.canContinue(.start))
        #expect(!flow.canExpand(.sources))
        #expect(!flow.canExpand(.outcome))
        #expect(flow.prerequisite(for: .sources) == "Choose how to start first")
        #expect(WizardStepFlow.Step.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func nextUnansweredStepOpensInOrder() {
        var flow = WizardStepFlow(sourcesReady: true)
        let progression: [(WizardStepFlow.Step, WizardStepFlow.Step)] = [
            (.start, .sources), (.sources, .outcome), (.outcome, .planning),
            (.planning, .moments), (.moments, .look), (.look, .render)
        ]
        for (completed, next) in progression {
            #expect(flow.canContinue(completed))
            flow.confirmed.insert(completed)
            #expect(flow.openStep == next)
        }
        #expect(!flow.canContinue(.render))
    }

    @Test func outcomeCanRepairMissingSourcesWithoutSkippingPlanningPrerequisites() {
        let flow = WizardStepFlow(confirmed: [.start], requestedStep: .outcome)
        #expect(flow.openStep == .outcome)
        #expect(flow.canContinue(.outcome))
        #expect(!flow.canContinue(.sources))
        #expect(!flow.canExpand(.planning))
        #expect(flow.prerequisite(for: .planning) == "Confirm sources first")
    }

    @Test func continuingOutcomeRechecksSourcesAndThenReturnsToPlanning() {
        var flow = WizardStepFlow(confirmed: [.start, .outcome], sourcesReady: true)
        #expect(flow.nextStep(after: .outcome) == .sources)
        #expect(flow.nextStep(after: .sources) == .planning)
        flow.confirmed.insert(.sources)
        #expect(flow.nextStep(after: .outcome) == .planning)
        flow.sourcesReady = false
        #expect(flow.nextStep(after: .outcome) == .sources)
        #expect(flow.nextStep(after: .planning) == .moments)
        #expect(flow.nextStep(after: .moments) == .look)
        #expect(flow.nextStep(after: .look) == .render)
    }

    @Test func ideaNeedsAProposalAndExplicitSourceConfirmation() {
        var flow = WizardStepFlow(confirmed: [.start, .outcome], sourcesReady: true,
                                  needsFootageProposal: true)
        #expect(flow.openStep == .sources)
        #expect(!flow.canContinue(.sources))
        #expect(flow.prerequisite(for: .planning) == "Find and confirm matching footage first")
        flow.needsFootageProposal = false
        #expect(flow.canContinue(.sources))
        #expect(!flow.canExpand(.planning))
        flow.confirmed.insert(.sources)
        #expect(flow.openStep == .planning)
    }

    @Test func changeOverridesProgressAndReturnsToNextUnansweredWhenCleared() {
        var flow = prepared()
        #expect(flow.openStep == .moments)
        for step in [WizardStepFlow.Step.start, .sources, .outcome, .planning] {
            flow.requestedStep = step
            #expect(flow.openStep == step)
            #expect(WizardStepFlow.Step.allCases.filter { !flow.isCollapsed($0) } == [step])
        }
        flow.requestedStep = nil
        #expect(flow.openStep == .moments)
    }

    @Test func staleChangeRequestClampsWhenSourcesDisappear() {
        var flow = prepared()
        flow.requestedStep = .planning
        flow.sourcesReady = false
        #expect(!flow.isComplete(.sources))
        #expect(!flow.canExpand(.planning))
        #expect(flow.openStep == .sources)
        flow.sourcesReady = true
        flow.confirmed.subtract([.sources, .planning, .moments])
        #expect(flow.openStep == .sources)
    }

    @Test func automaticCanConfigureLookBeforeDiscoveryWithoutClaimingASavedTake() {
        var flow = prepared()
        #expect(flow.canExpand(.look))
        #expect(flow.canContinue(.moments))
        #expect(!flow.isComplete(.moments))
        flow.confirmed.insert(.moments)
        #expect(flow.openStep == .look)
        #expect(flow.summary(for: .moments) == "No saved selection yet")
        #expect(!flow.canRenderTake)
        flow.confirmed.insert(.look)
        #expect(flow.openStep == .render)
        #expect(flow.summary(for: .render) == "Generate a new reel with these settings")
    }

    @Test func reviewWorkflowsRequireASavedTakeForLook() {
        var flow = prepared(automatic: false)
        flow.requestedStep = .look
        #expect(flow.openStep == .moments)
        #expect(flow.prerequisite(for: .look) == "Find the moments first")
        #expect(!flow.canContinue(.moments))
        flow.hasTake = true
        flow.takeIsValid = true
        #expect(flow.openStep == .look)
        #expect(flow.isComplete(.moments))
        #expect(flow.canRenderTake)
        #expect(flow.prerequisite(for: .render) == "Confirm the look first")
    }

    @Test func savedSelectionsCanBeReusedWithoutNewRunSources() {
        var answers = WizardStepFlow.Answers()
        answers.savedSelectionCount = 2
        var flow = WizardStepFlow(answers: answers, requestedStep: .moments, automatic: false)
        #expect(flow.openStep == .moments)
        #expect(flow.summary(for: .moments) == "2 saved selections · choose a take")
        #expect(!flow.canContinue(.moments))
        flow.hasTake = true
        flow.takeIsValid = true
        flow.requestedStep = .look
        #expect(flow.openStep == .look)
        #expect(flow.canContinue(.look))
        flow.confirmed.insert(.look)
        flow.requestedStep = nil
        #expect(flow.openStep == .render)
    }

    @Test func deletedTakeClampsReviewFlowBackToDiscovery() {
        var flow = prepared(automatic: false)
        flow.hasTake = true
        flow.takeIsValid = true
        flow.confirmed.insert(.look)
        flow.requestedStep = .render
        #expect(flow.openStep == .render)
        flow.hasTake = false
        #expect(!flow.canRenderTake)
        #expect(flow.openStep == .moments)
    }

    @Test func changedFootageAndBusyWorkBlockRenderingButKeepRecoveryReachable() {
        var flow = WizardStepFlow(confirmed: [.look], automatic: false, hasTake: true)
        #expect(flow.openStep == .render)
        #expect(!flow.canRenderTake)
        #expect(flow.summary(for: .render) == "Footage changed · open the selection for another take")
        flow.takeIsValid = true
        #expect(flow.canRenderTake)
        flow.isBusy = true
        #expect(!flow.canRenderTake)
        #expect(!flow.canContinue(.look))
        #expect(flow.canExpand(.look))
    }

    @Test func summariesReflectAnswersAndSingularCounts() {
        var answers = WizardStepFlow.Answers()
        answers.fromIdea = true
        answers.workflow = "Review moments and look"
        answers.pastedFrom = "Run 12"
        answers.sourceCount = 1
        answers.videoCount = 1
        answers.sourceDetail = "Favorite scenes"
        answers.outcome = "One reel"
        answers.recipe = "Interview"
        answers.length = "30s"
        answers.format = "9:16 · 1080p"
        answers.brief = "\n  Keep the complete answer.\nSecond line"
        answers.planning = "Profile taste"
        answers.selectionName = "The final exchange"
        answers.takeLabel = "Take 2 · 30s"
        answers.takeCount = 2
        answers.look = "Captions · Brand default"
        var flow = WizardStepFlow(answers: answers, hasTake: true, takeIsValid: true)
        #expect(flow.summary(for: .start) == "From an idea · Review moments and look · Pasted from Run 12")
        #expect(flow.summary(for: .sources) == "1 scene · 1 video · Favorite scenes")
        #expect(flow.summary(for: .outcome) == "One reel · Interview · 30s · 9:16 · 1080p")
        #expect(flow.summary(for: .planning) == "Keep the complete answer. · Profile taste")
        #expect(flow.summary(for: .moments) == "The final exchange · Take 2 · 30s · 2 takes")
        #expect(flow.summary(for: .look) == "Captions · Brand default")
        #expect(flow.summary(for: .render) == "The final exchange · Take 2 · 30s")
        flow.answers.takeCount = 1
        #expect(flow.summary(for: .moments).hasSuffix("1 take"))
    }

    @Test func summariesCoverEmptySourcesRecordingsAndOptionalBrief() {
        var flow = WizardStepFlow()
        #expect(flow.summary(for: .sources) == "No footage selected")
        flow.answers.planning = "Profile taste"
        #expect(flow.summary(for: .planning) == "Recipe guidance · Profile taste")
        flow.answers.recordingName = "Podcast 01.mp4"
        #expect(flow.summary(for: .sources) == "1 recording · Podcast 01.mp4")
        flow.needsFootageProposal = true
        #expect(flow.summary(for: .sources) == "Find matching footage for your idea")
        flow.answers.requestStatus = "Finding footage…"
        #expect(flow.summary(for: .start).hasSuffix("Finding footage…"))
    }

    @Test func exactlyOneStepIsOpenAcrossPrerequisiteCombinations() {
        for ready in [false, true] {
            for automatic in [false, true] {
                for hasTake in [false, true] {
                    for request in WizardStepFlow.Step.allCases {
                        let flow = WizardStepFlow(confirmed: [.start, .sources, .outcome, .planning],
                            requestedStep: request, sourcesReady: ready, automatic: automatic,
                            hasTake: hasTake, takeIsValid: hasTake)
                        #expect(flow.canExpand(flow.openStep))
                        #expect(WizardStepFlow.Step.allCases.filter { !flow.isCollapsed($0) }.count == 1)
                    }
                }
            }
        }
    }

    @Test func headerClickTogglesTheVisibleStep() {
        var flow = prepared()
        #expect(flow.visibleStep == .moments)
        // Clicking the open header collapses it; nothing else opens.
        let collapse = flow.headerClick(.moments)
        #expect(collapse?.collapsed == .moments)
        flow.collapsedStep = collapse?.collapsed
        flow.requestedStep = collapse?.requested
        #expect(flow.visibleStep == nil)
        #expect(flow.isCollapsed(.moments))
        // Clicking it again reopens it.
        let reopen = flow.headerClick(.moments)
        #expect(reopen?.requested == .moments && reopen?.collapsed == nil)
        flow.collapsedStep = reopen?.collapsed
        flow.requestedStep = reopen?.requested
        #expect(flow.visibleStep == .moments)
        // Clicking another expandable header opens that one instead.
        let other = flow.headerClick(.outcome)
        #expect(other?.requested == .outcome)
        flow.requestedStep = other?.requested
        flow.collapsedStep = other?.collapsed
        #expect(flow.visibleStep == .outcome)
        // Headers behind a prerequisite ignore the click.
        #expect(flow.headerClick(.render) == nil)
        #expect(flow.visibleStep == .outcome)
    }
}
