import SwiftUI

// The four cards (Source, Plan, Footage, Settings) and their navigation.
// WizardCardFlow owns the pure rules; the answers and actions stay on WizardView.
extension WizardView {
    /// The videos the current source choice covers.
    var sourceVideoIDs: Set<Int64> {
        if capabilities.sources == .podcastRecording {
            return Set(store.videos.filter { $0.path == highlightVideoPath }.map(\.id))
        }
        return Set(sourcePool.map(\.videoID))
    }

    /// Saved selections whose footage comes from the chosen sources (all of
    /// them when the user asked to see everything).
    var visibleSelections: [WizardSelectionSummary] {
        guard !showAllSelections else { return projectSelections }
        return WizardFootageReview.selections(projectSelections, usingVideos: sourceVideoIDs,
            scenes: SceneReferences.combining(store.referencedScenes, referenced: store.historyScenes))
    }

    /// The selection the Settings card renders: the active one when it is visible.
    var visibleSelection: WizardSelectionSummary? {
        visibleSelections.first { $0.id == store.activeWizardSelectionID } ?? visibleSelections.first
    }

    var cardFlow: WizardCardFlow {
        let selection = visibleSelection
        let take = selection?.bestTake
        let recording = capabilities.sources == .podcastRecording
            ? store.videos.first { $0.path == highlightVideoPath } : nil
        var answers = WizardCardFlow.Answers()
        answers.fromIdea = fromIdea
        answers.workflow = reviewWorkflow.title
        answers.pastedFrom = pastedSnapshot.isEmpty ? nil : pastedSourceName
        answers.requestStatus = store.pendingWizardPrompt?.statusMessage
        answers.sourceCount = sourcePool.count
        answers.videoCount = capabilities.sources == .podcastRecording
            ? (recording == nil ? 0 : 1) : Set(sourcePool.map(\.videoID)).count
        answers.recordingName = recording?.filename
        answers.sourceDetail = sourceSummary
        answers.outcome = workflow.title
        answers.recipe = recipe.title
        if capabilities.length == .maxSecondsAndCount {
            let count = highlightMaxCount == 0 ? "All highlights" : "Up to \(highlightMaxCount) highlights"
            answers.length = "\(count) · up to \(Int(highlightMaxSeconds))s each"
        } else {
            answers.length = durationMode == .custom ? "\(customDuration)s" : durationMode.title
        }
        answers.format = effectiveRenderSettings.preset.label
        answers.brief = aiInstructions
        answers.planning = capabilities.styleReference
            ? (tastePreset == "none" ? "No style reference" : tastePreset.isEmpty ? "Profile taste"
                : store.activeProfile.tasteCategories.first { "cat:\($0.key)" == tastePreset }?.label ?? "Style reference")
            : ""
        answers.selectionName = selection?.selection.name
        answers.takeLabel = take.map(WizardSelectionRules.takeLabel)
        answers.takeCount = selection?.takes.count ?? 0
        answers.savedSelectionCount = visibleSelections.count
        answers.keptSelectionCount = visibleSelections.count { $0.selection.bestTakeID != nil }
        answers.look = editingSummary + (lookCapabilities.offersCameraFocus
            ? " · " + WizardCameraFocus.name(cameraFocusBinding.wrappedValue) : "")
        let requested = store.pendingWizardPrompt?.statusMessage != nil ? WizardCardFlow.Card.source : requestedCard
        return WizardCardFlow(answers: answers, requestedCard: requested, collapsedCard: collapsedCard,
            sourcesReady: !readiness.contains(where: \.isBlocking), needsFootageProposal: needsFootageProposal,
            automatic: reviewWorkflow == .automatic, hasTake: take != nil,
            takeIsValid: take.map { WizardSelectionRules.resolvedPlan($0.plan, scenes: SceneReferences.combining(store.referencedScenes, referenced: store.historyScenes)) != nil } ?? false,
            isBusy: store.isWizardRunning || isFindingFootage)
    }

    var configurationForm: some View {
        let flow = cardFlow
        return ScrollViewReader { proxy in
            GeometryReader { page in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceL) {
                    ForEach(WizardCardFlow.Card.allCases, id: \.self) { card in
                        wizardCard(card, flow: flow, pageHeight: page.size.height)
                            .id(card)
                    }
                    // As in Express: once takes are kept, the summary and Generate
                    // live in their own panel that no collapse can hide.
                    if flow.settingsRenders {
                        MiniCard(number: 5, title: "Generate", summary: "", isOpen: true) {
                            generatePanel
                        }
                        .id("generate")
                    }
                }
                .padding(Theme.spaceXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .onChange(of: requestedCard) { _, card in
                collapsedCard = nil
                if card == .source { sourceGridExpanded = true }
                if reduceMotion {
                    proxy.scrollTo(card, anchor: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(card, anchor: .top) }
                }
            }
        }
        .environment(\.wizardStepRows, true)
        .toggleStyle(.switch)
        .textFieldStyle(.roundedBorder)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !flow.settingsRenders || store.isWizardRunning || isFindingFootage { generationBar }
        }
        .task(id: "\(store.profileGeneration):\(store.activeProjectID ?? 0):\(store.isWizardRunning):\(store.scenesVersion)") {
            await store.refreshWizardSelections()
        }
        .onChange(of: store.wizardLookRevision) { _, _ in open(.settings) }
        .confirmationDialog("Delete this selection and its takes? Rendered outputs are kept.",
            isPresented: Binding(get: { deletingSelection != nil }, set: { if !$0 { deletingSelection = nil } })) {
            Button("Delete selection", role: .destructive) {
                if let selection = deletingSelection { store.deleteWizardSelection(selection.id) }
                deletingSelection = nil
            }
        }
    }

    /// Navigate to a card; clears a collapse so the card is visible.
    func open(_ card: WizardCardFlow.Card) {
        collapsedCard = nil
        requestedCard = card
    }

    func resetCardProgress() {
        requestedCard = .source
        collapsedCard = nil
    }

    func wizardCard(_ card: WizardCardFlow.Card, flow: WizardCardFlow, pageHeight: CGFloat = 800) -> some View {
        let open = flow.visibleCard == card
        return MiniCard(number: card.rawValue, title: card == .settings ? presetTitle : card.title,
            summary: flow.summary(for: card), isOpen: open, compactSummary: true,
            headerTap: {
                let click = cardFlow.headerClick(card)
                requestedCard = click.requested
                collapsedCard = click.collapsed
            }, accessory: card == .settings ? AnyView(presetButtons) : nil) {
                if open {
                    if card == .source, store.pendingWizardPrompt != nil {
                        generateRequestBanner
                    }
                    VStack(alignment: .leading, spacing: Theme.spaceM) {
                        if let prerequisite = flow.prerequisite(for: card) {
                            FormCaption(prerequisite)
                            Button("Open 1 Source") { self.open(.source) }
                                .lineLimit(1).fixedSize()
                        } else {
                            cardContents(card, pageHeight: pageHeight)
                        }
                    }
                    .disabled(isFindingFootage)
                }
            }
    }

    @ViewBuilder func cardContents(_ card: WizardCardFlow.Card, pageHeight: CGFloat = 800) -> some View {
        switch card {
        case .source:
            sourceCard
        case .plan:
            FormCaption("What to make and what the planner is told: outcome, recipe, length, format, brief and planning preferences.")
            outcomeFields
            planningFields
        case .footage:
            footageCard(pageHeight: pageHeight)
        case .settings:
            FormCaption(store.currentWizardSelection == nil
                ? "How the reel looks and sounds. Generate finds the moments and renders with these settings."
                : "Keep the chosen moments and change how the reel looks and sounds, then Generate.")
            if let selection = visibleSelection, let take = selection.bestTake {
                takeAnchor(selection, take: take)
                if !cardFlow.canRenderTake && !store.isWizardRunning {
                    FormCaption("Footage changed. Open the selection and ask for another take.", tone: .warning)
                    Button("Open selection") {
                        store.openWizardSelection(selection.id, options: presentationOptions())
                    }
                    .lineLimit(1).fixedSize()
                }
            }
            settingsTabs
        }
    }

    /// The same four tabs as Express: Picture, Audio (where the recipe has
    /// sound choices), Overlays, Package. The open tab is remembered.
    @ViewBuilder var settingsTabs: some View {
        let tabs = WizardSettingsTab.available(audio: lookCapabilities.audioMusic)
        let current = (WizardSettingsTab(rawValue: settingsTabRaw) ?? .picture).effective(in: tabs)
        Picker("Settings", selection: Binding(get: { current }, set: { settingsTabRaw = $0.rawValue })) {
            ForEach(tabs, id: \.self) { tab in
                Text(tab.label).lineLimit(1).fixedSize().tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Settings")
        switch current {
        case .picture: pictureFields
        case .audio: audioFields
        case .overlays: overlaysFields
        case .package: packageFields
        }
        aiModelFields
    }

    var sourceCard: some View {
        Group {
            if !enteredWithHandoff {
                WizardControlRow("Start with") {
                    Picker("Start with", selection: $entryMode) {
                        Text("From footage").tag("footage")
                        Text("From an idea").tag("idea")
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                FormCaption("Using the footage or reference you brought into the Wizard.")
            }
            WizardControlRow("Workflow") {
                Picker("Workflow", selection: $reviewWorkflowRaw) {
                    ForEach(WizardWorkflow.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }
            if !pastedSnapshot.isEmpty {
                HStack(spacing: Theme.spaceM) {
                    Label("Pasted from \(pastedSourceName)", systemImage: "doc.on.clipboard")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Clear") { AISettingsPreferences.clearWizardPaste(defaults: .standard) }
                        .lineLimit(1).fixedSize()
                }
            }
            Divider()
            if needsFootageProposal {
                FormCaption("Describe your idea to find matching footage in this project.")
                briefFields
                Button("Find footage", systemImage: "wand.and.stars", action: startGeneration)
                    .lineLimit(1).fixedSize()
                    .disabled(!canStart)
                if store.scenes.isEmpty {
                    FormCaption("Analyze footage in this project before matching an idea.", tone: .warning)
                    Button("Open Sources") { store.requestedSection = .sources }
                        .lineLimit(1).fixedSize()
                }
            } else {
                sourceFields
            }
        }
    }

    func footageCard(pageHeight: CGFloat) -> some View {
        Group {
            FormCaption("Find a set of moments, then watch each take, drag its cuts and keep the one to render. Ask for another take with a note; every selection stays saved for later looks.")
            if store.isWizardRunning {
                Label("Wizard is working. Progress and Stop are available below.", systemImage: "hourglass")
                    .font(.callout)
            }
            HStack(spacing: Theme.spaceS) {
                Button(needsFootageProposal ? "Find footage" : "Find the moments", systemImage: "wand.and.stars", action: findMoments)
                    .lineLimit(1).fixedSize()
                    .disabled(!canStart)
                MiniModelButton(tasks: [capabilities.sources == .podcastRecording ? "highlights" : "wizard"])
            }
            if !canStart && !store.isWizardRunning {
                FormCaption("Review 1 Source to resolve the missing footage or AI setup.", tone: .warning)
                Button("Open 1 Source") { open(.source) }
                    .lineLimit(1).fixedSize()
            }
            let hidden = projectSelections.count - visibleSelections.count
            if hidden > 0 || showAllSelections {
                HStack(spacing: Theme.spaceS) {
                    FormCaption(showAllSelections
                        ? "Showing every saved selection, including footage outside the current sources."
                        : "\(hidden) saved \(hidden == 1 ? "selection uses" : "selections use") footage outside the current sources.")
                    Button(showAllSelections ? "Match the sources" : "Show all") { showAllSelections.toggle() }
                        .controlSize(.small).lineLimit(1).fixedSize()
                }
            }
            if visibleSelections.isEmpty {
                FormCaption(projectSelections.isEmpty
                    ? "No saved selection yet. Find the moments to review and keep takes here."
                    : "No saved selection uses the chosen sources. Find the moments for them, or Show all.")
            } else {
                Divider()
                WizardFootageReviewView(selections: visibleSelections, options: presentationOptions())
                    .id("\(store.activeProjectID ?? 0):\(store.scenesVersion):\(visibleSelections.map(\.id))")
                    .frame(maxWidth: .infinity)
                    .frame(height: max(560, pageHeight - 220))
                    .padding(.horizontal, -Theme.spaceS)
                    .disabled(store.isWizardRunning)
            }
        }
    }

    func takeAnchor(_ selection: WizardSelectionSummary, take: WizardSelectionTake) -> some View {
        Text("From \(selection.selection.name) · \(WizardSelectionRules.takeLabel(take))")
            .font(.callout.weight(.medium))
            .lineLimit(1).truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(selection.selection.name) · \(WizardSelectionRules.takeLabel(take))")
    }
}
