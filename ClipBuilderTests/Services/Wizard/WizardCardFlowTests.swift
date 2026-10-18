import Testing
@testable import Clip_Builder

@Suite("Wizard card flow")
struct WizardCardFlowTests {
    @Test("Four cards in Express order")
    func cards() {
        #expect(WizardCardFlow.Card.allCases.map(\.rawValue) == [1, 2, 3, 4])
        #expect(WizardCardFlow.Card.allCases.map(\.title) == ["Source", "Plan", "Footage", "Settings"])
    }

    @Test("Any card opens on request, even before its inputs exist")
    func anyCardOpens() {
        var flow = WizardCardFlow()
        #expect(flow.openCard == .source && flow.visibleCard == .source)
        for card in WizardCardFlow.Card.allCases {
            flow.requestedCard = card
            #expect(flow.openCard == card)
            #expect(WizardCardFlow.Card.allCases.filter { !flow.isCollapsed($0) } == [card])
        }
    }

    @Test("Footage explains the missing sources instead of refusing; Settings never blocks")
    func prerequisites() {
        var flow = WizardCardFlow()
        #expect(flow.prerequisite(for: .source) == nil && flow.prerequisite(for: .plan) == nil)
        #expect(flow.prerequisite(for: .settings) == nil)
        #expect(flow.prerequisite(for: .footage) == "Choose usable sources in 1 Source first.")
        #expect(!flow.canExpand(.footage))
        flow.sourcesReady = true
        #expect(flow.canExpand(.footage))
        flow.needsFootageProposal = true
        #expect(flow.prerequisite(for: .footage) == "Describe the idea and find matching footage in 1 Source first.")
        // Saved selections stay reachable with an empty source pool.
        var saved = WizardCardFlow()
        saved.answers.savedSelectionCount = 2
        #expect(saved.canExpand(.footage))
    }

    @Test("Header clicks toggle the open card and reopen a collapsed one")
    func headerClicks() {
        var flow = WizardCardFlow(requestedCard: .plan)
        let collapse = flow.headerClick(.plan)
        #expect(collapse.requested == .plan && collapse.collapsed == .plan)
        flow.collapsedCard = collapse.collapsed
        #expect(flow.visibleCard == nil)
        #expect(WizardCardFlow.Card.allCases.allSatisfy(flow.isCollapsed))
        let reopen = flow.headerClick(.plan)
        #expect(reopen.requested == .plan && reopen.collapsed == nil)
        flow.collapsedCard = nil
        let other = flow.headerClick(.settings)
        #expect(other.requested == .settings && other.collapsed == nil)
        flow.requestedCard = other.requested
        #expect(flow.visibleCard == .settings)
    }

    @Test("Summaries describe the answers and the take")
    func summaries() {
        var answers = WizardCardFlow.Answers()
        answers.sourceCount = 12
        answers.videoCount = 2
        answers.sourceDetail = "Favorites only"
        answers.outcome = "One reel"
        answers.recipe = "Fight highlights"
        answers.length = "20s"
        answers.format = "Portrait 1080"
        answers.brief = "\n  Big finishes only\nsecond line"
        answers.look = "Captions · music"
        var flow = WizardCardFlow(answers: answers)
        #expect(flow.summary(for: .source) == "12 scenes · 2 videos · Favorites only")
        #expect(flow.summary(for: .plan) == "One reel · Fight highlights · 20s · Portrait 1080 · Big finishes only")
        #expect(flow.summary(for: .footage) == "Generate finds the moments, or find them here first")
        #expect(flow.summary(for: .settings) == "Captions · music")
        flow.automatic = false
        #expect(flow.summary(for: .footage) == "No saved selection yet")
        flow.answers.recordingName = "episode.mp4"
        flow.answers.fromIdea = true
        flow.answers.pastedFrom = "Reel 4"
        #expect(flow.summary(for: .source) == "1 recording · episode.mp4 · From an idea · Pasted from Reel 4")
        flow.needsFootageProposal = true
        #expect(flow.summary(for: .source) == "Find matching footage for your idea")
        flow.answers.selectionName = "Knockouts"
        flow.answers.takeLabel = "Take 2"
        flow.answers.takeCount = 2
        flow.hasTake = true
        #expect(flow.summary(for: .footage) == "Knockouts · Take 2 · 2 takes")
        #expect(!flow.canRenderTake)
        flow.takeIsValid = true
        #expect(flow.summary(for: .settings) == "Knockouts · Take 2 · Captions · music")
        #expect(flow.canRenderTake && !flow.settingsRenders)
        flow.answers.keptSelectionCount = 1
        #expect(flow.settingsRenders)
        flow.isBusy = true
        #expect(!flow.canRenderTake)
        flow.takeIsValid = false
        #expect(flow.summary(for: .settings) == "Footage changed · open the selection for another take · Captions · music")
    }

    @Test("Generate renders the kept selections, one video each or one reel")
    func generateFromKeptSelections() {
        var flow = WizardCardFlow()
        #expect(!flow.settingsRenders && flow.outputCount(oneReel: false) == 0)
        flow.answers.keptSelectionCount = 1
        #expect(flow.settingsRenders)
        #expect(flow.generateTitle(oneReel: false) == "Generate Video")
        flow.answers.keptSelectionCount = 3
        flow.answers.savedSelectionCount = 4
        flow.answers.selectionName = "Knockouts"
        flow.answers.takeLabel = "Take 1"
        flow.answers.takeCount = 1
        flow.hasTake = true
        #expect(flow.generateTitle(oneReel: false) == "Generate Videos")
        #expect(flow.generateTitle(oneReel: true) == "Generate Video")
        #expect(flow.outputCount(oneReel: false) == 3 && flow.outputCount(oneReel: true) == 1)
        #expect(flow.summary(for: .footage) == "Knockouts · Take 1 · 1 take · 3 of 4 selections kept")
    }
}
