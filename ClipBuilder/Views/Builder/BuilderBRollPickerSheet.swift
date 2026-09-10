import SwiftUI
import AVKit

/// Park the playhead, press B, slide the window, press Enter. The picker
/// chooses the footage and the exact source window for a cutaway, then adds
/// it at the playhead on the chosen track. Nothing is committed until Enter:
/// the window is draft state, so Escape leaves the timeline untouched.
struct BuilderBRollPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One choosable piece of footage: an analyzed scene or a Library video.
    struct Source: Identifiable {
        var id: String
        var source: CutawaySource
        var isBRoll: Bool
        var favorite: Bool
        var name: String
        var detail: String
        var posterTime: Double
    }

    /// The loupe's window, matching ClipTrimEditor's fine trim.
    private static let loupeSpan = 10.0

    @State private var searchText = ""
    @State private var bRollOnly = false
    @State private var favoritesOnly = false
    @State private var selectedID: String?
    @State private var windowStart: Double = 0
    @State private var windowEnd: Double = 0
    @State private var track = 0
    @State private var coverAll = false
    @State private var added: Set<String> = []
    @State private var status: String?
    @State private var player: AVPlayer?
    @State private var looping = false
    @State private var loopObserver: Any?
    @State private var playerURL: URL?
    /// The id `restoreLastPick` just selected. SwiftUI delivers the
    /// selection change after the restore returns, so a flag cleared by a
    /// `defer` would already be false: the pending id is compared instead
    /// and only then forgotten.
    @State private var pendingRestoreID: String?
    /// Bumped for every player load; a load whose generation is stale (or
    /// whose sheet has gone) throws its result away.
    @State private var playerGeneration = 0
    @State private var loadTask: Task<Void, Never>?
    @State private var isPresented = true

    /// Whether a selection change should reset the window. A change that
    /// only reports the restored selection must not.
    nonisolated static func shouldResetWindow(newID: String?, pendingRestoreID: String?) -> Bool {
        guard let pendingRestoreID else { return true }
        return newID != pendingRestoreID
    }

    /// Whether a finished load may touch the player. A load that started
    /// before the sheet closed, before Stop, or before another load began
    /// must throw its result away — otherwise pressing Space twice quickly
    /// leaves a stopped picker playing.
    nonisolated static func shouldApplyLoad(loadGeneration: Int, currentGeneration: Int,
                                            isPresented: Bool, cancelled: Bool) -> Bool {
        loadGeneration == currentGeneration && isPresented && !cancelled
    }

    private var model: BuilderTimelineModel { store.builder }

    /// Where the cutaway will start: the spot a track's context menu asked
    /// for, else the playhead.
    private var startTime: Double { model.brollRequest?.time ?? model.playhead }

    // MARK: - Sources

    private var allSources: [Source] {
        var items: [Source] = store.scenes.filter { !$0.excluded }.map { scene in
            Source(id: "scene:\(scene.id)", source: .scene(scene), isBRoll: scene.isBRoll,
                   favorite: scene.favorite,
                   name: scene.videoFilename,
                   detail: scene.narrative ?? String(format: "%.1fs scene", scene.duration),
                   posterTime: (scene.startTime + scene.endTime) / 2)
        }
        let sceneVideos = Set(store.scenes.map(\.videoID))
        for video in store.videos where !sceneVideos.contains(video.id) && video.duration > 0 {
            items.append(Source(id: "file:\(video.path)",
                                source: .file(url: URL(fileURLWithPath: video.path), duration: video.duration),
                                isBRoll: false, favorite: false, name: video.filename,
                                detail: String(format: "%.0fs in the Library", video.duration),
                                posterTime: video.duration / 2))
        }
        return items
    }

    private var sources: [Source] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = allSources.filter { source in
            if bRollOnly && !source.isBRoll { return false }
            if favoritesOnly && !source.favorite { return false }
            guard !needle.isEmpty else { return true }
            return source.name.localizedCaseInsensitiveContains(needle)
                || source.detail.localizedCaseInsensitiveContains(needle)
        }
        // B-roll-tagged footage first; the tag only orders this list.
        return filtered.sorted {
            $0.isBRoll == $1.isBRoll ? $0.name.localizedCompare($1.name) == .orderedAscending : $0.isBRoll
        }
    }

    /// The chosen source. `selectedID` is kept pointing at it, so the list
    /// highlight and the strip never disagree.
    private var selected: Source? {
        sources.first { $0.id == selectedID }
    }

    // MARK: - Window

    private var length: Double { max(0.1, windowEnd - windowStart) }

    private var cuts: [Double] {
        guard let selected else { return [] }
        return model.mainCuts(inTrack: track, from: startTime, to: startTime + length)
            .map { windowStart + ($0 - startTime) }
            .filter { $0 > selected.source.window.start && $0 < selected.source.window.end }
    }

    private var coversFootage: Bool {
        model.hasMainClip(inTrack: track, from: startTime, to: startTime + length)
    }

    private func resetWindow(for source: Source, keepingLength: Double? = nil) {
        let bounds = source.source.window
        let wanted = keepingLength
            ?? model.defaultCutawayDuration(at: startTime, track: track)
        let span = min(max(0.1, wanted), max(0.1, bounds.end - bounds.start))
        windowStart = bounds.start
        windowEnd = bounds.start + span
        rebuildPlayer(for: source)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                sourceList
                    .frame(width: 260)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .modalCloseButton { cancel() }
        .onAppear {
            isPresented = true
            restoreLastPick()
        }
        .onDisappear {
            isPresented = false
            loadTask?.cancel()
            loadTask = nil
            stopLooping()
        }
        .onChange(of: sources.map(\.id)) { _, ids in
            // Filtering away the selection must move it, not strand it.
            guard let selectedID, ids.contains(selectedID) else {
                self.selectedID = ids.first
                return
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard Self.shouldResetWindow(newID: newID, pendingRestoreID: pendingRestoreID) else {
                pendingRestoreID = nil
                return
            }
            pendingRestoreID = nil
            guard let selected else { return }
            resetWindow(for: selected, keepingLength: length)
        }
        .onKeyPress(.upArrow) { cycleSource(-1); return .handled }
        .onKeyPress(.downArrow) { cycleSource(1); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            // A frame at a time, a second with Shift.
            let step = press.modifiers.contains(.shift) ? 1.0 : 1.0 / 30
            nudge(by: press.key == .leftArrow ? -step : step)
            return .handled
        }
        .onKeyPress(.space) { toggleLoop(); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA123456"), phases: .down) { press in
            if press.characters.lowercased() == "a" {
                coverAll.toggle()
                return .handled
            }
            if let digit = Int(press.characters), digit >= 1, digit <= model.document.trackCount {
                track = digit - 1
                return .handled
            }
            return .ignored
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add B-roll")
                    .font(.headline)
                Text("Covers this track's area from \(startTime.timecode) while the clip underneath keeps playing and talking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.spaceL)
    }

    private var sourceList: some View {
        VStack(spacing: Theme.spaceS) {
            TextField("Search footage", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Theme.spaceM)
                .padding(.top, Theme.spaceS)
            HStack(spacing: Theme.spaceS) {
                Toggle("B-roll", isOn: $bRollOnly)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Only footage tagged as B-roll")
                Toggle("Favorites", isOn: $favoritesOnly)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Only scenes marked as favorites")
                Spacer()
            }
            .padding(.horizontal, Theme.spaceM)
            List(sources, selection: $selectedID) { source in
                HStack(spacing: Theme.spaceS) {
                    VideoThumbnail(url: source.source.url, time: source.posterTime,
                                   cornerRadius: 4)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(source.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if source.isBRoll {
                                Text("B")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 3)
                                    .background(.orange, in: .capsule)
                            }
                            if added.contains(source.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                                    .help("Already added in this session")
                            }
                        }
                        Text(source.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(source.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            let bounds = selected.source.window
            let sourceSpan = max(0.1, bounds.end - bounds.start)
            VStack(alignment: .leading, spacing: Theme.spaceM) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
                }
                // Fine trim first, like ClipTrimEditor: a short window is
                // hard to place on a strip that spans the whole source.
                let loupeShown = sourceSpan > Self.loupeSpan + 0.5
                if loupeShown {
                    let span = min(Self.loupeSpan, sourceSpan)
                    let loupeStart = min(max(bounds.start, windowStart - (span - length) / 2),
                                         max(bounds.start, bounds.end - span))
                    VideoTrimSlider(url: selected.source.url, duration: span,
                                    start: $windowStart, end: $windowEnd,
                                    timeOffset: loupeStart,
                                    markers: cuts,
                                    rulerInterval: 0.5,
                                    minimumSpan: 0.2,
                                    showsTimes: false, stripHeight: 56,
                                    onDragEnded: { rebuildPlayer(for: selected) })
                        .help("Fine trim — a 10 second window around the selection")
                }
                LoupeCompanion(active: loupeShown) {
                    VideoTrimSlider(url: selected.source.url,
                                    duration: sourceSpan,
                                    start: $windowStart, end: $windowEnd,
                                    timeOffset: bounds.start,
                                    markers: cuts,
                                    minimumSpan: 0.2,
                                    stripHeight: LoupeCompanionMetrics.stripHeight(52, loupeShown: loupeShown),
                                    onDragEnded: { rebuildPlayer(for: selected) })
                }
                HStack(spacing: Theme.spaceM) {
                    Text("Length")
                        .font(.caption)
                    TextField("Seconds", value: Binding(
                        get: { length },
                        set: { newLength in
                            let span = min(max(0.1, newLength), max(0.1, bounds.end - windowStart))
                            windowEnd = windowStart + span
                        }), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Picker("Track", selection: $track) {
                        ForEach(0..<model.document.trackCount, id: \.self) { index in
                            Text("Track \(index + 1)").tag(index)
                        }
                    }
                    .frame(width: 150)
                    .help("Digits 1–6 pick the track")
                    Toggle("Cover all areas", isOn: $coverAll)
                        .toggleStyle(.checkbox)
                        .help("A: cover the whole screen instead of this track's area")
                    Spacer()
                }
                if let status {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !coversFootage {
                    Label("Nothing is playing under this spot — the B-roll will sit over black.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if !cuts.isEmpty {
                    Text("This window straddles a cut in the footage underneath (marked on the strip).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Theme.spaceL)
        } else {
            ContentUnavailableView("No footage", systemImage: "film",
                                   description: Text("Analyze a video first, or clear the search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Text("Space loops · ↑↓ change footage · ←→ nudge a frame (⇧ a second) · A covers all areas")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { cancel() }
            Button("Add and Keep Going") { add(advance: true) }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(selected == nil)
            Button("Add B-roll") { add(advance: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
        }
        .padding(Theme.spaceL)
    }

    // MARK: - Actions

    private func restoreLastPick() {
        track = min(max(0, model.brollRequest?.track ?? model.focusedTrack ?? 0),
                    model.document.trackCount - 1)
        if let last = model.lastBRollPick {
            if model.brollRequest == nil {
                track = min(max(0, last.track), model.document.trackCount - 1)
            }
            coverAll = last.coverAll
            if let match = sources.first(where: { $0.id == last.sourceKey }) {
                pendingRestoreID = match.id
                selectedID = match.id
                let bounds = match.source.window
                windowStart = min(max(bounds.start, last.sourceStart), max(bounds.start, bounds.end - 0.2))
                windowEnd = min(bounds.end, windowStart + max(0.2, last.length))
                rebuildPlayer(for: match)
                return
            }
        }
        if let first = sources.first {
            pendingRestoreID = first.id
            selectedID = first.id
            resetWindow(for: first)
        }
    }

    private func cycleSource(_ delta: Int) {
        guard !sources.isEmpty else { return }
        let current = sources.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(0, current + delta), sources.count - 1)
        selectedID = sources[next].id
    }

    /// Slide the window without changing its length, inside the source.
    private func nudge(by seconds: Double) {
        guard let selected else { return }
        let bounds = selected.source.window
        let span = length
        let start = min(max(bounds.start, windowStart + seconds), max(bounds.start, bounds.end - span))
        windowStart = start
        windowEnd = start + span
        rebuildPlayer(for: selected)
    }

    private func add(advance: Bool) {
        guard let selected else { return }
        let start = startTime
        let outcome = model.addCutaway(source: selected.source, at: start, track: track,
                                       duration: length, sourceStart: windowStart,
                                       coverAll: coverAll)
        status = outcome.message(at: start)
        guard let uid = outcome.uid else { return }
        model.brollRequest = nil
        added.insert(selected.id)
        model.lastBRollPick = BuilderTimelineModel.BRollPick(
            sourceKey: selected.id, sourceStart: windowStart, length: length,
            track: track, coverAll: coverAll)
        if advance {
            // The inserted clip may be shorter than asked (a short source):
            // move to where it actually ends.
            let added = model.clip(uid)
            model.playhead = (added?.startTime ?? start) + (added?.duration ?? length)
        } else if status == nil {
            stopLooping()
            dismiss()
        }
    }

    private func cancel() {
        stopLooping()
        model.brollRequest = nil
        dismiss()
    }

    // MARK: - Looping player

    private func rebuildPlayer(for source: Source) {
        let url = source.source.url
        let created = player ?? AVPlayer()
        player = created
        playerURL = url
        let wasLooping = looping
        let from = windowStart
        playerGeneration += 1
        let generation = playerGeneration
        // One load at a time: a fast run through the list must not have an
        // older, slower load win at the end.
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            // Drive-backed media has to be local before it can play, the
            // same resolution the fast preview does.
            let ready = await DrivePlayback.prepare(url)
            guard ready, Self.shouldApplyLoad(loadGeneration: generation,
                                              currentGeneration: playerGeneration,
                                              isPresented: isPresented,
                                              cancelled: Task.isCancelled) else { return }
            guard let asset = try? await DriveLocalAsset.make(url) else { return }
            guard Self.shouldApplyLoad(loadGeneration: generation,
                                       currentGeneration: playerGeneration,
                                       isPresented: isPresented,
                                       cancelled: Task.isCancelled) else { return }
            created.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            // The completion form: in an async context the plain seek(to:)
            // resolves to the awaitable overload.
            created.seek(to: CMTime(seconds: from, preferredTimescale: 600)) { _ in }
            // Only resume if the user has not stopped in the meantime.
            if wasLooping, looping { startLooping() }
        }
    }

    private func toggleLoop() {
        if looping { stopLooping() } else { startLooping() }
    }

    private func startLooping() {
        guard let player else { return }
        // Exactly one observer at a time, whatever order the callers run in.
        removeObserver()
        looping = true
        player.seek(to: CMTime(seconds: windowStart, preferredTimescale: 600))
        player.play()
        loopObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolated {
                    if time.seconds >= windowEnd - 0.02 || time.seconds < windowStart - 0.5 {
                        player.seek(to: CMTime(seconds: windowStart, preferredTimescale: 600))
                    }
                }
            }
    }

    private func removeObserver() {
        if let loopObserver { player?.removeTimeObserver(loopObserver) }
        loopObserver = nil
    }

    private func stopLooping() {
        looping = false
        // Stop wins over any load still in flight: bumping the generation
        // makes a late arrival discard itself instead of pressing play.
        playerGeneration += 1
        removeObserver()
        player?.pause()
    }
}
