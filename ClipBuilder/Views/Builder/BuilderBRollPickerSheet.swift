import SwiftUI
import AVKit

/// Park the playhead, press B, slide the window, press Enter. The picker
/// chooses the footage and the exact source window for a cutaway, then adds
/// it at the playhead on the chosen track. Nothing is committed until Enter:
/// the window is draft state, so Escape leaves the timeline untouched.
struct BuilderBRollPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One choosable item: footage for a cutaway (an analyzed scene or a
    /// Library video), or a suggested Library photo, which is added as an
    /// image overlay rather than as B-roll.
    struct Source: Identifiable {
        var id: String
        /// Footage for a cutaway; nil for a photo.
        var source: CutawaySource?
        /// A Library image's path; nil for footage.
        var photoPath: String?
        var isBRoll: Bool
        var favorite: Bool
        /// Why the Library suggested this for the spot being covered.
        var reason: String?
        var name: String
        var detail: String
        var posterTime: Double

        var isPhoto: Bool { photoPath != nil }
    }

    /// The clips a suggestion should be about: the main clips on `track`
    /// playing at `time`, and nothing else. Suggestions are then about the
    /// spot being covered rather than about the whole timeline.
    nonisolated static func suggestionScope(document: TimelineDocument, track: Int,
                                            at time: Double) -> TimelineDocument {
        var scoped = TimelineDocument()
        scoped.videoTrack = document.mainClips(inTrack: track).filter {
            $0.startTime <= time + 0.001 && time < $0.startTime + $0.duration - 0.001
        }
        scoped.trackCount = 1
        return scoped
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
    /// Library image metadata, read once when the sheet opens: what the
    /// photo suggestions are drawn from.
    @State private var imageAssets: [LibraryAssetMetadata] = []
    /// What the Library suggests for the spot being covered, recomputed
    /// when the track or the start time changes.
    @State private var suggested: [Source] = []
    /// How long a suggested photo stays on screen.
    @State private var photoLength: Double = 3

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
            Source(id: "scene:\(scene.id)", source: .scene(scene), photoPath: nil,
                   isBRoll: scene.isBRoll, favorite: scene.favorite, reason: nil,
                   name: scene.videoFilename,
                   detail: scene.narrative ?? String(format: "%.1fs scene", scene.duration),
                   posterTime: (scene.startTime + scene.endTime) / 2)
        }
        let sceneVideos = Set(store.scenes.map(\.videoID))
        for video in store.videos where !sceneVideos.contains(video.id) && video.duration > 0 {
            items.append(Source(id: "file:\(video.path)",
                                source: .file(url: URL(fileURLWithPath: video.path), duration: video.duration),
                                photoPath: nil, isBRoll: false, favorite: false, reason: nil,
                                name: video.filename,
                                detail: String(format: "%.0fs in the Library", video.duration),
                                posterTime: video.duration / 2))
        }
        return items
    }

    /// The Library's suggestions for this spot, as pickable items. A B-roll
    /// suggestion reuses the scene's own entry (same id, so selection, the
    /// remembered pick, the "used" mark and Enter all behave as usual) with
    /// the reason as its detail line; a photo becomes an item of its own.
    private func makeSuggested() -> [Source] {
        let scope = Self.suggestionScope(document: model.document, track: track, at: startTime)
        guard !scope.videoTrack.isEmpty else { return [] }
        let suggestions = MediaSuggestionService.suggestions(
            document: scope, scenes: store.scenes, people: store.people, assets: imageAssets)
        let footage = Dictionary(uniqueKeysWithValues: allSources.map { ($0.id, $0) })
        var items: [Source] = []
        var seen = Set<String>()
        for suggestion in suggestions {
            switch suggestion.kind {
            case .bRoll:
                guard let sceneID = suggestion.sceneID,
                      var item = footage["scene:\(sceneID)"], seen.insert(item.id).inserted else { continue }
                item.reason = suggestion.reason
                item.detail = suggestion.reason
                items.append(item)
            case .photo:
                guard let path = suggestion.path, seen.insert("photo:\(path)").inserted else { continue }
                items.append(Source(id: "photo:\(path)", source: nil, photoPath: path,
                                    isBRoll: false, favorite: false, reason: suggestion.reason,
                                    name: (path as NSString).lastPathComponent,
                                    detail: suggestion.reason, posterTime: 0))
            }
        }
        return items
    }

    /// Whether the Suggested group is on screen: never while searching,
    /// and never when the Library has nothing to suggest here.
    private var showsSuggested: Bool {
        !suggested.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Everything selectable, in the order it is drawn.
    private var visibleSources: [Source] {
        (showsSuggested ? suggested : []) + sources
    }

    private var sources: [Source] {
        let suggestedIDs = Set(showsSuggested ? suggested.map(\.id) : [])
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = allSources.filter { source in
            // Nothing is listed twice: a suggested scene lives in the group
            // above, under the same id.
            if suggestedIDs.contains(source.id) { return false }
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
        visibleSources.first { $0.id == selectedID }
    }

    // MARK: - Window

    private var length: Double { max(0.1, windowEnd - windowStart) }

    private var cuts: [Double] {
        guard let footage = selected?.source else { return [] }
        return model.mainCuts(inTrack: track, from: startTime, to: startTime + length)
            .map { windowStart + ($0 - startTime) }
            .filter { $0 > footage.window.start && $0 < footage.window.end }
    }

    private var coversFootage: Bool {
        model.hasMainClip(inTrack: track, from: startTime, to: startTime + length)
    }

    private func resetWindow(for source: Source, keepingLength: Double? = nil) {
        guard let footage = source.source else { return }
        let bounds = footage.window
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
        .task {
            // The Library's image metadata is what photo suggestions are
            // made of; it is read once per opening.
            guard let database = store.database else { return }
            imageAssets = (try? await database.fetchAssetMetadata(kind: AssetKind.images.rawValue)) ?? []
            suggested = makeSuggested()
        }
        .onChange(of: track) { _, _ in suggested = makeSuggested() }
        .onChange(of: startTime) { _, _ in suggested = makeSuggested() }
        .onDisappear {
            isPresented = false
            loadTask?.cancel()
            loadTask = nil
            stopLooping()
        }
        .onChange(of: visibleSources.map(\.id)) { _, ids in
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
            // A photo has no window to reset; its length stands on its own.
            guard selected.source != nil else {
                stopLooping()
                return
            }
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
            List(selection: $selectedID) {
                if showsSuggested {
                    Section("Suggested for this spot") {
                        ForEach(suggested) { source in
                            row(source).tag(source.id)
                        }
                    }
                }
                Section(showsSuggested ? "All footage" : "") {
                    ForEach(sources) { source in
                        row(source).tag(source.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// One row of the source list: footage or a suggested photo.
    @ViewBuilder
    private func row(_ source: Source) -> some View {
        HStack(spacing: Theme.spaceS) {
            if let path = source.photoPath {
                ImageThumbnail(url: URL(fileURLWithPath: path))
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let footage = source.source {
                VideoThumbnail(url: footage.url, time: source.posterTime, cornerRadius: 4)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(source.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if source.reason != nil {
                        Text("Suggested")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(.blue, in: .capsule)
                    }
                    if source.isPhoto {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("A Library photo: it is added as an image overlay, not as B-roll")
                    }
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
    }

    /// A suggested photo: what it looks like and how long it stays up. It
    /// has no source window, no track and no area — it is an overlay.
    @ViewBuilder
    private func photoDetail(_ source: Source, path: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            ImageThumbnail(url: URL(fileURLWithPath: path))
                .frame(maxWidth: .infinity, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
            if let reason = source.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.spaceM) {
                Text("Length")
                    .font(.caption)
                TextField("Seconds", value: Binding(
                    get: { photoLength },
                    set: { photoLength = max(0.5, $0) }),
                          format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer()
            }
            if let status {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Added as an image overlay at \(startTime.timecode) — it covers the whole frame while it shows, and no clip moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Theme.spaceL)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected, let path = selected.photoPath {
            photoDetail(selected, path: path)
        } else if let selected, let footage = selected.source {
            let bounds = footage.window
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
                    VideoTrimSlider(url: footage.url, duration: span,
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
                    VideoTrimSlider(url: footage.url,
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
            Button(selected?.isPhoto == true ? "Add Photo" : "Add B-roll") { add(advance: false) }
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
            if let match = visibleSources.first(where: { $0.id == last.sourceKey }),
               let bounds = match.source?.window {
                pendingRestoreID = match.id
                selectedID = match.id
                windowStart = min(max(bounds.start, last.sourceStart), max(bounds.start, bounds.end - 0.2))
                windowEnd = min(bounds.end, windowStart + max(0.2, last.length))
                rebuildPlayer(for: match)
                return
            }
        }
        if let first = visibleSources.first {
            pendingRestoreID = first.id
            selectedID = first.id
            resetWindow(for: first)
        }
    }

    private func cycleSource(_ delta: Int) {
        let items = visibleSources
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(0, current + delta), items.count - 1)
        selectedID = items[next].id
    }

    /// Slide the window without changing its length, inside the source.
    private func nudge(by seconds: Double) {
        guard let selected, let footage = selected.source else { return }
        let bounds = footage.window
        let span = length
        let start = min(max(bounds.start, windowStart + seconds), max(bounds.start, bounds.end - span))
        windowStart = start
        windowEnd = start + span
        rebuildPlayer(for: selected)
    }

    private func add(advance: Bool) {
        guard let selected else { return }
        let start = startTime
        if let path = selected.photoPath {
            addPhoto(selected, path: path, at: start, advance: advance)
            return
        }
        guard let footage = selected.source else { return }
        let outcome = model.addCutaway(source: footage, at: start, track: track,
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

    /// A suggested photo becomes an image overlay, never a cutaway: it has
    /// no track, no area and no source window.
    private func addPhoto(_ source: Source, path: String, at start: Double, advance: Bool) {
        let uid = model.addPhotoOverlay(path: path, at: start, length: photoLength)
        status = nil
        model.brollRequest = nil
        added.insert(source.id)
        if advance {
            model.playhead = model.imageItem(uid)?.endTime ?? (start + photoLength)
        } else {
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
        guard let footage = source.source else {
            // A photo has no player; a stale one must not keep running.
            stopLooping()
            return
        }
        let url = footage.url
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
