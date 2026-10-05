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
                        if settings.cameraFocus.isEmpty, run.footageKind == .qa {
                            MiniModelButton(tasks: ["framing"])
                        }
                    }
                }
                FormCaption(settings.cameraFocus.isEmpty
                    ? (run.footageKind == .qa
                        ? "The AI picks the layout for each exchange when you generate."
                        : "Chosen by the highlights model when the candidates were found.")
                    : WizardCameraFocus.summary(settings.cameraFocus))
            }
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
            bumperToggle("Intro video", placement: .intro, value: $settings.introVideo)
            bumperToggle("Outro video", placement: .outro, value: $settings.outroVideo)
            if flow.showsNameTags {
                MiniRow("Name tags") {
                    Toggle("Name tags", isOn: $settings.nameTags)
                }
                if settings.nameTags {
                    MiniDependents {
                        NameTagControls(content: $settings.nameTagContent, style: $settings.nameTagStyle,
                                        position: $settings.nameTagPosition)
                    }
                }
            }
            MiniRow("Watermark") {
                Toggle("Watermark", isOn: $settings.watermark)
            }
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

    private var runSummary: String {
        flow.runSummary(candidates: run.candidates, exchangeCount: run.keptCount,
            settings: settings.effective(for: flow,
                introAvailable: store.bumpers.contains { $0.placements.contains(.intro) },
                outroAvailable: store.bumpers.contains { $0.placements.contains(.outro) }))
    }

    @ViewBuilder
    private func bumperToggle(_ title: String, placement: BumperPlacement, value: Binding<Bool>) -> some View {
        let available = store.bumpers.contains { $0.placements.contains(placement) }
        MiniRow(title) {
            Toggle(title, isOn: value)
        }
        .disabled(!available)
        if !available {
            FormCaption("No bumpers allow this placement. Add one in Resources → Bumpers.")
                .lineLimit(nil)
        }
    }
}
