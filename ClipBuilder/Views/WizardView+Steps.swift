import SwiftUI

extension WizardView {
    var stepFlow: WizardStepFlow {
        let selection = store.currentWizardSelection
        let take = selection?.bestTake
        let recording = capabilities.sources == .podcastRecording
            ? store.videos.first { $0.path == highlightVideoPath } : nil
        var answers = WizardStepFlow.Answers()
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
        answers.savedSelectionCount = projectSelections.count
        answers.look = editingSummary + (lookCapabilities.offersCameraFocus
            ? " · " + WizardCameraFocus.name(cameraFocusBinding.wrappedValue) : "")
        let requested = store.pendingWizardPrompt?.statusMessage != nil ? WizardStepFlow.Step.start : requestedStep
        return WizardStepFlow(answers: answers, confirmed: confirmedSteps, requestedStep: requested, collapsedStep: collapsedStep,
            sourcesReady: !readiness.contains(where: \.isBlocking), needsFootageProposal: needsFootageProposal,
            automatic: reviewWorkflow == .automatic, hasTake: take != nil,
            takeIsValid: take.map { WizardSelectionRules.resolvedPlan($0.plan, scenes: SceneReferences.combining(store.referencedScenes, referenced: store.historyScenes)) != nil } ?? false,
            isBusy: store.isWizardRunning || isFindingFootage)
    }

    /// Filters stay live. This key only invalidates the user's acknowledgement;
    /// it never turns ordinary sources into pinned scene IDs.
    var sourceConfirmationKey: String {
        [formatPreset, highlightVideoPath, selectedRunIDsRaw, sourcePeopleRaw,
         String(limitToSelection), String(favoritesOnly), stackLevelRaw,
         proposedSceneIDs.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "live"]
            .joined(separator: "|")
    }

    var configurationForm: some View {
        let flow = stepFlow
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceL) {
                    ForEach(WizardStepFlow.Step.allCases, id: \.self) { step in
                        stepCard(step, flow: flow)
                            .id(step)
                    }
                }
                .padding(Theme.spaceXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: stepFlow.openStep) { _, step in
                collapsedStep = nil
                if step == .sources { sourceGridExpanded = true }
                if reduceMotion {
                    proxy.scrollTo(step, anchor: .top)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(step, anchor: .top) }
                }
            }
        }
        .environment(\.wizardStepRows, true)
        .toggleStyle(.switch)
        .textFieldStyle(.roundedBorder)
        .safeAreaInset(edge: .bottom, spacing: 0) { generationBar }
        .task(id: "\(store.profileGeneration):\(store.activeProjectID ?? 0):\(store.isWizardRunning):\(store.scenesVersion)") {
            await store.refreshWizardSelections()
        }
        .onChange(of: store.wizardLookRevision) { _, _ in
            confirmedSteps.remove(.look)
            requestedStep = .look
        }
        .onChange(of: store.currentWizardSelection?.bestTake?.id) { _, takeID in
            if takeID != nil {
                confirmedSteps.remove(.look)
                // A background refresh must not steal a card the user is editing.
                if requestedStep == .moments { requestedStep = nil }
            }
        }
        .confirmationDialog("Delete this selection and its takes? Rendered outputs are kept.",
            isPresented: Binding(get: { deletingSelection != nil }, set: { if !$0 { deletingSelection = nil } })) {
            Button("Delete selection", role: .destructive) {
                if let selection = deletingSelection { store.deleteWizardSelection(selection.id) }
                deletingSelection = nil
            }
        }
    }

    func stepCard(_ step: WizardStepFlow.Step, flow: WizardStepFlow) -> some View {
        let open = flow.visibleStep == step
        let prerequisite = flow.prerequisite(for: step)
        return MiniCard(number: step.rawValue, title: step.title,
            summary: prerequisite ?? flow.summary(for: step), isOpen: open, compactSummary: true,
            change: flow.canExpand(step) ? { collapsedStep = nil; requestedStep = step } : nil,
            headerTap: flow.canExpand(step) ? {
                guard let click = stepFlow.headerClick(step) else { return }
                requestedStep = click.requested
                collapsedStep = click.collapsed
            } : nil) {
                if open {
                    if step == .start, store.pendingWizardPrompt != nil {
                        generateRequestBanner
                    }
                    VStack(alignment: .leading, spacing: Theme.spaceM) {
                        stepContents(step)
                    }
                    .disabled(isFindingFootage)
                }
            }
    }

    @ViewBuilder func stepContents(_ step: WizardStepFlow.Step) -> some View {
        switch step {
        case .start:
            startStep
        case .sources:
            sourcesStep
        case .outcome:
            FormCaption("Choose what to make and the format to deliver it in.")
            outcomeFields
            continueStep(.outcome)
        case .planning:
            FormCaption("Tell the planner what matters. The brief is optional when starting from footage.")
            planningFields
            continueStep(.planning)
        case .moments:
            momentsStep
        case .look:
            FormCaption(store.currentWizardSelection == nil
                ? "Set the look for your next run. These choices are applied after the moments are found."
                : "Keep the chosen moments and change how the reel looks and sounds.")
            if let selection = store.currentWizardSelection, let take = selection.bestTake {
                takeAnchor(selection, take: take)
            }
            lookFields
            continueStep(.look)
        case .render:
            renderStep
        }
    }

    var startStep: some View {
        Group {
            FormCaption("Choose your starting point and where to pause for review.")
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
            continueStep(.start)
        }
    }

    var sourcesStep: some View {
        Group {
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
                continueStep(.sources)
            }
            Button("Choose a different outcome or recipe") { requestedStep = .outcome }
                .lineLimit(1).fixedSize()
                .help("Recipes may use analyzed scenes or one recording. Changing the recipe rechecks Sources.")
        }
    }

    var momentsStep: some View {
        Group {
            FormCaption("Find a set of moments, then keep and review its takes. Saved selections can be rendered again with another look.")
            if store.isWizardRunning {
                Label("Wizard is working. Progress and Stop are available below.", systemImage: "hourglass")
                    .font(.callout)
            }
            Button(needsFootageProposal ? "Find footage" : "Find the moments", systemImage: "wand.and.stars", action: findMoments)
                .lineLimit(1).fixedSize()
                .disabled(!canStart)
            if !canStart && !store.isWizardRunning {
                FormCaption("Review Sources to resolve the missing footage or AI setup.", tone: .warning)
                Button("Review Sources") { confirmedSteps.insert(.start); requestedStep = .sources }
                    .lineLimit(1).fixedSize()
            }
            selectionsRow
            if stepFlow.canContinue(.moments) {
                if store.currentWizardSelection == nil {
                    FormCaption("Automatic can find the moments and render in one run. Set the look before using Generate reel below.")
                }
                continueStep(.moments)
            }
        }
    }

    var renderStep: some View {
        Group {
            if let selection = store.currentWizardSelection, let take = selection.bestTake {
                takeAnchor(selection, take: take)
                FormCaption(stepFlow.summary(for: .look))
                FormCaption(effectiveRenderSettings.preset.label + " · " + effectiveRenderSettings.quality.label)
                if !stepFlow.canRenderTake && !store.isWizardRunning {
                    FormCaption("Footage changed. Open the selection and ask for another take.", tone: .warning)
                    Button("Open selection") {
                        store.openWizardSelection(selection.id, options: presentationOptions())
                    }
                    .lineLimit(1).fixedSize()
                }
                Button("Render", systemImage: "film") {
                    store.renderWizardSelection(selection.id, takeID: take.id, options: presentationOptions())
                }
                .lineLimit(1).fixedSize()
                .disabled(!stepFlow.canRenderTake)
            } else {
                FormCaption("Use the generation button below to find the moments and render with these settings.")
                FormCaption(stepFlow.summary(for: .outcome))
                FormCaption(stepFlow.summary(for: .look))
            }
            Button("Change output format") { confirmedSteps.insert(.start); requestedStep = .outcome }
                .lineLimit(1).fixedSize()
        }
    }

    func takeAnchor(_ selection: WizardSelectionSummary, take: WizardSelectionTake) -> some View {
        Text("From \(selection.selection.name) · \(WizardSelectionRules.takeLabel(take))")
            .font(.callout.weight(.medium))
            .lineLimit(1).truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(selection.selection.name) · \(WizardSelectionRules.takeLabel(take))")
    }

    func continueStep(_ step: WizardStepFlow.Step) -> some View {
        let next = stepFlow.nextStep(after: step)
        return Button("Continue to \(next.title.lowercased())") {
            confirmedSteps.insert(step)
            requestedStep = next
        }
        .lineLimit(1).fixedSize()
        .disabled(!stepFlow.canContinue(step))
        .padding(.top, Theme.spaceS)
    }

    func invalidateSourceConfirmation() {
        confirmedSteps.subtract([.sources, .planning, .moments])
    }

    func resetStepProgress() {
        confirmedSteps = []
        requestedStep = nil
        collapsedStep = nil
    }
}
