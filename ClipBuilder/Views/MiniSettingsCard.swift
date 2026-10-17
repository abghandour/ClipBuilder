import SwiftUI

struct MiniSettingsCard: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    let flow: MiniWizardFlow
    let run: MiniWizardRun

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            MiniRow("Quality") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach([EncodeQuality.archival, .balanced, .compact]) { quality in
                        Text(quality.label).lineLimit(1).fixedSize().tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Quality")
            }
            MiniRow("Canvas") {
                Picker("Canvas", selection: $settings.preset) {
                    ForEach(RenderPreset.allCases.filter { $0 != .custom }) { preset in
                        Text(preset.label).lineLimit(1).fixedSize().tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }
            if flow.showsCameraFocus {
                MiniRow("Camera focus") {
                    HStack(spacing: Theme.spaceS) {
                        WizardCameraFocusPicker(selection: $settings.cameraFocus, allowsOriginal: true,
                                                showsSummary: false)
                            .pickerStyle(.menu)
                        if settings.cameraFocus.isEmpty, run.footageKind != .highlights {
                            MiniModelButton(tasks: ["framing"])
                        }
                    }
                }
                FormCaption(settings.cameraFocus.isEmpty
                    ? (run.footageKind != .highlights
                        ? "The AI picks the layout for each \(run.footageKind == .qa ? "exchange" : "pick") when you generate."
                        : "Chosen by the highlights model when the candidates were found.")
                    : WizardCameraFocus.summary(settings.cameraFocus))
            }
            overlayRows
            MiniRow("Captions") {
                Toggle("Captions", isOn: $settings.captions)
            }
            if settings.captions {
                MiniDependents {
                    MiniRow("Caption position") {
                        CaptionPositionPicker(selection: $settings.captionPosition)
                            .pickerStyle(.segmented)
                    }
                    FormCaption("Auto keeps clear of the platform buttons; the other choices use the edge of the frame.")
                    MiniRow("Caption style") {
                        CaptionStylePicker(selection: $settings.captionStyleID, profile: store.activeProfile)
                    }
                    if flow.showsCaptionLanguage {
                        MiniRow("Caption language") {
                            HStack(spacing: Theme.spaceS) {
                                Picker("Caption language", selection: $settings.englishCaptions) {
                                    Text("Native").lineLimit(1).fixedSize().tag(false)
                                    Text("English").lineLimit(1).fixedSize().tag(true)
                                }
                                .pickerStyle(.segmented)
                                .accessibilityLabel("Caption language")
                                // Lines macOS cannot translate on device go to this model.
                                MiniModelButton(tasks: ["translate"])
                            }
                        }
                    }
                }
            }
            if flow.showsNameTags {
                MiniRow("Name tags") {
                    HStack {
                        Toggle("Name tags", isOn: $settings.nameTags)
                        if settings.nameTags { MiniModelButton(tasks: ["tag_text"]) }
                    }
                }
                if settings.nameTags {
                    MiniDependents {
                        NameTagControls(style: $settings.nameTagStyleID,
                                        position: $settings.nameTagPosition, profile: store.activeProfile)
                    }
                }
            }
            MiniRow("Watermark") {
                Toggle("Watermark", isOn: $settings.watermark)
            }
            if settings.watermark {
                let templates = overlayTemplates
                MiniDependents {
                    if !templates.isEmpty {
                        MiniRow("Watermark design") {
                            Picker("Watermark design", selection: Binding(
                                get: { templates.contains { $0.name == settings.watermarkOverlay } ? settings.watermarkOverlay ?? "" : "" },
                                set: { settings.watermarkOverlay = $0.isEmpty ? nil : $0 })) {
                                Text("Brand logo").lineLimit(1).fixedSize().tag("")
                                ForEach(templates) { template in
                                    Text(template.name).lineLimit(1).fixedSize().tag(template.name)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .onAppear {
                            // A design that was renamed or removed: really fall back to the logo.
                            if let chosen = settings.watermarkOverlay, !templates.contains(where: { $0.name == chosen }) {
                                settings.watermarkOverlay = nil
                            }
                        }
                    }
                    MiniRow("Watermark opacity") {
                        HStack(spacing: Theme.spaceS) {
                            Slider(value: Binding(
                                get: { settings.effectiveWatermarkOpacity },
                                set: { settings.watermarkOpacity = (($0 * 100).rounded()) / 100 }), in: 0.05...1)
                                .frame(width: 160)
                                .accessibilityLabel("Watermark opacity")
                            Text("\(Int((settings.effectiveWatermarkOpacity * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    FormCaption(settings.watermarkOverlay?.isEmpty == false
                        ? "The overlay renders faded to this strength with no boxes or effects, for the whole video."
                        : "The brand logo sits top-left at this strength.")
                        .lineLimit(nil)
                }
            }
            bumperToggle("Intro video", placement: .intro, value: $settings.introVideo,
                         bumper: $settings.introBumper)
            bumperToggle("Outro video", placement: .outro, value: $settings.outroVideo,
                         bumper: $settings.outroBumper)
            MiniRow("Transition") {
                transitionPicker
            }
            FormCaption(settings.transition == WizardPlanRules.randomTransitionChoice
                ? "Used at every cut between clips. Random picks a different effect at each cut."
                : "Used at every cut between clips.")
            MiniRow("Output") {
                Picker("Output", selection: $settings.outputMode) {
                    ForEach(MiniWizardFlow.OutputMode.allCases, id: \.self) { mode in
                        Text(mode.label).lineLimit(1).fixedSize().tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Output")
            }
            FormCaption(runSummary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                .help(runSummary)
            HStack(spacing: Theme.spaceS) {
                Button {
                    store.generateMiniVideos(settings: settings, flow: flow, batchID: run.batchID)
                } label: {
                    Text(flow.generateButtonTitle(keptCount: run.keptCount)).lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(run.keptCount == 0)
                // Each rendered video gets its post text from this model.
                MiniModelButton(tasks: ["captions"])
            }
        }
        .disabled(store.isWizardRunning)
    }

    /// Overlay: a saved template over the finished video, from a chosen
    /// second, for a chosen length or to the end.
    @ViewBuilder
    private var overlayRows: some View {
        let templates = overlayTemplates
        MiniRow("Overlay") {
            Toggle("Overlay", isOn: $settings.overlay)
        }
        .disabled(templates.isEmpty)
        if templates.isEmpty {
            FormCaption("No overlays yet. Add one in Resources → Overlays.")
                .lineLimit(nil)
        } else if settings.overlay {
            MiniDependents {
                MiniRow("Overlay design") {
                    Picker("Overlay design", selection: Binding(
                        get: { overlaySelection(in: templates) },
                        set: { selectOverlay($0, in: templates) })) {
                        ForEach(templates) { template in
                            Text(template.name).lineLimit(1).fixedSize().tag(template.name)
                        }
                    }
                    .pickerStyle(.menu)
                }
                overlayTextRows(in: templates)
                MiniRow("Starts at") {
                    HStack(spacing: Theme.spaceXS) {
                        TextField("Start", value: $settings.overlayStart, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .accessibilityLabel("Overlay start")
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                MiniRow("Duration") {
                    HStack(spacing: Theme.spaceS) {
                        Picker("Duration", selection: Binding(
                            get: { settings.overlayDuration == nil },
                            set: { whole in settings.overlayDuration = whole ? nil : 5 })) {
                            Text("Whole video").lineLimit(1).fixedSize().tag(true)
                            Text("Seconds").lineLimit(1).fixedSize().tag(false)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Overlay duration")
                        if settings.overlayDuration != nil {
                            TextField("Seconds", value: Binding(
                                get: { settings.overlayDuration ?? 5 },
                                set: { settings.overlayDuration = max(0, $0) }),
                                format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .accessibilityLabel("Overlay seconds")
                            Text("s").foregroundStyle(.secondary)
                        }
                    }
                }
                FormCaption("The overlay starts this many seconds into the finished video and stays on for the whole video unless you give it a length.")
                    .lineLimit(nil)
            }
            .onAppear {
                // A remembered design that was renamed or removed falls back to the first one.
                let selected = overlaySelection(in: templates)
                if selected != settings.overlayTemplate { selectOverlay(selected, in: templates) }
                let count = dynamicTexts(of: selected, in: templates).count
                if settings.overlayTexts.count != count { selectOverlay(selected, in: templates) }
            }
        }
    }

    /// One field per text the template lets the AI Wizard replace, prefilled
    /// with the template's own words so the user only edits what should change.
    @ViewBuilder
    private func overlayTextRows(in templates: [OverlayTemplate]) -> some View {
        let texts = dynamicTexts(of: overlaySelection(in: templates), in: templates)
        ForEach(Array(texts.enumerated()), id: \.offset) { index, original in
            MiniRow(texts.count == 1 ? "Text" : "Text \(index + 1)") {
                TextField(original, text: Binding(
                    get: { settings.overlayTexts[safe: index] ?? original },
                    set: { value in
                        var updated = settings.overlayTexts
                        while updated.count < texts.count { updated.append(texts[updated.count]) }
                        updated[index] = value
                        settings.overlayTexts = updated
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Overlay text \(index + 1)")
            }
        }
        if !texts.isEmpty {
            FormCaption("These are the texts the overlay lets the AI Wizard replace. Edit them here; the other items stay as designed.")
                .lineLimit(nil)
        }
    }

    /// Random, then every effect grouped by family (no plain cut: the row
    /// exists to put an effect at each cut).
    private var transitionPicker: some View {
        let groups: [(title: String, effects: [TransitionEffect])] = TransitionEffect.Category.allCases
            .filter { $0 != .cut }
            .map { category in (category.title, TransitionCatalog.all.filter { $0.category == category }) }
        return Picker("Transition", selection: $settings.transition) {
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

    private var overlayTemplates: [OverlayTemplate] {
        OverlayTemplateStore.list().filter { !$0.composition.isEmpty }
    }

    private func overlaySelection(in templates: [OverlayTemplate]) -> String {
        let chosen = settings.overlayTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return templates.first { $0.name.caseInsensitiveCompare(chosen) == .orderedSame }?.name
            ?? templates.first?.name ?? ""
    }

    private func dynamicTexts(of name: String, in templates: [OverlayTemplate]) -> [String] {
        templates.first { $0.name == name }.map { WizardFixedOverlay.dynamicTexts(in: $0.composition) } ?? []
    }

    /// Choosing a design resets the text fields to that design's own words.
    private func selectOverlay(_ name: String, in templates: [OverlayTemplate]) {
        settings.overlayTemplate = name
        settings.overlayTexts = dynamicTexts(of: name, in: templates)
    }

    private var runSummary: String {
        flow.runSummary(candidates: run.candidates, exchangeCount: run.keptCount,
            settings: settings.effective(for: flow,
                introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
                outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) }))
    }

    /// The toggle, then (when on) a menu of the bumpers that allow this
    /// placement. "Any" keeps the planner's pick; a chosen bumper that was
    /// removed falls back to Any.
    @ViewBuilder
    private func bumperToggle(_ title: String, placement: BumperPlacement, value: Binding<Bool>,
                              bumper: Binding<String?>) -> some View {
        let eligible = store.bumpers.filter { $0.placements.contains(placement) }
        MiniRow(title) {
            Toggle(title, isOn: value)
        }
        .disabled(eligible.isEmpty)
        if eligible.isEmpty {
            FormCaption("No bumpers allow this placement. Add one in Resources → Bumpers.")
                .lineLimit(nil)
        } else if value.wrappedValue {
            MiniDependents {
                MiniRow("\(placement == .intro ? "Intro" : "Outro") bumper") {
                    Picker(title, selection: Binding(
                        get: { eligible.contains { $0.libraryPath == bumper.wrappedValue } ? bumper.wrappedValue ?? "" : "" },
                        set: { bumper.wrappedValue = $0.isEmpty ? nil : $0 })) {
                        Text("Any").lineLimit(1).fixedSize().tag("")
                        ForEach(eligible) { asset in
                            Text(asset.displayName).lineLimit(1).fixedSize().tag(asset.libraryPath)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("\(title) bumper")
                }
            }
        }
    }
}
