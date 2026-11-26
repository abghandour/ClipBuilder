import AVFoundation
import SwiftUI

/// A compact button (picture, voice name, chevron) that opens the voices in a
/// popover, the way `SourcePickerButton` does for videos. Clones come first,
/// each with the person it was made from and its date; stock voices follow,
/// each with a drawn face.
struct VoicePickerButton<PersonAvatar: View>: View {
    /// What the control is for: "Voice for Alice Pereira".
    var title: String
    var sections: VoicePickerRules.Sections
    var selection: String
    /// Shown when `selection` is not in `sections`: "Loading voices…".
    var placeholder: String
    /// Under the Cloned heading when there are no clones; nil hides the section.
    var noClonesHint: String?
    /// Lets the popover speak a phrase in a voice before it is chosen; nil hides the play buttons.
    var preview: VoicePreview?
    var select: (String) -> Void
    /// The face of the person a clone was made from, by person key and size.
    @ViewBuilder var personAvatar: (String, CGFloat) -> PersonAvatar
    @State private var showing = false

    private var current: VoiceChoice? { sections.choice(selection) }

    /// The name alone, unless another voice shares it: then what tells them
    /// apart (a clone's date, "Premium") rides along on the closed control.
    private var currentLabel: String? {
        guard let current else { return nil }
        let caption = current.isCloned ? VoicePickerRules.cloneCaption(current) : current.detail
        let shared = (sections.cloned + sections.stock).filter { $0.title == current.title }.count > 1
        return shared && !caption.isEmpty ? "\(current.title) · \(caption)" : current.title
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: Theme.spaceS) {
                if let current {
                    VoiceChoicePicture(choice: current, size: 18, personAvatar: personAvatar)
                } else {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
                Text(currentLabel ?? placeholder)
                    .lineLimit(1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(current.map { $0.detail.isEmpty ? $0.title : "\($0.title), \($0.detail)" } ?? placeholder)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VoicePickerPopover(sections: sections, selection: selection, noClonesHint: noClonesHint, preview: preview, select: { id in
                select(id)
                showing = false
            }, personAvatar: personAvatar)
        }
    }
}

/// The scrolling popover. It holds keyboard focus as one control, like a menu:
/// arrows move a highlight through the grid, Return or Space picks it, typing
/// a name jumps to it, Escape closes.
private struct VoicePickerPopover<PersonAvatar: View>: View {
    var sections: VoicePickerRules.Sections
    var selection: String
    var noClonesHint: String?
    var preview: VoicePreview?
    var select: (String) -> Void
    @ViewBuilder var personAvatar: (String, CGFloat) -> PersonAvatar
    @State private var highlighted: String?
    @State private var typed = ""
    @State private var lastTyped = Date.distantPast
    @State private var player = VoicePreviewPlayer()
    /// The user's own phrase, kept between speakers and launches; empty means the speaker's line.
    @AppStorage("dub.voicePreviewPhrase") private var customPhrase = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VoicePickerList(sections: sections, selection: selection, highlighted: highlighted,
                                    noClonesHint: noClonesHint, loadingPreview: player.loadingID,
                                    playingPreview: player.playingID,
                                    togglePreview: preview == nil ? nil : { togglePreview($0) },
                                    select: select, personAvatar: personAvatar)
                        .padding(Theme.spaceL)
                }
                .frame(minHeight: 120, maxHeight: 520)
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.upArrow) { move(.up, proxy) }
                .onKeyPress(.downArrow) { move(.down, proxy) }
                .onKeyPress(.leftArrow) { move(.left, proxy) }
                .onKeyPress(.rightArrow) { move(.right, proxy) }
                .onKeyPress(.return) { pick() }
                .onKeyPress(.space) { preview == nil ? pick() : listen() }
                .onKeyPress(characters: .alphanumerics) { press in type(press.characters, proxy) }
                .onAppear {
                    highlighted = sections.choice(selection)?.id
                    focused = true
                    if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
                }
                .accessibilityLabel("Voices")
            }
            if let preview {
                Divider()
                phraseBar(preview)
            }
        }
        .frame(width: 520)
        .onDisappear { player.stop() }
    }

    /// What the play buttons say, and what a preview costs.
    private func phraseBar(_ preview: VoicePreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceXS) {
            HStack(spacing: Theme.spaceS) {
                Image(systemName: "quote.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Phrase to hear", text: $customPhrase, prompt: Text(preview.samplePhrase))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Phrase the play buttons speak")
                    .help("Type your own phrase, or leave this empty to hear the speaker's own line")
                if !customPhrase.isEmpty {
                    Button("Use the line", systemImage: "arrow.uturn.backward") { customPhrase = "" }
                        .labelStyle(.iconOnly).lineLimit(1).fixedSize()
                        .help("Go back to the speaker's own line")
                }
            }
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(["Play speaks this phrase in a voice. Space plays the highlighted one.", preview.note]
                        .compactMap { $0 }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.spaceL).padding(.vertical, Theme.spaceM)
    }

    private func togglePreview(_ id: String) {
        guard let preview else { return }
        highlighted = id
        player.toggle(id, phrase: VoicePreview.phrase(custom: customPhrase, sample: preview.samplePhrase),
                      synthesize: preview.synthesize)
    }

    private func listen() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        togglePreview(highlighted)
        return .handled
    }

    private func move(_ move: VoicePickerRules.Move, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        if let next = VoicePickerRules.move(move, from: highlighted, in: sections) {
            highlighted = next
            proxy.scrollTo(next)
        }
        return .handled
    }

    private func pick() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        select(highlighted)
        return .handled
    }

    /// Letters typed within a second of each other build one prefix.
    private func type(_ characters: String, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let now = Date()
        typed = now.timeIntervalSince(lastTyped) < 1 ? typed + characters : characters
        lastTyped = now
        if let match = VoicePickerRules.match(typed: typed, in: sections) {
            highlighted = match
            proxy.scrollTo(match)
        }
        return .handled
    }
}

/// The popover's content: the Cloned and Stock sections.
struct VoicePickerList<PersonAvatar: View>: View {
    var sections: VoicePickerRules.Sections
    var selection: String
    /// Where the keyboard is; drawn like a hover.
    var highlighted: String?
    var noClonesHint: String?
    var loadingPreview: String?
    var playingPreview: String?
    /// Nil when voices cannot be previewed here: the cells then have no play button.
    var togglePreview: ((String) -> Void)?
    var select: (String) -> Void
    @ViewBuilder var personAvatar: (String, CGFloat) -> PersonAvatar

    private let columns = [GridItem(.flexible(), spacing: Theme.spaceS, alignment: .top),
                           GridItem(.flexible(), spacing: Theme.spaceS, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            if !sections.cloned.isEmpty || noClonesHint != nil {
                section("Cloned voices", count: sections.cloned.count) {
                    if sections.cloned.isEmpty, let noClonesHint {
                        Text(noClonesHint).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        grid(sections.cloned)
                    }
                }
            }
            if !sections.stock.isEmpty {
                section("Stock voices", count: sections.stock.count) { grid(sections.stock) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack(spacing: Theme.spaceS) {
                SectionLabel(title)
                if count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func grid(_ choices: [VoiceChoice]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.spaceXS) {
            ForEach(choices) { choice in
                VoiceChoiceCell(choice: choice, selected: choice.id == selection, highlighted: choice.id == highlighted,
                                previewState: choice.id == playingPreview ? .playing
                                    : choice.id == loadingPreview ? .loading : .idle,
                                togglePreview: togglePreview.map { toggle in { toggle(choice.id) } },
                                action: { select(choice.id) }, personAvatar: personAvatar)
                    .id(choice.id)
            }
        }
    }
}

/// One voice: picture, name, what tells it apart (a clone's date, a stock
/// voice's character), and a play button to hear it.
private struct VoiceChoiceCell<PersonAvatar: View>: View {
    enum PreviewState { case idle, loading, playing }

    let choice: VoiceChoice
    let selected: Bool
    var highlighted = false
    var previewState = PreviewState.idle
    var togglePreview: (() -> Void)?
    let action: () -> Void
    @ViewBuilder var personAvatar: (String, CGFloat) -> PersonAvatar
    @State private var hovering = false

    private var caption: String { choice.isCloned ? VoicePickerRules.cloneCaption(choice) : choice.detail }

    var body: some View {
        HStack(spacing: Theme.spaceXS) {
            Button(action: action) {
                HStack(spacing: Theme.spaceS) {
                    VoiceChoicePicture(choice: choice, size: 36, personAvatar: personAvatar)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.title).lineLimit(1).truncationMode(.tail)
                        if !caption.isEmpty {
                            Text(caption)
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(caption.isEmpty ? choice.title : "\(choice.title), \(caption)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(caption.isEmpty ? choice.title : "\(choice.title) · \(caption)")
            if let togglePreview { playButton(togglePreview) }
        }
        .padding(.leading, Theme.spaceS).padding(.trailing, togglePreview == nil ? Theme.spaceS : Theme.spaceXS)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Theme.mediaRadius)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                      : hovering || highlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        }
        .overlay {
            // The keyboard's place needs more than a tint to be found: a ring,
            // solid on the chosen voice, quieter on any other.
            if selected || highlighted {
                RoundedRectangle(cornerRadius: Theme.mediaRadius)
                    .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary),
                                  lineWidth: highlighted ? 2 : 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
    }

    private func playButton(_ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            ZStack {
                switch previewState {
                case .idle:
                    Image(systemName: "play.circle").font(.title2)
                        .foregroundStyle(hovering || highlighted ? .primary : .secondary)
                case .loading:
                    ProgressView().controlSize(.small)
                case .playing:
                    Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(previewState == .idle ? "Play \(choice.title)" : "Stop \(choice.title)")
        .help(previewState == .idle ? "Hear \(choice.title) say the phrase below" : "Stop")
    }
}

/// A clone shows its person; every other voice shows its drawn face.
private struct VoiceChoicePicture<PersonAvatar: View>: View {
    let choice: VoiceChoice
    let size: CGFloat
    @ViewBuilder var personAvatar: (String, CGFloat) -> PersonAvatar

    var body: some View {
        if choice.isCloned, let key = choice.personKey {
            personAvatar(key, size).accessibilityHidden(true)
        } else {
            VoiceFaceView(face: choice.face, size: size)
        }
    }
}

/// How a picker speaks a phrase in a voice that has not been chosen yet.
struct VoicePreview {
    /// Spoken when the user has typed no phrase of their own: the speaker's own line.
    var samplePhrase: String
    /// What a preview costs, when it costs anything.
    var note: String?
    /// Voice identifier and phrase to an audio file.
    var synthesize: @Sendable (String, String) async throws -> URL

    /// Previews are for telling voices apart, not for reading paragraphs.
    static let phraseLimit = 200

    nonisolated static func phrase(custom: String, sample: String) -> String {
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let sample = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = !custom.isEmpty ? custom : !sample.isEmpty ? sample : "This is how I sound in your video."
        return String(phrase.prefix(phraseLimit))
    }
}

/// One preview at a time: starting another, or playing the same again, stops the first.
@Observable
final class VoicePreviewPlayer {
    private(set) var loadingID: String?
    private(set) var playingID: String?
    private(set) var error: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?

    func toggle(_ id: String, phrase: String, synthesize: @escaping @Sendable (String, String) async throws -> URL) {
        let wasActive = loadingID == id || playingID == id
        stop()
        guard !wasActive else { return }
        error = nil
        loadingID = id
        task = Task {
            do {
                let url = try await synthesize(id, phrase)
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                self.player = player
                loadingID = nil
                playingID = id
                player.play()
                try await Task.sleep(for: .seconds(player.duration + 0.15))
                guard !Task.isCancelled else { return }
                playingID = nil
                self.player = nil
            } catch {
                guard !Task.isCancelled else { return }
                loadingID = nil
                playingID = nil
                self.error = error.userMessage
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        loadingID = nil
        playingID = nil
    }
}
