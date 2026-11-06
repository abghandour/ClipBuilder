import SwiftUI

/// The Overlays tab of Express's Settings card: overlay design, captions,
/// name tags, safe area and watermark, bound to a `MiniWizardSettings`.
/// The rough cut sheet shows the same rows bound to its own copy, so a cut
/// can be checked with them before they reach the page.
struct MiniOverlayRows: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    /// The recordings whose speakers the caption and name tag editors list.
    var videoIDs: [Int64]
    /// Podcast and interview footage shows the Name tags rows.
    var showsNameTags: Bool
    /// A non-English transcript with captions on shows Native / English.
    var showsCaptionLanguage: Bool

    private var safeAreaPlatforms: Binding<[SocialPlatform]> {
        Binding(get: {
            let selected = settings.safeAreaPlatforms?.compactMap(SocialPlatform.init(rawValue:)) ?? []
            return selected.isEmpty ? store.activeProfile.defaultRenderSettings.platformSafeArea.platforms : selected
        }, set: { settings.safeAreaPlatforms = $0.isEmpty ? nil : $0.map(\.rawValue) })
    }

    @ViewBuilder
    var body: some View {
        overlayRows
        MiniRow("Captions") {
            Toggle("Captions", isOn: $settings.captions)
        }
        if settings.captions {
            MiniDependents {
                MiniRow("Caption position") {
                    // A menu: five segments, one of them "Custom (dragged)", outgrow the control column.
                    CaptionPositionPicker(selection: $settings.captionPosition)
                        .pickerStyle(.menu).fixedSize()
                }
                FormCaption("Auto keeps clear of the platform buttons. Safe area only also keeps explicit positions clear.")
                MiniRow("Caption style") {
                    CaptionStylePicker(selection: $settings.captionStyleID, profile: store.activeProfile)
                }
                CaptionSpeakerStylesEditor(people: nil, videoIDs: videoIDs,
                    runStyleID: settings.captionStyleID, profile: store.activeProfile, positions: $settings.speakerCaptionPositions)
                if settings.dub {
                    FormCaption("Captions follow the dub language.")
                } else if showsCaptionLanguage {
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
        if showsNameTags {
            MiniRow("Name tags") {
                HStack {
                    Toggle("Name tags", isOn: $settings.nameTags)
                    if settings.nameTags { MiniModelButton(tasks: ["tag_text"]) }
                }
            }
            if settings.nameTags {
                MiniDependents {
                    NameTagControls(style: $settings.nameTagStyleID,
                                    position: $settings.nameTagPosition, profile: store.activeProfile,
                                    videoIDs: videoIDs)
                }
            }
        }
        SafeAreaControls(enabled: $settings.safeAreaOnly, platforms: safeAreaPlatforms)
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
                MiniRow("Layout") {
                    HStack(spacing: Theme.spaceS) {
                        let edited = !settings.overlayEdits.isEmpty || CustomPosition.isCustom(settings.overlayPosition)
                        Text(edited ? "Custom (dragged)" : "As designed")
                            .lineLimit(1).fixedSize()
                        Button("Reset Layout", systemImage: "arrow.uturn.backward") {
                            settings.overlayEdits = OverlayEdits()
                            settings.overlayPosition = nil
                        }
                        .labelStyle(.iconOnly).controlSize(.small)
                        .disabled(!edited)
                        .help("Put every text and image back where the design has it")
                    }
                }
                FormCaption("Each text and image of the design is its own object in the preview: drag it to move it, drag its edges to resize it. Text wraps to its box.")
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
        let composition = templates.first { $0.name == overlaySelection(in: templates) }?.composition ?? OverlayComposition()
        let textIndices = WizardFixedOverlay.dynamicTextIndices(in: composition)
        let items = textIndices.map { composition.texts[$0] }
        let texts = items.map(\.text)
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            let original = item.text
            let textIndex = textIndices[index]
            MiniRow(texts.count == 1 ? "Text" : "Text \(index + 1)") {
                HStack(spacing: Theme.spaceS) {
                    NewlineTextField(prompt: original, text: Binding(
                        get: { settings.overlayTexts[safe: index] ?? original },
                        set: { value in
                            var updated = settings.overlayTexts
                            while updated.count < texts.count { updated.append(texts[updated.count]) }
                            updated[index] = value
                            settings.overlayTexts = updated
                        }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .help("Return starts a new line in the overlay")
                        .accessibilityLabel("Overlay text \(index + 1)")
                    OverlayTextAlignmentPicker(alignment: Binding(
                        get: { settings.overlayEdits.texts[safe: textIndex]?.alignment ?? item.alignment },
                        set: { value in
                            settings.overlayEdits.text(textIndex) { $0.alignment = value == item.alignment ? nil : value }
                        }))
                        .accessibilityLabel("Overlay text \(index + 1) alignment")
                    if settings.overlayEdits.texts[safe: textIndex]?.box != nil {
                        Button("Reset placement", systemImage: "arrow.uturn.backward") {
                            settings.overlayEdits.text(textIndex) { $0.box = nil }
                        }
                        .labelStyle(.iconOnly).controlSize(.small)
                        .help("Put this text back where the design has it")
                        .accessibilityLabel("Reset overlay text \(index + 1) placement")
                    }
                }
            }
        }
        if !texts.isEmpty {
            FormCaption("These are the texts the overlay lets the AI Wizard replace. Edit them here; the other items keep their words.")
                .lineLimit(nil)
        }
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
        dynamicTextItems(of: name, in: templates).map(\.text)
    }

    private func dynamicTextItems(of name: String, in templates: [OverlayTemplate]) -> [TextOverlayItem] {
        templates.first { $0.name == name }.map { WizardFixedOverlay.dynamicTextItems(in: $0.composition) } ?? []
    }

    /// Choosing a design resets the text fields to that design's own words
    /// and drops the previous design's alignments and resized boxes.
    private func selectOverlay(_ name: String, in templates: [OverlayTemplate]) {
        settings.overlayTemplate = name
        settings.overlayTexts = dynamicTexts(of: name, in: templates)
        settings.overlayEdits = OverlayEdits()
    }
}
