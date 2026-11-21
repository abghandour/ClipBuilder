import AVFoundation
import SwiftUI

/// One recording: listen, where it sits, its caption text (which the user
/// can correct, in the spoken language and in the caption language) and its
/// own Delete.
struct VoiceOverRow: View {
    let take: VoiceTake
    /// Where it sits in the reel on screen; nil when its footage is not in it.
    let start: Double?
    /// The caption language when it differs from the one spoken.
    let captionLanguage: String?
    let playing: Bool
    let listen: () -> Void
    let select: (() -> Void)?
    let setText: (String) -> Void
    /// The text and the language code it is in.
    let setTranslation: (String, String) -> Void
    let delete: () -> Void

    @State private var text = ""
    @State private var translation = ""
    /// The text each field last asked the library to save, until it comes back.
    @State private var textSent: [String] = []
    @State private var translationSent: [String] = []
    /// The language the translation field's text is in. It follows the
    /// caption language, after what was typed for the one before is saved.
    @State private var translationFor: String?
    @FocusState private var focus: Field?
    private enum Field { case text, translation }

    private var translationCode: String? {
        guard let captionLanguage, !captionLanguage.isEmpty, !take.language.isEmpty else { return nil }
        let code = ProjectLanguageResolver.languageCode(captionLanguage)
        return code == take.language ? nil : code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            HStack(spacing: Theme.spaceS) {
                Button(playing ? "Stop" : "Listen", systemImage: playing ? "stop.fill" : "play.fill", action: listen)
                    .labelStyle(.iconOnly)
                    .help(playing ? "Stop this recording" : "Listen to this recording")
                Group {
                    if let start {
                        Text(WizardPreviewClips.clock(start)).monospacedDigit()
                    } else {
                        Text("Not in the reel").foregroundStyle(.secondary)
                            .help("The footage this was recorded over is no longer in the reel, so Generate leaves it out")
                    }
                }
                .lineLimit(1).fixedSize()
                Text(String(format: "%.1f s", take.duration))
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    .labelStyle(.iconOnly)
                    .help("Delete this recording")
            }
            .contentShape(Rectangle())
            .onTapGesture { select?() }
            caption
        }
        .padding(Theme.spaceS)
        .background(RoundedRectangle(cornerRadius: Theme.mediaRadius).fill(.quaternary.opacity(0.5)))
        .opacity(start == nil ? 0.6 : 1)
        .onAppear {
            text = take.text
            translation = translated
            translationFor = translationCode
        }
        // What the library stores decides everything: a field that says
        // something else is unsaved, whatever was typed on the way there.
        // A caption or translation that arrives shows at once unless the
        // user has typed something else; the field's own save coming back
        // never replaces what is being typed.
        .onChange(of: take.text) { old, new in
            text = Self.arrived(new, replacing: old, field: text, sent: &textSent, editing: focus == .text)
        }
        .onChange(of: translated) { old, new in
            // A change of language is handled below, whichever of the two runs first.
            guard translationFor == translationCode else { return }
            translation = Self.arrived(new, replacing: old, field: translation, sent: &translationSent,
                                       editing: focus == .translation)
        }
        // Another caption language: what was typed is saved in the language
        // it was typed for, and the field shows the new language's text.
        .onChange(of: translationCode) {
            commitTranslation()
            translationFor = translationCode
            translationSent = []
            translation = translated
        }
        .onChange(of: focus) { old, _ in
            if old == .text {
                commitText()
                // Only the spacing differs from what is stored: nothing will arrive to tidy the field.
                if Self.tidy(text) == take.text { text = take.text }
            }
            if old == .translation {
                commitTranslation()
                if Self.tidy(translation) == translated { translation = translated }
            }
        }
        // The sheet or the tab can close with the caret still in a field.
        .onDisappear {
            guard take.state != .pending else { return }
            commitText()
            commitTranslation()
        }
    }

    private var translated: String {
        translationCode.flatMap { take.translations[$0]?.text } ?? ""
    }

    /// Text as the library stores it: single spaces, none at the ends.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a field shows once `new` is stored in place of `old`. `sent`
    /// holds the texts this field asked to save that have not come back yet, oldest first.
    static func arrived(_ new: String, replacing old: String, field: String, sent: inout [String], editing: Bool) -> String {
        if let index = sent.firstIndex(of: new) {
            // The field's own save (and any before it, which it replaced):
            // while the caret is in the field the typing stays as it is.
            sent.removeFirst(index + 1)
            return editing ? field : (tidy(field) == new ? new : field)
        }
        // Someone else's text (a caption just written, a translation): it
        // shows unless the field holds something the user typed.
        return tidy(field) == old ? new : field
    }

    /// Saves the field when it differs from what is stored. A field only
    /// visited saves nothing, and a save that failed is tried again by the
    /// next Return, click away or close, because the stored text is still the old one.
    private func commitText() {
        let tidied = Self.tidy(text)
        guard tidied != take.text else { return }
        textSent.append(tidied)
        setText(text)
    }

    /// In the language the field's text was typed for, which during a
    /// change of caption language is not yet the one on screen.
    private func commitTranslation() {
        guard let code = translationFor else { return }
        let tidied = Self.tidy(translation)
        guard tidied != (take.translations[code]?.text ?? "") else { return }
        translationSent.append(tidied)
        setTranslation(translation, code)
    }

    @ViewBuilder private var caption: some View {
        switch take.state {
        case .pending:
            HStack(spacing: Theme.spaceS) {
                ProgressView().controlSize(.small)
                Text("Writing the caption…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        default:
            TextField("Caption", text: $text,
                      prompt: Text(take.state == .failed ? "The caption could not be written; type it here"
                                                         : "No speech found; type the caption here"),
                      axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .text)
                .onSubmit { commitText() }
                .help("What the captions show for this recording. Correct it here if a word is wrong.")
            if let code = translationCode, !take.text.isEmpty {
                TextField("Caption in \(Locale.current.localizedString(forLanguageCode: code) ?? code)", text: $translation,
                          prompt: Text("\(Locale.current.localizedString(forLanguageCode: code) ?? code): translated when the reel is generated"),
                          axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .translation)
                    .onSubmit { commitTranslation() }
                    .help("The translated caption. Correct it here; a correction is never translated over.")
            }
        }
    }
}

/// The recordings of one Express reel, with the count, Undo after a delete,
/// and any message from the recorder.
struct VoiceOverList: View {
    @Environment(AppStore.self) private var store
    /// The reel this list is for. The library is shared: while it holds
    /// another reel's recordings this list shows none of them.
    let owner: VoiceOverLibrary.Owner
    /// Reel start per take id; nil shows each take where it was recorded.
    let starts: [String: Double]?
    let captionLanguage: String?
    var select: ((Double) -> Void)? = nil
    var emptyText = "No recordings yet."

    var body: some View {
        let library = store.voiceOver
        let mine = library.owner == owner
        let takes = mine ? library.takes : []
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                Text("Recordings").font(.headline).lineLimit(1).fixedSize()
                if !takes.isEmpty {
                    Text("\(takes.count) · \(WizardPreviewClips.clock(takes.reduce(0) { $0 + $1.duration }))")
                        .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                if mine, library.lastDeleted != nil, let database = store.database {
                    Button("Undo Delete", systemImage: "arrow.uturn.backward") { library.undoDelete(database: database) }
                        .lineLimit(1).fixedSize()
                        .keyboardShortcut("z", modifiers: .command)
                        .help("Put back the recording that was just deleted")
                }
            }
            if takes.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(takes) { take in
                let start = starts.map { $0[take.id] } ?? take.reelTime
                VoiceOverRow(take: take, start: start, captionLanguage: captionLanguage,
                             playing: library.auditioning == take.id,
                             listen: { if let database = store.database { library.toggleAudition(take, database: database) } },
                             select: start.flatMap { time in select.map { action in { action(time) } } },
                             setText: { text in
                                 if let database = store.database { library.setText(text, for: take.id, database: database) }
                             },
                             setTranslation: { text, code in
                                 if let database = store.database {
                                     library.setTranslation(text, language: code, for: take.id, database: database)
                                 }
                             },
                             delete: { if let database = store.database { library.delete(take, database: database) } })
            }
            if mine, let message = library.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Video sound under voice" and "Include in the reel", per profile.
struct VoiceOverSettingsRows: View {
    @Environment(AppStore.self) private var store
    @AppStorage private var level: Double
    @AppStorage private var include: Bool

    init(profile: String) {
        _level = AppStorage(wrappedValue: VoiceOverMixer.defaultBedLevel, VoiceOverPreferences.levelKey(profile: profile))
        _include = AppStorage(wrappedValue: true, VoiceOverPreferences.includeKey(profile: profile))
    }

    // The rough cut's preview carries the mix, so every change asks for a new
    // one. Done in the setters: nothing here depends on a view staying mounted.
    private var includeBinding: Binding<Bool> {
        Binding(get: { include }, set: { include = $0; store.voiceOver.mixRevision += 1 })
    }
    private var levelBinding: Binding<Double> {
        Binding(get: { level }, set: { value in
            guard value != level else { return }
            level = value
            store.voiceOver.mixRevision += 1
        })
    }

    var body: some View {
        MiniRow("Include in the reel", detail: "Off leaves the recordings out of the generated reel without deleting them.") {
            Toggle("Include in the reel", isOn: includeBinding)
        }
        if include {
            MiniRow("Video sound under voice") {
                HStack(spacing: Theme.spaceS) {
                    Slider(value: levelBinding, in: 0...1, step: 0.05)
                        .accessibilityLabel("Video sound under voice")
                    Text("\(Int((level * 100).rounded())) %").monospacedDigit().lineLimit(1).fixedSize()
                }
            }
        }
        if store.voiceOver.mixing {
            HStack(spacing: Theme.spaceS) {
                ProgressView().controlSize(.small)
                Text("Updating the preview’s sound…").font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }
}

/// The rough cut sheet's Voice Over tab: hold a button while the reel plays
/// to record over it. Each hold is one recording, kept as it is made; the
/// sheet then mixes it into the preview's sound.
struct VoiceOverTab: View {
    @Environment(AppStore.self) private var store
    let player: AVPlayer?
    /// The reel's clips on its output clock: reel time to the picture under it.
    let clips: [WizardPreviewClip]
    let owner: VoiceOverLibrary.Owner
    /// The reel on screen is rendered with the current settings.
    let canRecord: Bool
    let captionLanguage: String?
    let profile: String

    @State private var holding = false
    @State private var recordStart: Double?
    @State private var rateBeforeRecording: Float?
    init(player: AVPlayer?, clips: [WizardPreviewClip], owner: VoiceOverLibrary.Owner, canRecord: Bool,
         captionLanguage: String?, profile: String) {
        self.player = player
        self.clips = clips
        self.owner = owner
        self.canRecord = canRecord
        self.captionLanguage = captionLanguage
        self.profile = profile
    }

    private var library: VoiceOverLibrary { store.voiceOver }
    private var placed: [VoiceOverPlacement.Placed] {
        VoiceOverPlacement.place(library.takes, in: VoiceOverPlacement.cuts(from: clips))
    }
    private var ready: Bool { canRecord && player != nil && library.recorder.access != .unavailable }
    private var spokenLanguage: String {
        ProjectLanguageResolver.resolve(project: nil, profile: store.activeProfile).spoken.first ?? ""
    }

    var body: some View {
        let placed = placed
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack(spacing: Theme.spaceM) {
                recordButton
                LevelMeter(level: library.recorder.isRecording ? library.recorder.level : 0)
            }
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if library.recorder.access == .denied {
                Button("Open Microphone Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .lineLimit(1).fixedSize()
            }
            VoiceOverList(owner: owner, starts: Dictionary(uniqueKeysWithValues: placed.map { ($0.take.id, $0.start) }),
                          captionLanguage: captionLanguage,
                          select: { time in
                              player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                           toleranceBefore: .zero, toleranceAfter: .zero)
                          },
                          emptyText: "No recordings yet. Press play, then hold the button and talk.")
            VoiceOverSettingsRows(profile: profile)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: ["r"], phases: [.down, .up]) { press in
            if press.phase == .down { begin() } else { end() }
            return .handled
        }
        .task(id: owner) {
            library.recorder.refreshAccess()
            await library.load(owner, database: store.database, language: spokenLanguage, ai: store.ai)
            await translateCaptions()
        }
        .task(id: captionLanguage) {
            guard library.owner == owner else { return }
            await translateCaptions()
        }
        .onDisappear {
            holding = false
            library.cancelRecording()
            library.stopAudition()
            recordStart = nil
            library.recorder.startedAtReel = nil
            // A recording cut short by leaving the tab still gives the reel its speed back.
            if let player, player.rate != 0, let rate = rateBeforeRecording, rate > 0 { player.rate = rate }
            rateBeforeRecording = nil
            player?.volume = 1
        }
    }

    /// Translates the recordings spoken in another language, as a job: an AI
    /// call does not run inside the sheet.
    private func translateCaptions() async {
        guard let captionLanguage, let database = store.database,
              !VoiceOverTranscriber.needingTranslation(library.takes, target: captionLanguage).isEmpty else { return }
        let library = library, ai = store.ai
        try? await store.runVoiceOverJob(title: "Voice over — caption translation",
                                         group: "voice-translate-\(owner.projectID)") {
            await library.translate(to: captionLanguage, ai: ai, database: database)
        }
    }

    private var hint: String {
        switch library.recorder.access {
        case .unavailable: return "This build cannot use the microphone: it has no microphone permission text."
        case .denied: return "Clip Builder is not allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        default: break
        }
        if !canRecord { return "Press play to render the reel first; recording needs the finished picture." }
        if library.recorder.isRecording { return "Let go to stop. The reel keeps playing." }
        return "Hold while the reel plays, or hold R. Recording starts at the playhead and stops when you let go."
    }

    private var recordButton: some View {
        let recording = library.recorder.isRecording
        return Label(recording ? "Recording \(WizardPreviewClips.clock(library.recorder.elapsed))" : "Hold to Record",
                     systemImage: recording ? "stop.fill" : "mic.fill")
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1).fixedSize()
            .foregroundStyle(recording ? Color.white : (ready ? Color.primary : Color.secondary))
            .padding(.horizontal, Theme.spaceM)
            .padding(.vertical, 6)
            .background(Capsule().fill(recording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary)))
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 3600, maximumDistance: 400, pressing: { down in
                if down { begin() } else { end() }
            }, perform: {})
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(recording ? "Stop Recording" : "Record Voice Over")
            // Assistive technology cannot hold: one activation starts, the next stops.
            .accessibilityAction { if holding { end() } else { begin() } }
            .help("Hold to record your voice over the reel from the playhead; let go to stop")
    }

    private func begin() {
        guard ready, !holding, let player, let database = store.database else { return }
        holding = true
        Task {
            guard await library.beginRecording(database: database) else { holding = false; return }
            // Let go while the system asked for the microphone: nothing to record.
            guard holding else { library.cancelRecording(); return }
            let time = player.currentTime().seconds
            recordStart = time.isFinite ? time : 0
            library.recorder.startedAtReel = recordStart
            player.volume = 0
            // The microphone records in real time, so the picture must play at 1x
            // for the voice to stay over what it was said about.
            rateBeforeRecording = player.rate
            if player.rate == 0 { player.play() }
            player.rate = 1
        }
    }

    private func end() {
        guard holding else { return }
        holding = false
        guard library.recorder.isRecording, let start = recordStart, let database = store.database else { return }
        recordStart = nil
        library.recorder.startedAtReel = nil
        // Back to the speed the reel was playing at before the hold.
        if let player, player.rate != 0, let rate = rateBeforeRecording, rate > 0 { player.rate = rate }
        rateBeforeRecording = nil
        player?.volume = 1
        library.finishRecording(anchor: VoiceOverPlacement.anchor(at: start, in: clips), reelTime: start,
                                language: spokenLanguage, captionLanguage: captionLanguage,
                                ai: store.ai, database: database)
    }
}

/// The input level while recording.
private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<14, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(index) / 14 < level ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Under the rough cut's scrubber: one red bar per recording across the reel.
struct VoiceOverLane: View {
    @Environment(AppStore.self) private var store
    let clips: [WizardPreviewClip]
    let duration: Double

    var body: some View {
        let placed = VoiceOverPlacement.place(store.voiceOver.takes, in: VoiceOverPlacement.cuts(from: clips))
        let recorder = store.voiceOver.recorder
        // Drawn under the scrubber on its scale: the thumb above is the playhead.
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = duration > 0 ? width / duration : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.6))
                ForEach(placed, id: \.take.id) { item in
                    let start = min(width, max(0, item.start * scale))
                    RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.85))
                        .frame(width: max(2, min(width - start, item.take.duration * scale)), height: 6)
                        .offset(x: min(start, max(0, width - 2)))
                }
                if recorder.isRecording, let from = recorder.startedAtReel {
                    let start = min(width, max(0, from * scale))
                    RoundedRectangle(cornerRadius: 2).fill(Color.red)
                        .frame(width: max(2, min(width - start, recorder.elapsed * scale)), height: 6)
                        .offset(x: min(start, max(0, width - 2)))
                }
            }
        }
        .allowsHitTesting(false)
        .help("Where each voice recording sits in the reel")
        .accessibilityLabel("Voice recordings")
        .accessibilityValue("\(placed.count) in the reel")
    }
}

/// The Express page's Voice Over tab: the recordings only. Recording happens
/// over the finished reel, in the rough cut sheet.
struct VoiceOverPanel: View {
    @Environment(AppStore.self) private var store
    let owner: VoiceOverLibrary.Owner
    let captionLanguage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            VoiceOverList(owner: owner, starts: nil, captionLanguage: captionLanguage,
                          emptyText: "No recordings yet. Press Render Preview and open the Voice Over tab to record over the reel.")
            if store.voiceOver.owner == owner, !store.voiceOver.takes.isEmpty {
                VoiceOverSettingsRows(profile: store.activeProfile.profileName)
                FormCaption("Recorded over the reel in Render Preview › Voice Over. With captions on, each recording's text is its caption.")
            }
        }
        .task(id: owner) { await load() }
        // A rough cut sheet for another source took the library while it was
        // open: once it has closed, this panel shows its own recordings again.
        .task(id: store.voiceOver.owner != owner && store.voiceOver.reviewSheets == 0) {
            if store.voiceOver.owner != owner, store.voiceOver.reviewSheets == 0 { await load() }
        }
        .onDisappear { store.voiceOver.stopAudition() }
    }

    private func load() async {
        let language = ProjectLanguageResolver.resolve(project: nil, profile: store.activeProfile).spoken.first ?? ""
        await store.voiceOver.load(owner, database: store.database, language: language, ai: store.ai)
    }
}
