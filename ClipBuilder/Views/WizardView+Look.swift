import SwiftUI

// Presentation-only choices for the current take (or the next Automatic run).
extension WizardView {
    private var safeAreaPlatformSelection: Binding<[SocialPlatform]> {
        Binding(get: {
            let selected = safeAreaPlatforms.split(separator: ",").compactMap { SocialPlatform(rawValue: String($0)) }
            return selected.isEmpty ? store.activeProfile.defaultRenderSettings.platformSafeArea.platforms : selected
        }, set: { safeAreaPlatforms = $0.map(\.rawValue).joined(separator: ",") })
    }

    /// Sound & music.
    @ViewBuilder var audioFields: some View {
        WizardControlRow(dubLanguage.isEmpty ? "Dub" : "Dub to \(DubLanguageChoices.name(dubLanguage))") {
            Toggle("Dub to \(DubLanguageChoices.name(dubLanguage.isEmpty ? DubLanguageChoices.defaultLanguage : dubLanguage))",
                   isOn: Binding(get: { !dubLanguage.isEmpty }, set: {
                       dubLanguage = $0 ? (store.editingDefaults.footage.dubLanguage ?? DubLanguageChoices.defaultLanguage) : ""
                   }))
                .lineLimit(1).fixedSize()
        }
        if !dubLanguage.isEmpty {
            DubLanguagePicker(language: Binding(get: { dubLanguage }, set: { dubLanguage = $0 ?? "" }))
                .formDependent()
        }
        if lookCapabilities.audioMusic {
            FormGroupHeader("Sound & music")
            WizardControlRow("Audio") {
                Picker("Audio", selection: audioModeBinding) {
                    ForEach(WizardAudioMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.audio)
            FieldCaption(WizardFieldHelp.audio)

            if audioMode.useMusic, !musicFolders.isEmpty {
                WizardControlRow("Music from") {
                    Picker("Music from", selection: $musicFolderRaw) {
                        Text("Whole library").tag("")
                        Divider()
                        ForEach(musicFolders, id: \.self) { folder in
                            Text(folder).tag(folder)
                        }
                    }
                }
                .fieldHelp(WizardFieldHelp.musicFolder)
                .formDependent()
            }

            if audioMode.useMusic {
                WizardControlRow("Track") {
                    Picker("Track", selection: $musicTrackRaw) {
                        Text("Automatic").tag("")
                        ForEach(musicTracks, id: \.self) { Text($0).tag($0) }
                    }
                }
                .formDependent()
                FormCaption("Automatic picks a track long enough for this take from the chosen folder.")
                    .formDependent()
            }
            if audioMode.useMusic && musicCount == 0 {
                HStack {
                    Label(musicFolderRaw.isEmpty
                          ? "No music has been added yet"
                          : "The “\(musicFolderRaw)” folder has no music — the whole library will be used",
                          systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Music") {
                        store.requestedSection = .music
                    }
                    .controlSize(.small).lineLimit(1).fixedSize()
                }
                .formDependent()
            }
        }

    }

    /// Captions, name tags, overlays and branding: everything drawn over the picture.
    @ViewBuilder var overlaysFields: some View {
        if lookCapabilities.onScreenText {
            FormGroupHeader("Captions & names")
            WizardControlRow("On-screen text") {
                Picker("On-screen text", selection: textModeBinding) {
                    ForEach(WizardTextMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.onScreenText)
            FieldCaption(WizardFieldHelp.onScreenText)

            if (textMode == .captions || textMode == .both), !lookTranscriptsAvailable {
                FormCaption("No transcript is available in these sources, so captions will be skipped.", tone: .warning)
                    .formDependent()
            }

            if textMode == .captions || textMode == .both {
                WizardControlRow("Caption position") {
                    CaptionPositionPicker(selection: captionChoice(\.captionPosition))
                }
                .formDependent()
                FormCaption("Auto keeps clear of the platform buttons. Safe area only also keeps explicit positions clear.")
                    .formDependent()
                WizardControlRow("Caption style") {
                    CaptionStylePicker(selection: captionChoice(\.captionStyleID), profile: store.activeProfile)
                }
                .formDependent()
                CaptionSpeakerStylesEditor(people: eligibleSourcePeople, videoIDs: nil,
                    runStyleID: captionStyleID, profile: store.activeProfile,
                    positions: speakerPositionChoices, ordinals: captionOrdinals)
                    .formDependent()
                if !dubLanguage.isEmpty {
                    FormCaption("Captions follow the dub language (\(DubLanguageChoices.name(dubLanguage))).")
                        .formDependent()
                } else {
                    WizardControlRow("Caption language") {
                        Picker("Caption language", selection: $captionLanguage) {
                            Text("Original audio language").tag("")
                            ForEach(store.activeProfile.captionLanguages, id: \.self) { language in
                                Text(Locale.current.localizedString(forIdentifier: language) ?? language)
                                    .tag(language)
                            }
                        }
                    }
                    .fieldHelp(WizardFieldHelp.captionLanguage)
                    .formDependent()
                    FieldCaption(WizardFieldHelp.captionLanguage)
                        .formDependent()
                }
            }
        }

        if lookFormPlan.step2Controls.contains(.nameTags) {
            WizardControlRow("Name tags") { Toggle("Name tags", isOn: $nameTags) }
            if nameTags {
                NameTagControls(style: $nameTagStyleID, position: $nameTagPosition, profile: store.activeProfile,
                                people: eligibleSourcePeople)
                    .formDependent()
            }
        }
        SafeAreaControls(enabled: $safeAreaOnly, platforms: safeAreaPlatformSelection)
        if lookFormPlan.step2Controls.contains(.overlayStyle) {
            FormGroupHeader("Overlays")
            overlayControls
            fixedOverlayRows
            if lookHasFightSources {
                StrikeStatsLookControls(enabled: $strikeStats, units: $strikeUnits,
                                        speedCallouts: $strikeSpeedCallouts,
                                        grapplingCard: $strikeGrapplingCard, roundCard: $strikeRoundCard)
            }
        }
        if lookCapabilities.branding {
            FormGroupHeader("Branding")
            WizardControlRow("Brand elements") {
                Picker("Brand elements", selection: brandingOverrideBinding) {
                    ForEach(WizardBrandingOverride.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
            .fieldHelp(WizardFieldHelp.branding)
            FieldCaption(WizardFieldHelp.branding)
            if store.activeProfile.logoPath.isEmpty,
               resolvedBranding.includeWatermark || resolvedBranding.includeOutro {
                FormCaption("No brand logo is set. Add one in Settings → Profile to use the watermark or outro.", tone: .warning)
                    .formDependent()
            }
            if resolvedBranding.includeWatermark { watermarkRows }
        }

    }

    /// Look, pacing and transitions, camera focus and B-roll.
    @ViewBuilder var pictureFields: some View {
        FormGroupHeader("Picture")
        WizardControlRow("Effect") { lookPicker }
        if !lookPresetRaw.isEmpty, lookPresetRaw != "none" {
            WizardControlRow("Effect strength") {
                HStack(spacing: Theme.spaceS) {
                    Slider(value: $lookIntensity, in: 0.05...1)
                        .frame(width: 160)
                        .accessibilityLabel("Effect strength")
                    Text("\(Int((lookIntensity * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .formDependent()
            FormCaption("Graded into every clip's footage; captions, name tags and overlays stay clean.")
                .formDependent()
        }
        FormGroupHeader("Pacing and transitions")
        WizardControlRow("Transition at every cut") { transitionChoicePicker }
        FormCaption(transitionChoiceRaw.isEmpty
            ? "The planner's cadence: hard cuts with an allowed effect every third boundary."
            : transitionChoiceRaw == WizardPlanRules.randomTransitionChoice
                ? "A different allowed effect at every cut." : "This effect at every cut between clips.")
        EditPacingControls(pacing: pacingBinding)
        HStack {
            Text(settingOrigin(edited: runPacing != nil, copied: copiedOptions?.pacing != nil))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Save as default") {
                store.activeProfile.defaultPacing = effectivePacing
                store.saveActiveProfile()
            }
            .controlSize(.small).lineLimit(1).fixedSize()
        }

        transitionControls
        if lookFormPlan.step2Controls.contains(.cameraFocus) {
            FormGroupHeader("Camera focus")
            WizardCameraFocusPicker(selection: cameraFocusBinding, allowsOriginal: lookCapabilities.offersOriginalFraming)
            if cameraFocusBinding.wrappedValue == CropRecipe.Kind.interview.rawValue {
                WizardControlRow("Shot changes") {
                    InterviewShotChangesPicker(cuts: $interviewCuts)
                }
                FormCaption(InterviewShotChangesPicker.caption)
                WizardControlRow("Punch in on") {
                    InterviewPunchInPicker(selection: $interviewPunchIn)
                }
                FormCaption(InterviewPunchInPicker.caption)
                WizardControlRow("Zoom in/out for focus") {
                    InterviewZoomMovesToggle(isOn: $interviewZoomMoves)
                }
                FormCaption(InterviewZoomMovesToggle.caption)
                if !interviewZoomMoves {
                    WizardControlRow("Pull back") {
                        InterviewZoomSlider(zoom: $interviewZoom)
                    }
                    FormCaption(InterviewZoomSlider.caption)
                }
            }
        }
        if lookFormPlan.step2Controls.contains(.framingCamera) {
            WizardControlRow("Framing camera") {
                Picker("Framing camera", selection: $framingCameraRaw) {
                    Text("Smooth").tag("smooth")
                    Text("Balanced").tag("balanced")
                    Text("Fast").tag("fast")
                }
            }
        }
        if lookFormPlan.step2Controls.contains(.bRoll) {
            FormGroupHeader("B-roll")
            WizardPodcastControls(plan: lookFormPlan, useBRoll: $useBRoll, instructions: $brollInstructions)
        }
    }

    /// Output count and bumpers: the wrapper around the reel.
    @ViewBuilder var packageFields: some View {
        WizardControlRow("Output") {
            Picker("Output", selection: $outputModeRaw) {
                ForEach(MiniWizardFlow.OutputMode.allCases, id: \.self) { mode in
                    Text(mode.label).lineLimit(1).fixedSize().tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        FormCaption(outputMode == .oneReel
            ? "The kept takes join into one reel, hard cuts between them unless a transition is chosen."
            : "Every kept selection becomes its own video.")
        if lookCapabilities.bumpers {
            FormGroupHeader("Bumpers")
            bumperToggle("Include an intro", placement: .intro, value: $includeIntroBumper, bumper: $introBumperLibraryPath)
            bumperToggle("Include an outro", placement: .outro, value: $includeOutroBumper, bumper: $outroBumperLibraryPath)
            bumperToggle("Include one at random in the middle", placement: .anywhere, value: $includeMiddleBumper)
        }

    }

    /// Which models the step 2 jobs use; shown under every tab.
    @ViewBuilder var aiModelFields: some View {
        if !lookFormPlan.step2Models(useBRoll: useBRoll, instructions: brollInstructions).isEmpty {
            DisclosureGroup(lookFormPlan.capabilities.podcastFraming
                ? "Caption, B-roll and camera focus AI settings" : "Caption and B-roll AI settings") {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    TaskModelPickers(tasks: lookFormPlan.step2Models(useBRoll: useBRoll, instructions: brollInstructions))
                }
                .padding(.top, Theme.spaceS)
            }
        }
    }

    /// The Generate panel: the run as a card, then the action.
    var generatePanel: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            RunSummaryCard(summary: wizardRunSummary, accessibilityText: generationSummary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.spaceM) {
                    generationAction
                    manualBuildAction
                }
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    generationAction
                    manualBuildAction
                }
            }
        }
    }

    /// The kept takes and the active choices, grouped like the Settings tabs.
    var wizardRunSummary: WizardRunSummary {
        let flow = cardFlow
        let count = flow.outputCount(oneReel: outputMode == .oneReel)
        let takes = flow.answers.keptSelectionCount
        guard takes > 0 else {
            return WizardRunSummary(headline: "No kept footage", length: nil, sections: [], hasFootage: false)
        }
        let source = [flow.answers.selectionName, flow.answers.takeLabel].compactMap { $0 }.joined(separator: ", ")
        let headline = (outputMode == .oneReel ? "One reel" : count == 1 ? "1 video" : "\(count) videos")
            + " from " + (source.isEmpty ? "the kept takes" : source + (takes > 1 ? " + \(takes - 1) more" : ""))
        let render = effectiveRenderSettings
        var picture = [render.quality.label, render.preset.label]
        if !lookPresetRaw.isEmpty, lookPresetRaw != "none" {
            picture.append(EffectCatalog.preset(for: lookPresetRaw)?.name ?? lookPresetRaw.replacingOccurrences(of: "lut:", with: ""))
        }
        picture.append(transitionChoiceRaw.isEmpty ? "Planner's cadence"
            : transitionChoiceRaw == WizardPlanRules.randomTransitionChoice ? "Random transitions"
            : (TransitionCatalog.all.first { $0.name == transitionChoiceRaw }?.title ?? transitionChoiceRaw) + " transitions")
        if lookFormPlan.step2Controls.contains(.cameraFocus) {
            picture.append(WizardCameraFocus.name(cameraFocusBinding.wrappedValue))
        }
        var audio: [String] = []
        if lookCapabilities.audioMusic {
            audio.append(audioMode.title)
            if audioMode.useMusic {
                audio.append(musicTrackRaw.isEmpty
                    ? (musicFolderRaw.isEmpty ? "Any track" : "Track from \(musicFolderRaw)") : "Track: \(musicTrackRaw)")
            }
        }
        var overlays: [String] = []
        if safeAreaOnly {
            overlays.append("Safe area: " + safeAreaPlatformSelection.wrappedValue.map(\.shortLabel).joined(separator: ", "))
        }
        if lookCapabilities.onScreenText, textMode != .none { overlays.append("Text: \(textMode.title)") }
        if lookFormPlan.step2Controls.contains(.nameTags), nameTags { overlays.append("Name tags") }
        if !fixedOverlayTemplate.isEmpty { overlays.append("Overlay \(fixedOverlayTemplate)") }
        if lookCapabilities.branding {
            if resolvedBranding.includeWatermark {
                overlays.append(watermarkOverlay.isEmpty ? "Watermark" : "Watermark \(watermarkOverlay)")
            }
            if resolvedBranding.includeHeadline { overlays.append("Headline") }
            if resolvedBranding.includeOutro { overlays.append("Outro card") }
        }
        var package: [String] = []
        if lookCapabilities.bumpers {
            if includeIntroBumper { package.append("Intro video") }
            if includeOutroBumper { package.append("Outro video") }
            if includeMiddleBumper { package.append("Middle bumper") }
        }
        package.append(outputMode.label)
        var sections = [WizardRunSummary.Section(title: "Picture", items: picture)]
        if !audio.isEmpty { sections.append(.init(title: "Audio", items: audio)) }
        sections.append(.init(title: "Overlays", items: overlays.isEmpty ? ["None"] : overlays))
        sections.append(.init(title: "Package", items: package))
        return WizardRunSummary(headline: headline, length: nil, sections: sections, hasFootage: true)
    }

    /// None, then the Looks and film-stock LUT presets the local ffmpeg can render.
    var lookPicker: some View {
        let available = EffectCatalog.presets.filter { preset in
            preset.id != "none" && (availableLookIDs?.contains(preset.id) ?? true)
        }
        let groups: [(title: String, presets: [EffectCatalog.Preset])] = [
            ("Effects", available.filter { $0.group == "looks" }),
            ("Film stocks", available.filter { $0.group == "film" }),
        ].filter { !$0.presets.isEmpty }
        return Picker("Effect", selection: $lookPresetRaw) {
            Text("None").lineLimit(1).fixedSize().tag("")
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.presets, id: \.id) { preset in
                        Text(preset.name).lineLimit(1).fixedSize().tag(preset.id)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .task { availableLookIDs = await EffectControls.availablePresetIDs() }
    }

    /// Planner cadence, Random, then every effect grouped by family.
    var transitionChoicePicker: some View {
        let groups: [(title: String, effects: [TransitionEffect])] = TransitionEffect.Category.allCases
            .filter { $0 != .cut }
            .map { category in (category.title, TransitionCatalog.all.filter { $0.category == category }) }
        return Picker("Transition at every cut", selection: $transitionChoiceRaw) {
            Text("Planner's cadence").lineLimit(1).fixedSize().tag("")
            Text("Random").lineLimit(1).fixedSize().tag(WizardPlanRules.randomTransitionChoice)
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.effects) { effect in
                        Text(effect.title).lineLimit(1).fixedSize().tag(effect.name)
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    private var savedOverlayTemplates: [OverlayTemplate] {
        OverlayTemplateStore.list().filter { !$0.composition.isEmpty }
    }

    /// Express's fixed overlay: a saved design over the finished video from a
    /// chosen second, for a chosen length or to the end, with its texts editable.
    /// Change one overlay text's edit in the stored JSON.
    private func updateOverlayTextEdit(_ textIndex: Int, _ change: (inout OverlayTextEdit) -> Void) {
        var edits = OverlayEdits.split(fixedOverlayEdits)
        edits.text(textIndex, change)
        fixedOverlayEdits = edits.joined
    }

    @ViewBuilder var fixedOverlayRows: some View {
        let templates = savedOverlayTemplates
        WizardControlRow("Fixed overlay") { Toggle("Fixed overlay", isOn: $fixedOverlayOn) }
            .disabled(templates.isEmpty)
        if templates.isEmpty {
            FormCaption("No saved overlays yet. Add one in Resources → Overlays.").formDependent()
        } else if fixedOverlayOn {
            let selected = templates.first { $0.name.caseInsensitiveCompare(fixedOverlayTemplate) == .orderedSame }?.name
                ?? templates.first?.name ?? ""
            let composition = templates.first { $0.name == selected }?.composition ?? OverlayComposition()
            let textIndices = WizardFixedOverlay.dynamicTextIndices(in: composition)
            let items = textIndices.map { composition.texts[$0] }
            let texts = items.map(\.text)
            WizardControlRow("Overlay design") {
                Picker("Overlay design", selection: Binding(get: { selected }, set: { name in
                    fixedOverlayTemplate = name
                    fixedOverlayTexts = WizardExpressExtras.joinedTexts(
                        templates.first { $0.name == name }.map { WizardFixedOverlay.dynamicTexts(in: $0.composition) } ?? [])
                    fixedOverlayEdits = ""
                })) {
                    ForEach(templates) { template in
                        Text(template.name).lineLimit(1).fixedSize().tag(template.name)
                    }
                }
                .pickerStyle(.menu)
            }
            .formDependent()
            .onAppear { if selected != fixedOverlayTemplate { fixedOverlayTemplate = selected } }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let original = item.text
                let textIndex = textIndices[index]
                WizardControlRow(texts.count == 1 ? "Text" : "Text \(index + 1)") {
                    HStack(spacing: Theme.spaceS) {
                        TextField(original, text: Binding(
                            get: { WizardExpressExtras.splitTexts(fixedOverlayTexts)[safe: index] ?? original },
                            set: { value in
                                var updated = WizardExpressExtras.splitTexts(fixedOverlayTexts)
                                while updated.count < texts.count { updated.append(texts[updated.count]) }
                                updated[index] = value
                                fixedOverlayTexts = WizardExpressExtras.joinedTexts(updated)
                            }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .accessibilityLabel("Overlay text \(index + 1)")
                        OverlayTextAlignmentPicker(alignment: Binding(
                            get: { OverlayEdits.split(fixedOverlayEdits).texts[safe: textIndex]?.alignment ?? item.alignment },
                            set: { value in
                                updateOverlayTextEdit(textIndex) { $0.alignment = value == item.alignment ? nil : value }
                            }))
                            .accessibilityLabel("Overlay text \(index + 1) alignment")
                        if OverlayEdits.split(fixedOverlayEdits).texts[safe: textIndex]?.box != nil {
                            Button("Reset placement", systemImage: "arrow.uturn.backward") {
                                updateOverlayTextEdit(textIndex) { $0.box = nil }
                            }
                            .labelStyle(.iconOnly).controlSize(.small)
                            .help("Put this text back where the design has it")
                            .accessibilityLabel("Reset overlay text \(index + 1) placement")
                        }
                    }
                }
                .formDependent()
            }
            WizardControlRow("Layout") {
                HStack(spacing: Theme.spaceS) {
                    let edited = !OverlayEdits.split(fixedOverlayEdits).isEmpty || CustomPosition.isCustom(fixedOverlayPosition)
                    Text(edited ? "Custom (dragged)" : "As designed")
                        .lineLimit(1).fixedSize()
                    Button("Reset layout", systemImage: "arrow.uturn.backward") {
                        fixedOverlayEdits = ""
                        fixedOverlayPosition = ""
                    }
                    .labelStyle(.iconOnly).controlSize(.small)
                    .disabled(!edited)
                    .help("Put every text and image back where the design has it")
                }
            }
            .formDependent()
            FormCaption("Each text and image of the design is its own object in the preview: drag it to move it, drag its edges to resize it.")
                .formDependent()
            WizardControlRow("Starts at") {
                HStack(spacing: Theme.spaceXS) {
                    TextField("Start", value: $fixedOverlayStart, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Overlay start")
                    Text("s").foregroundStyle(.secondary)
                }
            }
            .formDependent()
            WizardControlRow("Duration") {
                HStack(spacing: Theme.spaceS) {
                    Picker("Duration", selection: Binding(get: { fixedOverlayDuration <= 0 },
                                                         set: { whole in fixedOverlayDuration = whole ? 0 : 5 })) {
                        Text("Whole video").lineLimit(1).fixedSize().tag(true)
                        Text("Seconds").lineLimit(1).fixedSize().tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Overlay duration")
                    if fixedOverlayDuration > 0 {
                        TextField("Seconds", value: $fixedOverlayDuration, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .accessibilityLabel("Overlay seconds")
                        Text("s").foregroundStyle(.secondary)
                    }
                }
            }
            .formDependent()
            FormCaption("The overlay starts this many seconds into the finished video and stays on for the whole video unless you give it a length.")
                .formDependent()
        }
    }

    /// Express's watermark design and strength; the brand logo when no design is chosen.
    @ViewBuilder var watermarkRows: some View {
        let templates = savedOverlayTemplates
        if !templates.isEmpty {
            WizardControlRow("Watermark design") {
                Picker("Watermark design", selection: Binding(
                    get: { templates.contains { $0.name == watermarkOverlay } ? watermarkOverlay : "" },
                    set: { watermarkOverlay = $0 })) {
                    Text("Brand logo").lineLimit(1).fixedSize().tag("")
                    ForEach(templates) { template in
                        Text(template.name).lineLimit(1).fixedSize().tag(template.name)
                    }
                }
                .pickerStyle(.menu)
            }
            .formDependent()
        }
        let usesOverlay = !watermarkOverlay.isEmpty && templates.contains { $0.name == watermarkOverlay }
        let fallback = usesOverlay ? WizardFixedOverlay.watermarkOpacity : BrandRenderer.logoWatermarkOpacity
        let effective = watermarkOpacity > 0 ? min(1, watermarkOpacity) : fallback
        WizardControlRow("Watermark opacity") {
            HStack(spacing: Theme.spaceS) {
                Slider(value: Binding(get: { effective }, set: { watermarkOpacity = (($0 * 100).rounded()) / 100 }), in: 0.05...1)
                    .frame(width: 160)
                    .accessibilityLabel("Watermark opacity")
                Text("\(Int((effective * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .formDependent()
        FormCaption(usesOverlay ? "The overlay renders faded to this strength with no boxes or effects, for the whole video."
                                : "The brand logo sits top-left at this strength.")
            .formDependent()
    }

    var overlayControls: some View {
        Group {
            WizardControlRow("Overlay template") {
                Picker("Overlay template", selection: $overlayTemplateRaw) {
                    Text("Preset style").tag("")
                    ForEach(overlayTemplates, id: \.self) { Text($0).tag($0) }
                }
            }
            if overlayTemplateRaw.isEmpty {
                WizardControlRow("Overlay style") {
                    Picker("Overlay style", selection: $overlayStyleRaw) {
                        Text("Automatic").tag("")
                        ForEach(WizardTextStyle.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                }
                .formDependent()
            }
            WizardControlRow("Animation") {
                Picker("Animation", selection: $overlayAnimationRaw) {
                    Text("Automatic").tag("")
                    ForEach(WizardTextStyle.animations, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
            }
            WizardControlRow("Placement") {
                Picker("Placement", selection: $overlayPlacementRaw) {
                    Text("Automatic").tag("")
                    ForEach(WizardTextStyle.placements, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        }
    }

    var transitionControls: some View {
        DisclosureGroup("Allowed transitions") {
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                WizardControlRow("Use all approved transitions") {
                    Toggle("Use all approved transitions", isOn: Binding(get: { !limitTransitions }, set: { limitTransitions = !$0 }))
                }
                if limitTransitions {
                    ForEach(RenderEngine.allTransitions.filter { $0 != "cut" }, id: \.self) { name in
                        WizardControlRow(name.replacingOccurrences(of: "_", with: " ").capitalized) {
                            Toggle(name.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(get: {
                                transitionsRaw.split(separator: ",").map(String.init).contains(name)
                            }, set: { enabled in
                                var names = Set(transitionsRaw.split(separator: ",").map(String.init))
                                if enabled { names.insert(name) } else { names.remove(name) }
                                transitionsRaw = names.sorted().joined(separator: ",")
                                updateCopiedOption("allowedTransitions", .array(names.sorted().map(JSONSetting.string)))
                            }))
                        }
                        .formDependent()
                    }
                }
                FormCaption("Hard cuts form the backbone. Allowed effects add an accent every third boundary; no effects means cuts only.")
            }
            .padding(.top, Theme.spaceS)
        }
    }

}
