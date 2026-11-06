import SwiftUI

struct MiniSettingsCard: View {
    @Environment(AppStore.self) private var store
    @Binding var settings: MiniWizardSettings
    /// The open tab, remembered per profile by the page.
    @Binding var tab: MiniWizardFlow.SettingsTab
    let flow: MiniWizardFlow
    let run: MiniWizardRun
    /// Presets the local ffmpeg can render. Probing ffmpeg spawns a process,
    /// so it runs once off the main thread; until then every look is listed.
    @State private var availableLookIDs: Set<String>?
    /// Root-relative names of the music library's tracks, read once off the main thread.
    @State private var musicTracks: [String]?

    var body: some View {
        let tabs = flow.settingsTabs
        let current = flow.effectiveSettingsTab(tab)
        // No rules between rows: the gap alone separates them.
        VStack(alignment: .leading, spacing: SettingsRowMetrics.plainRowSpacing) {
            PageTabs(tabs: tabs, selection: Binding(get: { current }, set: { tab = $0 }),
                     label: \.label, rowSpacing: SettingsRowMetrics.plainRowSpacing) { tab in
                switch tab {
                case .picture: pictureRows
                case .audio: audioRows
                case .overlays:
                    MiniOverlayRows(settings: $settings, videoIDs: [run.video.id],
                                    showsNameTags: flow.showsNameTags, showsCaptionLanguage: flow.showsCaptionLanguage)
                case .package: packageRows
                }
            }
            .accessibilityLabel("Settings")
        }
        .environment(\.formCaptionIndent, SettingsRowMetrics.labelWidth + Theme.spaceM)
        .environment(\.settingsRowDividers, false)
        .environment(\.settingsDetailBelow, true)
        .disabled(store.isWizardRunning)
    }

    /// How the footage itself is encoded, framed and graded.
    @ViewBuilder
    private var pictureRows: some View {
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
        FramingRows(framing: $settings.framing, type: run.video.type ?? .other, videoIDs: [run.video.id],
                    canvasAspect: Double(settings.preset.width ?? 1080) / Double(settings.preset.height ?? 1920))
        if settings.framing.subject == .auto, run.footageKind != .highlights {
            MiniModelButton(tasks: ["framing"])
        }
        MiniRow("Effect") {
            lookPicker
        }
        FormCaption(settings.lookName == nil
            ? "Grades the footage of every clip with an effect from the Effects library."
            : "Graded into every clip's footage; captions, name tags and overlays stay clean.")
        MiniRow("Transition") {
            transitionPicker
        }
        FormCaption(settings.transition == WizardPlanRules.randomTransitionChoice
            ? "Used at every cut between clips. Random picks a different effect at each cut."
            : "Used at every cut between clips.")
    }

    /// Everything drawn over the picture: the headline, the words, the brand.
    /// The wrapper around the reel and how many files come out.
    @ViewBuilder
    private var packageRows: some View {
        bumperToggle("Intro video", placement: .intro, value: $settings.introVideo,
                     bumper: $settings.introBumper)
        bumperToggle("Outro video", placement: .outro, value: $settings.outroVideo,
                     bumper: $settings.outroBumper)
        if flow.isPodcastOrInterview {
            MiniRow("Include B-roll") {
                Toggle("Include B-roll", isOn: $settings.includesBRoll)
                    .labelsHidden().toggleStyle(.checkbox)
                    .lineLimit(1).fixedSize()
            }
        }
        FormCaption("Every kept pick is cut into one video, in list order.")
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

    /// Dubbing for every source; mute and music keep their fight/training rules.
    @ViewBuilder
    private var audioRows: some View {
        if flow.showsAudioOptions {
            MiniRow("Mute source audio") {
                Toggle("Mute source audio", isOn: $settings.muteSourceAudio)
            }
            FormCaption(settings.muteSourceAudio
                ? "Muted: the reel plays without the recording's sound."
                : "Off: the crowd, the commentary and the impacts stay in.")
            MiniRow("Music") {
                Toggle("Music", isOn: $settings.music)
            }
            if settings.music {
                MiniDependents {
                    MiniRow("Track") {
                        Picker("Track", selection: Binding(
                            get: { settings.musicTrackName ?? "" },
                            set: { settings.musicTrack = $0.isEmpty ? nil : $0 })) {
                            Text("Random").tag("")
                            if let musicTracks, !musicTracks.isEmpty {
                                Divider()
                                ForEach(musicTracks, id: \.self) { track in
                                    Text(track).lineLimit(1).truncationMode(.middle).tag(track)
                                }
                            } else if let name = settings.musicTrackName {
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Track")
                    }
                    FormCaption(musicTracks?.isEmpty == true
                        ? "The music library is empty; add tracks under Resources → Music."
                        : settings.musicTrackName == nil
                            ? "Random picks a track that fits the reel's length."
                            : settings.muteSourceAudio ? "Music only." : "Mixed under the source audio.")
                }
                .task {
                    let tracks = await Task.detached { WizardEngine.availableMusic().map(\.name) }.value
                    musicTracks = tracks
                    if let chosen = settings.musicTrackName, !tracks.contains(chosen) { settings.musicTrack = nil }
                }
            }
        }
        MiniRow("Dub") {
            Toggle("Dub", isOn: $settings.dub)
        }
        if settings.dub {
            MiniDependents { DubLanguagePicker(language: $settings.dubLanguage) }
        }
    }

    /// None, then the Looks and film-stock LUT presets the local ffmpeg can render.
    private var lookPicker: some View {
        let available = EffectCatalog.presets.filter { preset in
            preset.id != "none" && (availableLookIDs?.contains(preset.id) ?? true)
        }
        let groups: [(title: String, presets: [EffectCatalog.Preset])] = [
            ("Effects", available.filter { $0.group == "looks" }),
            ("Film stocks", available.filter { $0.group == "film" }),
        ].filter { !$0.presets.isEmpty }
        return Picker("Effect", selection: $settings.look) {
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

/// Left, centre, right for one of a fixed overlay's replaceable texts;
/// shared by the Express card and the Wizard's Look step.
struct OverlayTextAlignmentPicker: View {
    @Binding var alignment: String

    var body: some View {
        Picker("Alignment", selection: $alignment) {
            Label("Left", systemImage: "text.alignleft").tag("left")
            Label("Center", systemImage: "text.aligncenter").tag("center")
            Label("Right", systemImage: "text.alignright").tag("right")
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Where this text sits in its box")
    }
}
