import SwiftUI

// Source, outcome and planning controls; bindings and actions belong to WizardView.
extension WizardView {
    @ViewBuilder var outcomeFields: some View {
        WizardControlRow("Outcome") {
            Picker("Outcome", selection: workflowBinding) {
                ForEach(ReelRecipe.Workflow.allCases) { workflow in
                    Text(workflow.title).tag(workflow)
                }
            }
        }
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .help("Choose one take, or let the content critic compare takes on small previews. Only the best take is rendered.")
        if workflow == .iterate {
            WizardControlRow("Target score: \(critiqueTargetScore)") {
                Stepper("Target score", value: $critiqueTargetScore, in: 60...95, step: 5)
            }
            .formDependent()
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            WizardControlRow("Attempts: \(critiqueMaxVersions)") {
                Stepper("Attempts", value: $critiqueMaxVersions, in: 2...5)
            }
            .formDependent()
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            FormCaption("The critic can request a better version until it approves or the attempt limit is reached. Every version is kept in the Library.")
                .formDependent()
        }
        if WizardFormPlan.showsCriticBriefControls(outcome: workflow) { CriticBriefControls() }
        WizardControlRow("Recipe") {
            Picker("Recipe", selection: $formatPreset) {
                ForEach(Array(ReelRecipe.menuSections(workflow: workflow, preferredSources: capabilities.sources).enumerated()), id: \.offset) { index, section in
                    if index > 0 { Divider() }
                    ForEach(section) { recipe in
                        Text(recipe.title).tag(recipe.id)
                    }
                }
            }
        }
        .fieldHelp(WizardFieldHelp.recipe)

        if let recipe = ReelRecipe.recipe(id: formatPreset) {
            FormCaption(recipe.summary)
        }

        if capabilities.length == .maxSecondsAndCount {
            WizardControlRow("Maximum highlights") {
                Picker("Maximum highlights", selection: $highlightMaxCount) {
                    Text("No limit").tag(0)
                    Text("Choose a count").tag(max(1, highlightMaxCount))
                }
            }
            if highlightMaxCount > 0 {
                WizardControlRow("Up to \(highlightMaxCount) highlights") {
                    Stepper("Maximum highlights", value: $highlightMaxCount, in: 1...Int.max)
                }
                .formDependent()
            }
            WizardControlRow("Maximum reel length: \(Int(highlightMaxSeconds))s") {
                Stepper("Maximum reel length", value: $highlightMaxSeconds, in: 5...120, step: 1)
            }
            FormCaption("Every candidate is reviewed before rendering. No captions, branding or music.")
        }

        if capabilities.length == .targetDuration {
            WizardControlRow("Length") {
                Picker("Length", selection: durationModeBinding) {
                    ForEach(WizardDurationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            .fieldHelp(WizardFormPlan.lengthHelp(recipe: recipe))
            FieldCaption(WizardFormPlan.lengthHelp(recipe: recipe))

            if durationMode == .custom {
                HStack {
                    Text("Custom length").lineLimit(1).fixedSize()
                    Spacer()
                    TextField("Seconds", value: $customDuration, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 58)
                        .fieldHelp(WizardFieldHelp.customLength)
                    Stepper("Custom length", value: $customDuration, in: 3...180)
                        .labelsHidden()
                        .fieldHelp(WizardFieldHelp.customLength)
                    Text("seconds")
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .formDependent()
            }
        }
        FormGroupHeader("Output format")
        RenderSettingsControls(settings: renderSettingsBinding)
        HStack {
            Text(settingOrigin(edited: runRenderSettings != nil, copied: copiedOptions?.renderSettings != nil))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Save as default") {
                store.activeProfile.defaultRenderSettings = effectiveRenderSettings
                store.saveActiveProfile()
            }
            .controlSize(.small).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder var planningFields: some View {
        FormGroupHeader("Brief")
        briefFields
        if !pastedSnapshot.isEmpty {
            DisclosureGroup("Copied planning details") {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    ForEach(["pinnedOverlayText", "templateLabel"], id: \.self) { key in
                        let title = key == "pinnedOverlayText" ? "Exact on-screen wording" : "Reference label"
                        WizardControlRow(title) {
                            TextField(title, text: Binding(get: {
                                AISettingsJSON.decode([String: JSONSetting].self, pastedSnapshot)?[key]?.string ?? ""
                            }, set: { updateCopiedOption(key, $0.isEmpty ? .null : .string($0)) }))
                                .frame(idealWidth: 220, maxWidth: 320)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.top, Theme.spaceS)
            }
        }
        FormGroupHeader("Planning preferences")
        if formPlan.step1Controls.contains(.fightResearch) {
            WizardControlRow("Fight research and learned rules") {
                Toggle("Fight research and learned rules", isOn: fightResearchBinding)
            }
        }
        if capabilities.styleReference {
            WizardControlRow("Style reference") {
                Picker("Style reference", selection: $tastePreset) {
                    Text("Profile taste").tag("")
                    Text("No style reference").tag("none")
                    if !store.activeProfile.tasteCategories.isEmpty {
                        Divider()
                        ForEach(store.activeProfile.tasteCategories) { category in
                            Text(category.label).tag("cat:\(category.key)")
                        }
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.styleReference)
            FieldCaption(WizardFieldHelp.styleReference)
        }

        if capabilities.layouts {
            WizardControlRow("Layouts") {
                Picker("Layouts", selection: layoutModeBinding) {
                    ForEach(WizardLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.layouts)
            if layoutMode == .selected {
                layoutChecklist.formDependent()
            } else {
                FormCaption(layoutMode == .singleScene
                     ? "Every clip fills the frame on its own."
                     : "Layouts approved under Resources → Screen Crop may be used.")
                    .formDependent()
            }
        }

        DisclosureGroup("Planning AI settings") {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                TaskModelPickers(tasks: formPlan.step1Models)
                WizardControlRow("Model override") {
                    TextField("Model override", text: $copiedModelOverride, prompt: Text("Automatic"))
                        .frame(idealWidth: 220, maxWidth: 320)
                        .textFieldStyle(.roundedBorder)
                        .fieldHelp(WizardFieldHelp.modelOverride)
                }
                FormCaption("Routing rows are shared defaults saved to Settings. Model override applies to planning for this run.")
            }
            .padding(.top, Theme.spaceS)
        }
    }

    var sourceFields: some View {
        Group {
            if reviewingIdea {
                Text("Review the matched footage, then confirm below to continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let proposedSceneIDs, capabilities.sources == .scenes {
                restrictionChip("Idea match: \(proposedSceneIDs.count) scenes") { self.proposedSceneIDs = nil }
            }
            if capabilities.sources == .podcastRecording {
                // One recording at a time: clicking another swaps, clicking
                // the selected one clears.
                WizardSourceGrid(videos: podcastHighlightVideos,
                                 selectedPaths: highlightVideoPath.isEmpty ? [] : [highlightVideoPath],
                                 isExpanded: $sourceGridExpanded,
                                 subtitle: { recordingSubtitle($0) }) { video in
                    highlightVideoPath = highlightVideoPath == video.path ? "" : (video.path ?? "")
                }
            } else {
                HStack {
                    Text("\(sourcePool.count) usable scenes · \(Set(sourcePool.map(\.videoID)).count) videos")
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Edit") { showSourcePicker = true }
                        .lineLimit(1).fixedSize()
                        .focused($sourcesFocused)
                }
                // Nothing is selected until a video is clicked; the picks are
                // remembered across launches. "All" in the picker turns the
                // batch limit off and every analyzed video contributes.
                WizardSourceGrid(videos: analyzedVideos,
                                 selectedPaths: Set(analyzedVideos.filter(videoContributes).compactMap(\.path)),
                                 isExpanded: $sourceGridExpanded,
                                 subtitle: { analyzedSubtitle($0) }) { video in
                    toggleVideo(video)
                }
                Text(sourceSummary).font(.caption).foregroundStyle(.secondary)
                if favoritesOnly {
                    restrictionChip("Favorites only") { favoritesOnly = false }
                }
                if limitToSelection {
                    restrictionChip("Selected Analyze batches: \(selectedRunIDs.count)") { limitToSelection = false }
                }
                WizardSourceEvidence(scenes: Array(sourcePool.prefix(6)),
                    people: projectPeople.filter { selectedSourcePeople.contains($0.key) })
                copiedSourceRestrictions
                Text(framingStatus).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(readiness.enumerated()), id: \.offset) { _, item in
                if case let .warning(message, action) = item {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(action.rawValue) { recover(action) }
                            .controlSize(.small).lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    @ViewBuilder var briefFields: some View {
        TextField(recipe.briefPrompt, text: $aiInstructions, axis: .vertical)
            .lineLimit(3...6)
            .textFieldStyle(.roundedBorder)
            .fieldHelp(WizardFieldHelp.instructions(for: recipe))
        if capabilities.referenceTemplate, let handoff = store.pendingWizardTemplate {
            referenceTemplateChip(handoff)
        }
    }

    var selectionsRow: some View {
        Group {
            FormGroupHeader("Selections")
            if projectSelections.isEmpty {
                FormCaption("Find the moments to save a selection you can return to and render in different styles.")
            } else {
                ForEach(projectSelections) { summary in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.spaceM) {
                            selectionIdentity(summary)
                            Spacer(minLength: Theme.spaceS)
                            selectionActions(summary)
                        }
                        VStack(alignment: .leading, spacing: Theme.spaceS) {
                            selectionIdentity(summary)
                            selectionActions(summary)
                        }
                    }
                    .disabled(store.isWizardRunning)
                    Divider()
                }
            }
        }
    }

    func selectionIdentity(_ summary: WizardSelectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            Button(summary.selection.name) {
                store.openWizardSelection(summary.id, options: presentationOptions(for: summary))
            }
            .buttonStyle(.link)
            .lineLimit(1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(summary.selection.name)
            Text("\(summary.takes.count) \(summary.takes.count == 1 ? "take" : "takes") · \(summary.selection.editedAt ?? "")")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
    }

    func selectionActions(_ summary: WizardSelectionSummary) -> some View {
        HStack(spacing: Theme.spaceS) {
            Button("Use selection") {
                store.activeWizardSelectionID = summary.id
                open(.settings)
            }
            .lineLimit(1).fixedSize()
            .disabled(summary.bestTake == nil)
            .help("Choose this selection’s best take and customize its look")
            Button("Delete selection", systemImage: "trash") { deletingSelection = summary }
                .labelStyle(.iconOnly).help("Delete selection")
        }
    }

    var generateRequestBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Generate Video Request", systemImage: "wand.and.stars")
                .font(.headline)
            Text("“\(store.pendingWizardPrompt?.description ?? "")”")
            if let pendingStatus = store.pendingWizardPrompt?.statusMessage {
                let line = store.jobs.running.last(where: {
                    $0.kind == .generateRequest && $0.projectID == store.activeProjectID
                })?.statusLine ?? ""
                let status = line.isEmpty ? pendingStatus : line
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            } else if store.pendingWizardPrompt?.parseFailed == true {
                Label(store.pendingWizardPrompt?.proposesFootage == true
                      ? "Couldn't finish interpreting the idea. Review Sources and the original brief before continuing."
                      : "Couldn't interpret the request with AI — it was added to the brief as written.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(store.pendingWizardPrompt?.statusMessage != nil ? "Stop" : "Close") {
                    store.cancelGenerateRequest()
                }
                .lineLimit(1).fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
    }

}
