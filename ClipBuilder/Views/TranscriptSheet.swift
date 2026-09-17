import AVKit
import SwiftUI

/// The whole transcript of one video, every segment editable in place.
/// Save writes all changed segments at once; a segment edited before can
/// be reverted to what the transcriber produced. Opened from the Raw
/// Videos detail pane and from batch/scene context menus.
struct TranscriptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord

    @State private var rows: [TranscriptRow] = []
    /// Edited text per segment id; only segments whose text differs from
    /// the stored row are written on Apply.
    @State private var drafts: [Int64: String] = [:]
    /// Who says a line, as changed here and not yet applied.
    @State private var speakerDrafts: [Int64: TranscriptRow.SpeakerAttribution] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @State private var showTools = false
    /// Who is talking: the podcast pass's speaker turns and this video's
    /// roster, for the speaker column and its menu.
    @State private var turns: [SpeakerTurn] = []
    @State private var roster: [VideoPersonRecord] = []
    /// Who says each line, worked out once per load (a row's menu asks
    /// about every other row for "all lines by …").
    @State private var speakerLabels: [Int64: String] = [:]
    /// The scenes of this video that cover each line (by the line's
    /// midpoint) and the tags they carry, housekeeping tags dropped —
    /// worked out once per load. Tags are read-only here; the Scenes
    /// screen edits them.
    @State private var lineScenes: [Int64: [SceneRecord]] = [:]
    @State private var lineTags: [Int64: [String]] = [:]
    /// Only lines inside scenes carrying this tag are listed; "" = all.
    @State private var tagFilter = ""
    /// What the video panel is playing: a line's range or a tagged scene.
    @State private var playing: PlayingRange?
    /// The player's clock while something plays, for following the line.
    @State private var playbackTime: Double?
    @State private var timeObserver: Any?

    struct PlayingRange: Equatable {
        var start: Double
        /// nil: on to the end of the file.
        var end: Double?
        var label: String
        /// The line whose ▶ started it (nil for a tag's scene).
        var rowID: Int64?
    }
    /// One player for the whole sheet, shown in the right panel: a line's
    /// play button (or a tag chip) seeks it to the range and a boundary
    /// observer stops it at the range's end.
    @State private var player: AVPlayer?
    @State private var boundaryObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    /// The file is not on this Mac (a Drive copy not downloaded), so the
    /// play buttons stay off.
    @State private var playbackUnavailable = false
    /// A re-cut by speaker happened (the transcriber's rows are backed up).
    @State private var hasRecut = false
    /// What the last Re-cut did, shown briefly under the header.
    @State private var recutNote: String?

    private var changedIDs: [Int64] {
        rows.compactMap { row in
            (drafts[row.id] ?? row.text) != row.text ? row.id : nil
        }
    }

    private var changedSpeakerIDs: [Int64] {
        rows.compactMap { row in
            guard let draft = speakerDrafts[row.id] else { return nil }
            return draft != row.speaker ? row.id : nil
        }
    }

    private var hasChanges: Bool { !changedIDs.isEmpty || !changedSpeakerIDs.isEmpty }

    private var changeSummary: String {
        var parts: [String] = []
        if !changedIDs.isEmpty { parts.append("\(changedIDs.count) segment\(changedIDs.count == 1 ? "" : "s") edited") }
        if !changedSpeakerIDs.isEmpty { parts.append("\(changedSpeakerIDs.count) speaker change\(changedSpeakerIDs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The line with its pending speaker change applied.
    private func effective(_ row: TranscriptRow) -> TranscriptRow {
        guard let draft = speakerDrafts[row.id] else { return row }
        var row = row
        row.speaker = draft
        return row
    }

    private func speakerLabel(_ row: TranscriptRow) -> String? {
        guard speakerDrafts[row.id] != nil else { return speakerLabels[row.id] }
        return TranscriptSpeakers.label(for: effective(row), turns: turns, roster: roster, people: store.people)
    }

    /// The speaker turn under most of the line — the app's own guess.
    private func bestTurn(for row: TranscriptRow) -> SpeakerTurn? {
        var best: (turn: SpeakerTurn, overlap: Double)?
        for turn in turns {
            let overlap = min(turn.end, row.endTime) - max(turn.start, row.startTime)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn, overlap) }
        }
        return best?.turn
    }

    /// The lines on show: all of them, or those under the tag filter.
    private var visibleRows: [TranscriptRow] {
        tagFilter.isEmpty ? rows : rows.filter { lineTags[$0.id]?.contains(tagFilter) == true }
    }

    /// Every tag any line carries, Reel first, then alphabetical.
    private var allLineTags: [String] {
        Self.orderTags(Array(Set(lineTags.values.flatMap { $0 })))
    }

    /// Scene tags worth reading beside a transcript line: the analyzer's
    /// content tags, not people (the speaker column has them), layout or
    /// framing bookkeeping.
    nonisolated static func lineTags(_ tags: [String]) -> [String] {
        orderTags(tags.filter { tag in
            !tag.hasPrefix("person:") && !tag.hasPrefix("vip:") && !tag.hasPrefix("podcast")
                && !tag.hasPrefix("portrait-fit:") && !tag.hasPrefix("center-stage:")
                && tag != "auto-hidden"
        })
    }

    nonisolated static func orderTags(_ tags: [String]) -> [String] {
        let unique = Array(Set(tags))
        return unique.filter { $0 == "reel-highlight" } + unique.filter { $0 != "reel-highlight" }.sorted()
    }

    /// The scenes whose range holds the line's midpoint.
    nonisolated static func scenes(covering row: TranscriptRow, in scenes: [SceneRecord]) -> [SceneRecord] {
        let mid = (row.startTime + row.endTime) / 2
        return scenes.filter { $0.startTime <= mid && mid < $0.endTime }
    }

    /// The lines that currently read as the same speaker as `row` (the
    /// same person, feed, voice cluster or Unknown), for "all lines by …".
    private func sameSpeakerRows(as row: TranscriptRow) -> [TranscriptRow] {
        guard let label = speakerLabel(row) else { return [row] }
        return rows.filter { $0.isTranslation == row.isTranslation && speakerLabel($0) == label }
    }

    /// People the user can attribute a line to: this video's roster first,
    /// then everyone else in the library.
    private var otherPeople: [PersonRecord] {
        let rosterKeys = Set(roster.map(\.key))
        return store.people.filter { !rosterKeys.contains($0.key) && !$0.hidden }
    }

    /// Language shown per segment only when the transcript mixes languages
    /// (a translation stored alongside the original).
    private var showsLanguage: Bool {
        Set(rows.map { "\($0.language)|\($0.isTranslation)" }).count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Transcript — \(video.filename)")
                        .font(.headline)
                    HStack(spacing: 8) {
                        AIInfoButton(video: video)
                        if !rows.isEmpty {
                            Text(tagFilter.isEmpty ? "\(rows.count) segments"
                                 : "\(visibleRows.count) of \(rows.count) segments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let recutNote {
                            Text(recutNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !allLineTags.isEmpty {
                            // Narrow the transcript to the lines inside
                            // scenes carrying one tag (the reel picks, the
                            // questions…).
                            Menu(tagFilter.isEmpty ? "All tags" : tagFilter) {
                                Button("All tags") { tagFilter = "" }
                                Divider()
                                ForEach(allLineTags, id: \.self) { tag in
                                    let count = rows.count { lineTags[$0.id]?.contains(tag) == true }
                                    Button("\(tag == "reel-highlight" ? "Reel" : tag) (\(count))") { tagFilter = tag }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                            .help("Show only the lines inside scenes carrying a tag")
                        }
                    }
                }
                Spacer()
                if !turns.isEmpty {
                    // Split rows where the speaker changes mid-row, using the
                    // words' timings; Undo puts the transcriber's rows back.
                    Menu("Re-cut by Speaker") {
                        Button("Re-cut by Speaker") { recut() }
                            .disabled(hasChanges)
                        if hasRecut {
                            Button("Undo Re-cut") { undoRecut() }
                                .disabled(hasChanges)
                        }
                    }
                    .fixedSize()
                    .help(hasChanges ? "Apply or discard your pending changes first"
                          : "Split every row where the speaker changes, at the gap between words, so each row has one speaker" + (hasRecut ? " — or put the transcriber's original rows back" : ""))
                }
                Button("Topics, Cuts & Translation…") { showTools = true }
                    .disabled(rows.isEmpty)
                Button("Re-transcribe") {
                    store.transcribe(video: video, force: true)
                    dismiss()
                }
                .help("Discard this transcript and run the transcriber again")
                Button(hasChanges ? "Apply" : "Done") {
                    if hasChanges { save(thenDismiss: false) } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .help(hasChanges ? "Save every edited line and speaker change at once" : "Close")
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.quote",
                    description: Text("Transcribe this video from the Raw Videos screen."))
                    // Fill the sheet's remaining height so the header stays
                    // pinned to the top instead of centering with it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let visible = visibleRows
                            let current = currentRowID
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                                // Tags print where the line enters a
                                // different scene, so a run of lines in one
                                // exchange reads as one block under its tags.
                                let previous = index > 0 ? sceneIDs(visible[index - 1]) : nil
                                let sameSpeaker = index > 0 && speakerLabel(visible[index - 1]) == speakerLabel(row)
                                segmentRow(row, showTags: index == 0 || previous != sceneIDs(row),
                                           current: current == row.id, repeatedSpeaker: sameSpeaker)
                                Divider()
                            }
                        }
                    }
                    Divider()
                    videoPanel
                        .frame(width: 400)
                }
            }

            if hasChanges {
                Divider()
                HStack {
                    Text(changeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard Changes") { drafts = [:]; speakerDrafts = [:] }
                        .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 1160, height: 640)
        .modalCloseButton {
            if hasChanges { confirmDiscard = true } else { dismiss() }
        }
        .task { await load() }
        .onDisappear { stopPlayback(releasePlayer: true) }
        .sheet(isPresented: $showTools) { TranscriptToolsSheet(video: video) }
        .confirmationDialog("Discard unsaved transcript changes?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Apply and Close") { save(thenDismiss: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(changeSummary + " not applied yet.")
        }
    }

    private func segmentRow(_ row: TranscriptRow, showTags: Bool, current: Bool, repeatedSpeaker: Bool) -> some View {
        let playing = self.playing?.rowID == row.id
        return HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await togglePlayback(row) }
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.caption)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(playing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .disabled(playbackUnavailable)
            .help(playbackUnavailable ? "The video is not on this Mac — download it from the Drive menu to watch it"
                  : playing ? "Stop" : "Watch this line in the panel on the right")
            .accessibilityLabel(playing ? "Stop" : "Play line at \(row.startTime.timecode)")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.startTime.timecode)–\(row.endTime.timecode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if showsLanguage {
                    Text(row.isTranslation ? "\(row.language) · translation" : row.language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, alignment: .leading)
            .padding(.top, 3)

            // A run of rows by one speaker reads as a block: the name is
            // bright on the first row and faint on the rest (the menu
            // stays on every row).
            speakerMenu(row)
                .frame(width: 108, alignment: .leading)
                .padding(.top, 1)
                .opacity(repeatedSpeaker ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Segment text", text: Binding(
                    get: { drafts[row.id] ?? row.text },
                    set: { drafts[row.id] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                if showTags, let tags = lineTags[row.id], !tags.isEmpty {
                    tagLine(row, tags: tags)
                }
            }

            if row.originalText != nil {
                Button("Revert") { revert(row) }
                    .controlSize(.mini)
                    .help("Restore the transcriber's original text for this segment")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(current || (drafts[row.id] ?? row.text) != row.text
                    ? Color.accentColor.opacity(current ? 0.16 : 0.08) : Color.clear)
    }

    /// The scenes a line sits in, for tag-line boundaries.
    private func sceneIDs(_ row: TranscriptRow) -> Set<Int64>? {
        lineScenes[row.id].map { Set($0.map(\.id)) }
    }

    /// The line being spoken in the panel; the ▶ line before the clock moves.
    private var currentRowID: Int64? {
        guard let playing else { return nil }
        guard let time = playbackTime else { return playing.rowID }
        return rows.first { !$0.isTranslation && $0.startTime <= time && time < $0.endTime }?.id ?? playing.rowID
    }

    // MARK: - Video panel

    /// The right-hand player: a line's ▶ or a tag chip plays its range here;
    /// the player's own controls take over from there.
    private var videoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                PlayerView(player: player)
                    .background(.black)
                    .overlay { talkerOverlay }
                if playing == nil {
                    Button {
                        Task { await play(start: 0, end: nil, label: "Whole video", rowID: nil) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 36))
                            Text(playbackUnavailable
                                 ? "The video is not on this Mac — download it from the Drive menu"
                                 : "Press ▶ on a line or click a tag to watch it here.\nClick to watch from the start.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(playbackUnavailable)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let playing {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playing.label)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(playing.end.map { "\(playing.start.timecode)–\($0.timecode)" } ?? "from \(playing.start.timecode)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop") { stopPlayback(releasePlayer: false) }
                        .controlSize(.small)
                }
                if let row = currentRow {
                    Divider()
                    whoIsTalking(row)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var currentRow: TranscriptRow? {
        guard let id = currentRowID else { return nil }
        return rows.first { $0.id == id }
    }

    /// The key the line is attributed to right now (draft, override, or the
    /// app's guess); nil for Unknown or no guess.
    private func attributedKey(_ row: TranscriptRow) -> String? {
        switch speakerDrafts[row.id] ?? row.speaker {
        case .person(let key): return key
        case .unknown: return nil
        case .automatic: return bestTurn(for: row)?.personKey
        }
    }

    /// Who the app thinks is talking on the line being played, as a checkbox
    /// per person of this video (plus Unknown): the checked one is the
    /// current attribution; checking another stages a change for Apply.
    private func whoIsTalking(_ row: TranscriptRow) -> some View {
        let guess = bestTurn(for: row)
        let guessName = guess?.personKey.map { TranscriptSpeakers.name(forKey: $0, roster: roster, people: store.people) }
        let attribution = speakerDrafts[row.id] ?? row.speaker
        let checkedKey = attributedKey(row)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Who is talking · \(row.startTime.timecode)–\(row.endTime.timecode)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if attribution != .automatic {
                    Button("Use the app's guess") { attribute([row], .automatic) }
                        .controlSize(.mini)
                }
            }
            Text(guessName.map { "The app thinks: \($0)" }
                 ?? (guess != nil ? "The app hears a voice it could not match to a person" : "No speaker detected under this line"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(roster) { entry in
                Toggle(isOn: Binding(
                    get: { checkedKey == entry.key },
                    set: { on in if on { attribute([row], .person(key: entry.key)) } })
                ) {
                    HStack(spacing: 6) {
                        VideoPersonAvatar(record: entry, videoURL: video.url, size: 22)
                        Text(entry.displayName)
                            .font(.callout)
                            .lineLimit(1)
                        if guess?.personKey == entry.key {
                            Text("app's guess")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .help("This person says the line — the blue frame shows their feed")
            }
            Toggle(isOn: Binding(
                get: { attribution == .unknown },
                set: { on in if on { attribute([row], .unknown) } })
            ) {
                Text(TranscriptSpeakers.unknownLabel)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .help("Nobody the app knows says this line")
        }
    }

    /// The feed of whoever the line is attributed to, framed in blue over
    /// the picture; the app's guess dashed when the user picked someone
    /// else. Grid layouts frame the person's tile; split layouts the side
    /// the guess was heard on.
    @ViewBuilder
    private var talkerOverlay: some View {
        if let row = currentRow {
            GeometryReader { proxy in
                let frame = Self.videoRect(in: proxy.size, videoWidth: video.width, videoHeight: video.height)
                let chosen = attributedKey(row).flatMap { feedRect(personKey: $0, row: row) }
                let guessKey = bestTurn(for: row)?.personKey
                let guess = guessKey.flatMap { feedRect(personKey: $0, row: row) }
                if let chosen {
                    Rectangle()
                        .strokeBorder(Color.blue, lineWidth: 3)
                        .frame(width: chosen.width * frame.width, height: chosen.height * frame.height)
                        .position(x: frame.minX + (chosen.midX) * frame.width,
                                  y: frame.minY + (chosen.midY) * frame.height)
                }
                if let guess, guessKey != attributedKey(row) {
                    Rectangle()
                        .strokeBorder(Color.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: guess.width * frame.width, height: guess.height * frame.height)
                        .position(x: frame.minX + guess.midX * frame.width,
                                  y: frame.minY + guess.midY * frame.height)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Where a person's feed sits in the source frame (fractions), from the
    /// podcast layout: their tile in a grid, else the side the speaker turn
    /// resolved to in a split, else the whole frame for one camera.
    private func feedRect(personKey: String, row: TranscriptRow) -> CGRect? {
        if let tile = video.podcastTiles.first(where: { $0.personKey == personKey }) {
            return CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)
        }
        guard let layout = video.podcastLayout.flatMap(PodcastLayout.init(rawValue:)) else { return nil }
        switch layout {
        case .singleCamera:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .splitHorizontal:
            guard let turn = bestTurn(for: row), turn.personKey == personKey else { return nil }
            let seam = video.podcastSeamX ?? 0.5
            switch turn.resolvedSide {
            case .left: return CGRect(x: 0, y: 0, width: seam, height: 1)
            case .right: return CGRect(x: seam, y: 0, width: 1 - seam, height: 1)
            case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
            case .unknown: return nil
            }
        case .grid:
            return nil
        }
    }

    /// The picture's rectangle inside a letterboxed player of `size`.
    nonisolated static func videoRect(in size: CGSize, videoWidth: Int, videoHeight: Int) -> CGRect {
        guard size.width > 0, size.height > 0, videoWidth > 0, videoHeight > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = CGFloat(videoWidth) / CGFloat(videoHeight)
        var width = size.width, height = size.width / aspect
        if height > size.height { height = size.height; width = size.height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The scene tags under a line, each a button that plays the scene
    /// carrying the tag.
    private func tagLine(_ row: TranscriptRow, tags: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                let scene = lineScenes[row.id]?.first { $0.tags.contains(tag) }
                Button {
                    guard let scene else { return }
                    Task {
                        await play(start: scene.startTime, end: scene.endTime,
                                   label: "Scene tagged \(tag == "reel-highlight" ? "Reel" : tag)", rowID: nil)
                    }
                } label: {
                    TagChip(tag: tag)
                }
                .buttonStyle(.plain)
                .disabled(scene == nil)
                .help(scene.map { "Watch the scene tagged \(tag) (\($0.startTime.timecode)–\($0.endTime.timecode)) in the panel" } ?? tag)
            }
        }
    }

    // MARK: - Re-cut by speaker

    private func recut() {
        Task {
            guard let split = await store.recutTranscriptBySpeaker(videoID: video.id) else { return }
            recutNote = split == 0 ? "Every row already has one speaker."
                : "\(split) row\(split == 1 ? "" : "s") split where the speaker changed."
            await load()
        }
    }

    private func undoRecut() {
        Task {
            if await store.undoTranscriptRecut(videoID: video.id) {
                recutNote = "The transcriber's rows are back."
                await load()
            }
        }
    }

    // MARK: - Playback

    /// Play the line in the panel, or stop it when it is the one playing.
    private func togglePlayback(_ row: TranscriptRow) async {
        if playing?.rowID == row.id {
            stopPlayback(releasePlayer: false)
            return
        }
        let who = speakerLabel(row).map { "\($0) · " } ?? ""
        await play(start: row.startTime, end: row.endTime, label: who + "line at \(row.startTime.timecode)", rowID: row.id)
    }

    /// Seek the panel's player to a range and play it; a boundary observer
    /// stops it at `end` (nil plays on to the end of the file).
    private func play(start: Double, end: Double?, label: String, rowID: Int64?) async {
        guard let player = await preparedPlayer() else { return }
        stopPlayback(releasePlayer: false)
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        if let end {
            let stopAt = CMTime(seconds: max(end, start + 0.2), preferredTimescale: 600)
            boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: stopAt)], queue: .main) {
                Task { @MainActor in player.pause() }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            Task { @MainActor in playbackTime = time.seconds }
        }
        playing = PlayingRange(start: start, end: end, label: label, rowID: rowID)
        playbackTime = start
        player.play()
    }

    /// The sheet's player, opened on first use and kept ready for every
    /// later line (a seek on an item that is not ready yet is dropped, so
    /// the first play waits for readiness).
    private func preparedPlayer() async -> AVPlayer? {
        if let player { return player }
        guard await DrivePlayback.prepare(video.url),
              let asset = try? await DriveLocalAsset.make(video.url) else {
            playbackUnavailable = true
            return nil
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        for _ in 0..<100 where item.status != .readyToPlay {
            if item.status == .failed { playbackUnavailable = true; return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A line that runs to the end of the file stops with the file.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            Task { @MainActor in stopPlayback(releasePlayer: false) }
        }
        self.player = player
        return player
    }

    private func stopPlayback(releasePlayer: Bool) {
        player?.pause()
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playing = nil
        playbackTime = nil
        if releasePlayer {
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player = nil
        }
    }

    /// The speaker column: who says the line, and a menu to say otherwise —
    /// a person of this video, anyone else in the library, or Unknown; the
    /// same choices for every line that reads as this speaker; and back to
    /// automatic once overridden. Attribution saves at once, like Revert.
    private func speakerMenu(_ row: TranscriptRow) -> some View {
        let label = speakerLabel(row)
        let attribution = speakerDrafts[row.id] ?? row.speaker
        let overridden = attribution != .automatic
        let pending = speakerDrafts[row.id] != nil && speakerDrafts[row.id] != row.speaker
        let group = sameSpeakerRows(as: row)
        return Menu {
            speakerChoices(current: attribution, label: label) { speaker in
                attribute([row], speaker)
            }
            if group.count > 1, let label {
                Divider()
                Menu("All \(group.count) Lines by \(label)") {
                    speakerChoices(current: nil, label: nil) { speaker in
                        attribute(group, speaker)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: overridden ? "person.fill.checkmark" : "person.fill")
                    .font(.caption2)
                Text(label ?? "Speaker?")
                    .font(.caption.weight(label == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(label == nil ? AnyShapeStyle(.tertiary)
                             : label == TranscriptSpeakers.unknownLabel ? AnyShapeStyle(.secondary)
                             : pending ? AnyShapeStyle(Color.orange)
                             : AnyShapeStyle(Color.accentColor))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(pending ? "Changed here — Apply saves it"
              : overridden ? "You set who says this line — click to change it or go back to automatic"
              : "Who the speaker detection says is talking — click to correct it")
        .accessibilityLabel("Speaker: \(label ?? "not known")")
    }

    @ViewBuilder
    private func speakerChoices(current: TranscriptRow.SpeakerAttribution?, label: String?,
                                pick: @escaping (TranscriptRow.SpeakerAttribution) -> Void) -> some View {
        ForEach(roster) { entry in
            choice(entry.displayName, .person(key: entry.key), current: current, pick: pick)
        }
        if !otherPeople.isEmpty {
            Menu("Other People") {
                ForEach(otherPeople) { person in
                    choice(person.displayName, .person(key: person.key), current: current, pick: pick)
                }
            }
        }
        choice(TranscriptSpeakers.unknownLabel, .unknown, current: current, pick: pick)
        if let current, current != .automatic {
            Divider()
            Button("Automatic") { pick(.automatic) }
        }
    }

    private func choice(_ title: String, _ speaker: TranscriptRow.SpeakerAttribution,
                        current: TranscriptRow.SpeakerAttribution?,
                        pick: @escaping (TranscriptRow.SpeakerAttribution) -> Void) -> some View {
        Button {
            pick(speaker)
        } label: {
            if current == speaker {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Stage a speaker change; Apply writes every staged change at once.
    private func attribute(_ lines: [TranscriptRow], _ speaker: TranscriptRow.SpeakerAttribution) {
        for line in lines {
            if speaker == line.speaker { speakerDrafts[line.id] = nil } else { speakerDrafts[line.id] = speaker }
        }
    }

    private func load() async {
        guard let database = store.database else { return }
        rows = (try? await database.fetchTranscripts(videoID: video.id)) ?? []
        let speakers = await store.speakerTurns(videoID: video.id)
        turns = speakers.turns
        roster = speakers.roster
        let people = store.people
        speakerLabels = rows.reduce(into: [:]) { labels, row in
            labels[row.id] = TranscriptSpeakers.label(for: row, turns: turns, roster: roster, people: people)
        }
        hasRecut = await store.hasTranscriptRecut(videoID: video.id)
        let scenes = store.scenes.filter { $0.videoID == video.id && !$0.ignored }
        lineScenes = rows.reduce(into: [:]) { result, row in
            let covering = Self.scenes(covering: row, in: scenes)
            if !covering.isEmpty { result[row.id] = covering }
        }
        lineTags = lineScenes.mapValues { Self.lineTags($0.flatMap(\.tags)) }
        isLoading = false
    }

    /// Apply: every edited line and every staged speaker change, in one go.
    private func save(thenDismiss: Bool) {
        guard let database = store.database else { return }
        let changes = rows.compactMap { row -> (id: Int64, text: String)? in
            guard let draft = drafts[row.id] else { return nil }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != row.text ? (row.id, trimmed) : nil
        }
        // One write per distinct attribution.
        var speakerChanges: [TranscriptRow.SpeakerAttribution: [Int64]] = [:]
        for row in rows {
            if let draft = speakerDrafts[row.id], draft != row.speaker { speakerChanges[draft, default: []].append(row.id) }
        }
        guard !changes.isEmpty || !speakerChanges.isEmpty else { if thenDismiss { dismiss() }; return }
        isSaving = true
        Task {
            do {
                if !changes.isEmpty { try await database.updateTranscriptTexts(changes) }
                for (speaker, ids) in speakerChanges {
                    await store.setTranscriptSpeaker(rowIDs: ids, videoID: video.id, speaker: speaker)
                }
                drafts = [:]
                speakerDrafts = [:]
                await load()
                if thenDismiss { dismiss() }
            } catch {
                store.presentError("Could not save the transcript", error)
            }
            isSaving = false
        }
    }

    private func revert(_ row: TranscriptRow) {
        guard let database = store.database else { return }
        Task {
            try? await database.revertTranscriptText(id: row.id)
            drafts[row.id] = nil
            await load()
        }
    }
}
