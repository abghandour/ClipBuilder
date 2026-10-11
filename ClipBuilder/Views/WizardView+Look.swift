import SwiftUI

// Presentation-only choices for the current take (or the next Automatic run).
extension WizardView {
    @ViewBuilder var lookFields: some View {
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
                          systemImage: "music.note.list")
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
                FormCaption("Auto keeps clear of the platform buttons; the other choices use the edge of the frame.")
                    .formDependent()
                WizardControlRow("Caption style") {
                    CaptionStylePicker(selection: captionChoice(\.captionStyleID), profile: store.activeProfile)
                }
                .formDependent()
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

        if lookFormPlan.step2Controls.contains(.nameTags) {
            WizardControlRow("Name tags") { Toggle("Name tags", isOn: $nameTags) }
            if nameTags {
                NameTagControls(style: $nameTagStyleID, position: $nameTagPosition, profile: store.activeProfile)
                    .formDependent()
            }
        }
        if lookFormPlan.step2Controls.contains(.overlayStyle) {
            FormGroupHeader("Overlays")
            overlayControls
        }
        FormGroupHeader("Pacing and transitions")
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
        if lookCapabilities.bumpers {
            FormGroupHeader("Bumpers")
            bumperToggle("Include an intro", placement: .intro, value: $includeIntroBumper)
            bumperToggle("Include an outro", placement: .outro, value: $includeOutroBumper)
            bumperToggle("Include one at random in the middle", placement: .anywhere, value: $includeMiddleBumper)
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
        }

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
