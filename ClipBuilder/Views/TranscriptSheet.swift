import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole transcript of one video, every segment editable in place.
/// Save writes all changed segments at once; a segment edited before can
/// be reverted to what the transcriber produced. Opened from the Raw
/// Videos detail pane and from batch/scene context menus.
struct TranscriptSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let video: VideoRecord
    var focusSetsPicker = false

    private var currentVideo: VideoRecord {
        store.videos.first { $0.id == video.id } ?? video
    }

    private var coverage: AnalysisCoverage.Report {
        AnalysisCoverage.report(video: currentVideo, activeRun: store.activeLayer(videoID: video.id).run,
                                scenes: currentVideoScenes, transcriptCount: rows.count)
    }

    @State private var rows: [TranscriptRow] = []
    @State private var transcriptionSets: [TranscriptionSet] = []
    @State private var selectedTranscriptionKey = ""
    @State private var activeTranscriptionKey: String?
    @State private var pinnedTranscriptionKey: String?
    @State private var missingTranscriptionPin = false
    @FocusState private var setsPickerFocused: Bool
    /// Edited text per segment id; only segments whose text differs from
    /// the stored row are written on Apply.
    @State private var drafts: [Int64: String] = [:]
    /// Each line's translations, shown under it (by original row id).
    @State private var translationsByRow: [Int64: [TranscriptRow]] = [:]
    /// The languages the pills turned off; never all of them.
    @State private var hiddenLanguages: Set<TranscriptTranslationRows.Language> = []
    private var languages: [TranscriptTranslationRows.Language] { TranscriptTranslationRows.languages(rows) }
    private var missingLanguages: [String] {
        TranscriptTranslationRows.missing(captions: store.projectLanguages.captions, rows: rows)
    }
    private func shows(_ row: TranscriptRow) -> Bool {
        !hiddenLanguages.contains(.init(code: row.language, isTranslation: row.isTranslation))
    }
    /// Who says a line, as changed here and not yet applied.
    @State private var speakerDrafts: [Int64: TranscriptRow.SpeakerAttribution] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @State private var showTools = false
    @State private var confirmRetranscribe = false
    @State private var editMode = false
    @State private var compareMode = false
    /// The version being renamed from the version menu, and the name typed.
    @State private var renamingSet: TranscriptionSet?
    @State private var renameText = ""
    @State private var confirmRevertAll = false
    @State private var confirmDeleteSet = false
    @State private var confirmDeleteAllSets = false
    @State private var retranscribeEditCount = 0
    /// The word timings offered by the re-transcribe dialog, read when it opens.
    @State private var retranscribeOptions: [WordTiming] = [.recognizer]
    @State private var confirmUndoRecut = false
    @State private var undoRecutEditCount = 0
    @State private var showsQA = false
    /// The topics of the active transcript, as a third view beside Lines and Q&A.
    @State private var showsTopics = false
    @State private var topics: [TopicRange] = []
    /// Cleanup cuts still waiting for a decision, shown on their button.
    @State private var pendingCuts = 0
    /// The line a picked topic starts at; the list scrolls to it.
    @State private var scrollTarget: Int64?
    private var analysisJob: AppJob? { store.jobs.latest(.transcriptAnalysis, subjectID: String(video.id)) }
    /// Lines on show: the controls that act on lines hide in the other views.
    private var showsLines: Bool { !showsQA && !(showsTopics && !topics.isEmpty) }
    @State private var videoScenes: [SceneRecord] = []
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
    @AppStorage(PlaybackSpeed.key) private var speed = 1.0
    @State private var boundaryObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    /// The player being opened, shared by every request that arrives meanwhile.
    @State private var preparing: Task<AVPlayer?, Never>?
    /// Bumped by each play request and on release: a stale request stops.
    @State private var playToken = 0
    /// Bumped when the player is released (sheet closed).
    @State private var playerEpoch = 0
    /// The file is not on this Mac (a Drive copy not downloaded), so the
    /// play buttons stay off.
    @State private var playbackUnavailable = false
    /// A re-cut by speaker happened (the transcriber's rows are backed up).
    @State private var hasRecut = false
    /// What the last Re-cut did, shown briefly under the header.
    @State private var recutNote: String?
    private var mappingJob: AppJob? { store.jobs.latest(.mapSpeakers, subjectID: String(video.id)) }
    /// True until the job's task has really ended: Stop marks the job
    /// cancelled at once, while its last writes may still be landing.
    private var isMappingSpeakers: Bool {
        mappingJob?.status == .running || store.speakerMappingVideoIDs.contains(video.id)
    }
    private var translationJob: AppJob? {
        store.jobs.latest(.transcriptTranslation, subjectID: "\(video.id):\(selectedTranscriptionKey)")
    }
    /// Lines attributed by hand that the speaker map does not agree with.
    @State private var unlearnedCorrections = 0
    /// The map's latest log line while it runs.
    private var mappingStatus: String? { mappingJob?.statusLine }
    /// Lines whose speaker the last Fix Speakers changed, with the
    /// name they had before.
    @State private var changedByMap: [Int64: String] = [:]
    /// Consecutive lines by one speaker read as one block.
    @AppStorage("transcript.groupBySpeaker") private var groupBySpeaker = false

    static let editedFilter = "edited:text"
    private var editedCount: Int { rows.count { !$0.isTranslation && $0.originalText != nil } }
    private var canCompare: Bool { editedCount > 0 || !changedIDs.isEmpty }

    static let changedByMapFilter = "changed:map"

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
        let changed = rows.filter { (drafts[$0.id] ?? $0.text) != $0.text }
        let lines = changed.count { !$0.isTranslation }, translations = changed.count - lines
        if lines > 0 { parts.append("\(lines) line\(lines == 1 ? "" : "s") changed") }
        if translations > 0 { parts.append("\(translations) translation\(translations == 1 ? "" : "s") changed") }
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
        // A translation shows under its line, never as a row of its own.
        let rows = rows.filter { !$0.isTranslation }
        if tagFilter.isEmpty { return rows }
        if tagFilter == Self.editedFilter { return rows.filter { $0.originalText != nil } }
        if tagFilter == Self.changedByMapFilter { return rows.filter { changedByMap[$0.id] != nil } }
        return rows.filter { lineTags[$0.id]?.contains(tagFilter) == true }
    }

    /// Where each speaker block ends (the end time of its last visible
    /// line), per visible row, for the grouped reading.
    nonisolated static func blockEnds(_ rows: [TranscriptRow], sameSpeaker: (TranscriptRow, TranscriptRow) -> Bool) -> [Double] {
        var ends = [Double](repeating: 0, count: rows.count)
        var index = rows.count - 1
        while index >= 0 {
            let end = rows[index].endTime
            var start = index
            while start > 0, sameSpeaker(rows[start - 1], rows[start]) { start -= 1 }
            for i in start...index { ends[i] = end }
            index = start - 1
        }
        return ends
    }

    /// Bracket edges for consecutive visible lines in the same Q&A scene.
    /// Hidden lines do not split a run; visible lines without an exchange do.
    nonisolated static func exchangeSpans(_ rows: [TranscriptRow], exchange: (TranscriptRow) -> Int64?) -> [Int: ExchangeEdge] {
        let exchanges = rows.map(exchange)
        var edges: [Int: ExchangeEdge] = [:]
        for index in exchanges.indices {
            guard let id = exchanges[index] else { continue }
            let continuesBefore = index > 0 && exchanges[index - 1] == id
            let continuesAfter = index + 1 < exchanges.count && exchanges[index + 1] == id
            switch (continuesBefore, continuesAfter) {
            case (false, false): edges[index] = .only
            case (false, true): edges[index] = .first
            case (true, true): edges[index] = .middle
            case (true, false): edges[index] = .last
            }
        }
        return edges
    }

    private func exchangeScene(_ row: TranscriptRow) -> SceneRecord? {
        lineScenes[row.id]?.first { !$0.ignored && $0.tags.contains("q&a") }
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

    /// One check-pill per language on show (the spoken one first); with
    /// `allowAdd`, a dashed pill per project caption language still missing.
    /// The pills when they fit the bar, else the same choices in a menu.
    private func languageControls(allowAdd: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            languagePills(allowAdd: allowAdd)
            languageMenu(allowAdd: allowAdd)
        }
    }

    @ViewBuilder
    private func languageMenu(allowAdd: Bool) -> some View {
        let all = languages
        let missing = allowAdd && !rows.isEmpty && translationJob?.status != .running ? missingLanguages : []
        if all.count > 1 || !missing.isEmpty {
            Menu("Languages") {
                if all.count > 1 {
                    ForEach(all, id: \.self) { language in
                        Toggle(DubLanguageChoices.name(language.code) + (language.isTranslation ? "" : " (spoken)"), isOn: Binding(
                            get: { !hiddenLanguages.contains(language) },
                            set: { _ in hiddenLanguages = TranscriptTranslationRows.toggling(language, hidden: hiddenLanguages, all: all) }))
                    }
                }
                if !missing.isEmpty {
                    Divider()
                    ForEach(missing, id: \.self) { language in
                        Button("Add \(DubLanguageChoices.name(language)) Translation") {
                            store.addTranscriptTranslations(videoID: video.id, transcriptionKey: selectedTranscriptionKey, languages: [language])
                        }
                        .disabled(selectedTranscriptionKey.isEmpty)
                    }
                }
            }
            .lineLimit(1).fixedSize()
            .help("Show or hide a language of this transcript")
        }
    }

    @ViewBuilder
    private func languagePills(allowAdd: Bool) -> some View {
        let all = languages
        let missing = allowAdd && !rows.isEmpty ? missingLanguages : []
        if all.count > 1 || !missing.isEmpty {
            HStack(spacing: 6) {
                Text("Languages").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                if all.count > 1 {
                    ForEach(all, id: \.self) { language in
                        let shown = !hiddenLanguages.contains(language)
                        let name = DubLanguageChoices.name(language.code)
                        Button {
                            hiddenLanguages = TranscriptTranslationRows.toggling(language, hidden: hiddenLanguages, all: all)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.accentColor).opacity(shown ? 1 : 0)
                                    .accessibilityHidden(true)
                                Text(name).foregroundStyle(shown ? .primary : .secondary)
                                if !language.isTranslation { Text("spoken").foregroundStyle(.secondary) }
                            }
                            .font(.callout).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(.quaternary.opacity(shown ? 1 : 0.4), in: Capsule())
                            .overlay(Capsule().strokeBorder(shown ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.35)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(shown ? "Hide the \(name) \(language.isTranslation ? "translation" : "text")"
                              : "Show the \(name) \(language.isTranslation ? "translation" : "text")")
                        .accessibilityAddTraits(shown ? .isSelected : [])
                    }
                }
                if translationJob?.status == .running {
                    ProgressView().controlSize(.small)
                        .help(translationJob?.statusLine ?? "Translating…")
                } else {
                    ForEach(missing, id: \.self) { language in
                        let name = DubLanguageChoices.name(language)
                        Button {
                            store.addTranscriptTranslations(videoID: video.id, transcriptionKey: selectedTranscriptionKey, languages: [language])
                        } label: {
                            Label(name, systemImage: "plus")
                                .font(.callout).lineLimit(1).fixedSize()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedTranscriptionKey.isEmpty)
                        .help("Translate this transcript into \(name), a caption language of the project. Runs in the background; correct the result with Edit Text.")
                        .accessibilityLabel("Add \(name) translation")
                    }
                }
            }
            .fixedSize()
        }
    }

    private var selectedSet: TranscriptionSet? {
        transcriptionSets.first { $0.id == selectedTranscriptionKey } ?? transcriptionSets.first(where: \.isActive)
    }

    private func versionTitle(_ set: TranscriptionSet) -> String {
        set.name ?? TranscriptSetSwitch.date(set.createdAt)
    }

    private func versionState(_ set: TranscriptionSet) -> String {
        set.isPinned ? "Pinned" : set.isActive ? "In use" : "Read only"
    }

    private func versionDetail(_ set: TranscriptionSet) -> String {
        var parts: [String] = []
        if set.name != nil { parts.append(TranscriptSetSwitch.date(set.createdAt)) }
        parts.append("\(set.segmentCount) lines")
        if let language = set.language, !language.isEmpty {
            parts.append(DubLanguageChoices.name(language) + (set.hasTranslations ? " + translation" : ""))
        }
        if set.editedCount > 0 { parts.append("\(set.editedCount) edited") }
        if let model = set.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// The transcript versions of this video and what can be done with the
    /// one on show, beside the title.
    @ViewBuilder
    private var versionMenu: some View {
        if !transcriptionSets.isEmpty || missingTranscriptionPin {
            Menu {
                Section("Transcript Versions") {
                    Picker("Version", selection: $selectedTranscriptionKey) {
                        ForEach(transcriptionSets) { set in
                            Text("\(versionTitle(set)) — \(versionState(set)) · \(versionDetail(set))").tag(set.id)
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Divider()
                Button("Always Use This Version") { changePin(selectedTranscriptionKey) }
                    .disabled(selectedTranscriptionKey.isEmpty || pinnedTranscriptionKey == selectedTranscriptionKey)
                Button("Choose Automatically") { changePin(nil) }
                    .disabled(pinnedTranscriptionKey == nil)
                Button("Rename…") {
                    renameText = selectedSet?.name ?? ""
                    renamingSet = selectedSet
                }
                .disabled(selectedSet == nil)
                Button("Transcribe Again…") {
                    Task {
                        retranscribeEditCount = await store.transcriptEditCount(videoID: video.id)
                        retranscribeOptions = store.transcriptionTimingOptions(for: [video], force: true)
                        confirmRetranscribe = true
                    }
                }
                .disabled(!video.isPresent)
                Divider()
                Button("Delete This Version…", role: .destructive) { confirmDeleteSet = true }
                    .disabled(selectedTranscriptionKey.isEmpty || store.transcribingVideoIDs.contains(video.id))
                Button("Delete All \(transcriptionSets.count) Versions…", role: .destructive) { confirmDeleteAllSets = true }
                    .disabled(store.transcribingVideoIDs.contains(video.id))
            } label: {
                if let set = selectedSet {
                    Text("Version  \(versionTitle(set))  ·  \(versionState(set))").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Version").lineLimit(1)
                }
            }
            // A long version name is cut short rather than pushing Done out.
            .frame(maxWidth: 340)
            .fixedSize(horizontal: true, vertical: false)
            .focused($setsPickerFocused)
            .disabled(hasChanges || isSaving || editMode)
            .help(hasChanges || editMode ? "Apply or discard your changes to switch versions"
                  : missingTranscriptionPin ? "The pinned version is not on this Mac yet"
                  : "Switch transcript version, choose which one the app uses, rename, transcribe again or delete")
        }
    }

    /// Deletes the set shown (or, with nil, every transcript of the video).
    /// With nothing left there is nothing to edit, so the sheet closes.
    private func deleteSets(_ key: String?) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.deleteTranscriptSets(video: video, key: key)
                let remaining = (try? await store.database?.transcriptionSets(videoID: video.id)) ?? []
                if remaining.isEmpty { dismiss(); return }
                selectedTranscriptionKey = ""
                await load()
            } catch { store.presentError("Could not delete the transcript", error) }
        }
    }

    private func changePin(_ key: String?) {
        guard let database = store.database else { return }
        Task {
            do {
                try await database.setActiveTranscriptionKey(videoID: video.id, key: key)
                // Express shows the rows, picks and Highlights of the active set.
                await store.transcriptSetChanged(videoID: video.id)
                selectedTranscriptionKey = ""
                await load()
            } catch { store.presentError("Could not change the active transcript", error) }
        }
    }

    var body: some View {
        Group {
        if video.isPresent && (selectedTranscriptionKey.isEmpty || selectedTranscriptionKey == activeTranscriptionKey) {
            editableBody
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(video.filename).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Done") { dismiss() }.lineLimit(1).fixedSize()
                }
                versionMenu
                Label(video.isPresent ? "Saved transcription · Read-only" : "Not on this Mac · Read-only transcript", systemImage: "text.quote")
                    .foregroundStyle(.secondary)
                if !video.isPresent { MissingFootageDownloadButton(video: video) }
                List(rows) { row in
                    HStack(alignment: .top) {
                        Text(row.startTime.timecode).monospacedDigit()
                        Text(row.text).textSelection(.enabled)
                    }
                }
            }
            .padding().frame(minWidth: 600, minHeight: 400)
        }
        }
        .task(id: selectedTranscriptionKey) { await load() }
        .speakerColors(for: Set(speakerLabels.values))
        // The version menu's dialogs: here, because the read-only body shows the menu too.
        .confirmationDialog("Re-transcribe this video?", isPresented: $confirmRetranscribe) {
            // Always destructive here: confirming drops unsaved changes and closes the sheet.
            RetranscribeButtons(options: retranscribeOptions, destructive: true) { timing in
                store.transcribe(video: video, force: true, wordTiming: timing)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((retranscribeEditCount > 0
                 ? ConfirmTranscriptLoss.message(count: retranscribeEditCount)
                    + (hasChanges ? " Unsaved changes will be discarded." : "")
                 : "This makes a new transcript set, discards any unsaved changes, and closes this sheet. The previous set stays in the sets list.")
                 + (retranscribeOptions.count > 1 ? " " + TranscriptionModelChoiceDialog.message : ""))
        }
        .confirmationDialog("Delete this transcript?", isPresented: $confirmDeleteSet) {
            Button("Delete Transcript", role: .destructive) { deleteSets(selectedTranscriptionKey) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the selected transcript set with its edits, translations, speaker map and topics"
                 + (transcriptionSets.count > 1 ? "; the newest remaining set becomes active." : ". This video will have no transcript.")
                 + " Picks and clips already made from it stay. This cannot be undone.")
        }
        .confirmationDialog("Delete all transcripts of this video?", isPresented: $confirmDeleteAllSets) {
            Button("Delete All \(transcriptionSets.count) Transcripts", role: .destructive) { deleteSets(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every transcript set of this video with its edits, translations, speaker maps and topics, "
                 + "and closes this sheet. Picks and clips already made from them stay. This cannot be undone.")
        }
        .alert("Rename Transcript Version", isPresented: Binding(get: { renamingSet != nil }, set: { if !$0 { renamingSet = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let set = renamingSet else { return }
                let name = renameText
                Task {
                    await store.renameTranscriptSet(videoID: video.id, key: set.id, name: name)
                    transcriptionSets = (try? await store.database?.transcriptionSets(videoID: video.id)) ?? transcriptionSets
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave the name empty to show the date it was made.")
        }
    }

    private var editableBody: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal).padding(.top, 14).padding(.bottom, 10)
            Divider()
            Group {
                if editMode || hasChanges { editBar } else { toolbar }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(editMode || hasChanges ? Color.orange.opacity(0.12) : Color.clear)
            notices
            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsQA, !qaSections.isEmpty {
                TranscriptQAView(video: video, sections: qaSections, rows: rows, labels: qaLabels,
                                 preferredTranslationLanguage: store.activeProfile.captionLanguages.first) { scene, start, end in
                    store.setSceneEditRange(scene, start: start, end: end)
                }
            } else if showsTopics, !topics.isEmpty {
                topicsView
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
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let visible = visibleRows
                            let current = currentRowID
                            let blockEnds = groupBySpeaker
                                ? Self.blockEnds(visible) { speakerLabel($0) == speakerLabel($1) && $0.isTranslation == $1.isTranslation }
                                : []
                            let exchangeSpans = groupBySpeaker
                                ? Self.exchangeSpans(visible) { exchangeScene($0)?.id }
                                : [:]
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                                // Tags print where the line enters a
                                // different scene, so a run of lines in one
                                // exchange reads as one block under its tags.
                                let previous = index > 0 ? sceneIDs(visible[index - 1]) : nil
                                let sameSpeaker = index > 0 && speakerLabel(visible[index - 1]) == speakerLabel(row)
                                    && visible[index - 1].isTranslation == row.isTranslation
                                let grouped = groupBySpeaker && speakerLabel(row) != nil
                                VStack(alignment: .leading, spacing: 0) {
                                    segmentRow(row, showTags: index == 0 || previous != sceneIDs(row),
                                               current: current == row.id, repeatedSpeaker: sameSpeaker,
                                               grouped: grouped, blockEnd: grouped && !sameSpeaker ? blockEnds[index] : nil)
                                    if !(grouped && index + 1 < visible.count
                                         && speakerLabel(visible[index + 1]) == speakerLabel(row)
                                         && visible[index + 1].isTranslation == row.isTranslation) {
                                        Divider()
                                    }
                                }
                                // Include the padding and divider so the bracket has no gaps.
                                .overlay(alignment: .leading) {
                                    if let edge = exchangeSpans[index] {
                                        let bracket = ExchangeBracket(edge: edge)
                                            .frame(width: 18)
                                            .frame(maxHeight: .infinity)
                                            .contentShape(Rectangle())
                                        if (edge == .first || edge == .only), let scene = exchangeScene(row) {
                                            bracket.help("Q&A exchange \(scene.startTime.timecode)–\(scene.endTime.timecode)")
                                        } else {
                                            bracket
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target, anchor: .top)
                        scrollTarget = nil
                    }
                    .onAppear {
                        // A topic picked in the Topics view lands here.
                        if let target = scrollTarget {
                            proxy.scrollTo(target, anchor: .top)
                            scrollTarget = nil
                        }
                    }
                    }
                    Divider()
                    videoPanel
                        .frame(width: 400)
                }
            }

        }
        .frame(minWidth: 900, idealWidth: 1320, maxWidth: .infinity,
               minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .modalCloseButton {
            if hasChanges { confirmDiscard = true } else { dismiss() }
        }
        .onChange(of: mappingJob?.status) { _, status in
            if status == .done { Task { await refreshSpeakerMapping() } }
        }
        .onChange(of: translationJob?.status) { _, status in
            if status == .done { Task { await load() } }
        }
        // Q&A has its own player and Topics has none: nothing keeps
        // playing behind either.
        .onChange(of: showsLines) { _, lines in
            if !lines { stopPlayback(releasePlayer: true) }
        }
        .onChange(of: currentVideoScenes) { _, scenes in
            refreshSceneMapping(scenes)
        }
        .onChange(of: store.analysisRunsVersion) { _, _ in
            Task { await load() }
        }
        .appJobSetupPresentation()
        .onDisappear { stopPlayback(releasePlayer: true) }
        .sheet(isPresented: $showTools, onDismiss: { Task { await loadAnalysis() } }) { CleanupCutsSheet(video: video) }
        .onChange(of: analysisJob?.status) { _, status in
            if status != .running { Task { await loadAnalysis() } }
        }
        .confirmationDialog("Undo re-cut?", isPresented: $confirmUndoRecut) {
            Button("Undo Re-cut", role: .destructive) { undoRecut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Undoing the re-cut throws away \(undoRecutEditCount) edited lines. Undo anyway?")
        }
        .confirmationDialog("Revert all transcript edits?", isPresented: $confirmRevertAll) {
            Button("Revert All Edits", role: .destructive) { revertAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Put the transcriber's text back on \(editedCount) lines? Their word timings and any translations and topics derived from the edits are refreshed too.")
        }
        .confirmationDialog("Discard unsaved transcript changes?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Apply and Close") { save(thenDismiss: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(changeSummary + " not applied yet.")
        }
    }

    private var qaLabels: [Int64: String] {
        rows.reduce(into: [:]) { result, row in result[row.id] = speakerLabel(row) }
    }

    private var qaSections: [TranscriptQASections.Section] {
        TranscriptQASections.sections(scenes: videoScenes, rows: rows, labels: qaLabels)
    }

    /// What this is, which version, and the way out.
    private var titleBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Transcript")
                Text(video.filename)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(video.filename)
            }
            .layoutPriority(-1)
            AIInfoButton(video: video)
            versionMenu
            Text(editMode || hasChanges ? "Apply or discard your changes to switch versions."
                 : titleSummary)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(editMode || hasChanges ? "" : titleSummary)
                .layoutPriority(-2)
            Spacer(minLength: 8)
            if editMode || hasChanges {
                Button("Done") { dismiss() }
                    .lineLimit(1).fixedSize()
                    .disabled(true)
                    .help("Apply or discard your changes first")
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .lineLimit(1).fixedSize()
                    .disabled(isSaving)
            }
        }
    }

    private var titleSummary: String {
        guard !rows.isEmpty else { return "" }
        let lines = rows.count { !$0.isTranslation }
        let shown = visibleRows.count
        var parts = [showsQA || tagFilter.isEmpty ? "\(lines) lines" : "\(shown) of \(lines) lines"]
        parts.append(languages.map { DubLanguageChoices.name($0.code) }.joined(separator: " + "))
        if editedCount > 0 { parts.append("\(editedCount) edited") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One row: what is on show at the left, what can be done at the right.
    /// When the sheet is too narrow for every title, the actions keep their
    /// icons and say what they are in their tooltips.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbar(compact: false)
            toolbar(compact: true)
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("View", selection: viewChoice) {
                Text("Lines").tag(0)
                if !qaSections.isEmpty { Text("Q&A \(qaSections.count)").tag(1) }
                if !topics.isEmpty { Text("Topics \(topics.count)").tag(2) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if showsLines {
                Divider().frame(height: 18)
                showMenu
                languageControls(allowAdd: true)
                groupToggle(compact: compact)
            }
            Spacer(minLength: 8)
            speakerActions(compact: compact)
            Button {
                showTools = true
            } label: {
                HStack(spacing: 5) {
                    Label("Cleanup Cuts", systemImage: "scissors").modifier(CompactLabel(compact: compact))
                    if pendingCuts > 0 {
                        Text(pendingCuts.formatted()).fontWeight(.semibold).foregroundStyle(.orange).monospacedDigit()
                    }
                }
                .lineLimit(1)
            }
            .fixedSize()
            .disabled(rows.isEmpty)
            .accessibilityLabel("Cleanup Cuts")
            .help(pendingCuts > 0
                  ? "Cleanup Cuts: \(pendingCuts) pause, filler and repeat cut\(pendingCuts == 1 ? "" : "s") waiting for a decision"
                  : "Cleanup Cuts: decide which pauses, filler words, repeats and false starts are cut from this video")
            Menu {
                Menu("Export Captions (SRT)") {
                    ForEach(languages, id: \.self) { language in
                        Button(DubLanguageChoices.name(language.code) + (language.isTranslation ? "" : " (spoken)") + "…") {
                            exportSRT(language)
                        }
                    }
                }
                .disabled(rows.isEmpty)
                Button(analysisJob?.status == .running ? "Finding Topics & Cuts…" : "Find Topics & Cuts Again") {
                    store.startTranscriptAnalysis(video: video)
                }
                .disabled(rows.isEmpty || analysisJob?.status == .running || hasChanges || isSaving)
                Divider()
                Button("Revert All Edits… (\(editedCount))") { confirmRevertAll = true }
                    .disabled(editedCount == 0 || hasChanges || isSaving)
            } label: {
                Label("Tools", systemImage: "ellipsis.circle").modifier(CompactLabel(compact: compact, full: .titleOnly))
            }
            .fixedSize()
            .help("Tools: export this transcript's captions, look for topics and cleanup cuts again, or put every edited line back")
            if showsLines {
                Button("Edit Text", systemImage: "pencil") { editMode = true }
                    .modifier(CompactLabel(compact: compact))
                    .lineLimit(1).fixedSize()
                    .disabled(isSaving || rows.isEmpty || isMappingSpeakers)
                    .help(isMappingSpeakers ? "Wait for Fix Speakers to finish; it replaces the lines"
                          : "Edit Text: correct lines and their translations; nothing is saved until you apply")
            }
        }
        .lineLimit(1)
    }

    /// The toolbar's place while text is being edited or a change waits:
    /// what changed, and the only way out (apply or discard).
    private var editBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").foregroundStyle(Color.orange).accessibilityHidden(true)
            Text(editMode ? "Editing text" : "Changes not applied").fontWeight(.semibold).fixedSize()
            Text(hasChanges ? changeSummary : "Type in a line or a translation.")
                .foregroundStyle(.secondary).truncationMode(.tail)
                .help(hasChanges ? changeSummary : "")
                .layoutPriority(-1)
            if !showsQA {
                Divider().frame(height: 18)
                languageControls(allowAdd: false)
                Toggle("Show what changed", isOn: $compareMode)
                    .toggleStyle(.checkbox).fixedSize()
                    .disabled(!canCompare)
                    .help("Show each changed line's earlier text under it")
            }
            Spacer(minLength: 8)
            Button(hasChanges ? "Discard Changes" : "Stop Editing") {
                drafts = [:]
                speakerDrafts = [:]
                editMode = false
            }
            .lineLimit(1).fixedSize()
            .disabled(isSaving)
            Button(applyTitle) { save(thenDismiss: false) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .lineLimit(1).fixedSize()
                .disabled(!hasChanges || isSaving)
                .help("Save every changed line, translation and speaker at once")
        }
        .lineLimit(1)
    }

    private var applyTitle: String {
        let count = changedIDs.count + changedSpeakerIDs.count
        return count == 0 ? "Apply" : "Apply \(count) Change\(count == 1 ? "" : "s")"
    }

    /// Coverage and speaker-map messages, under the toolbar only while there is one.
    @ViewBuilder
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverageControls
            statusStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .lineLimit(1)
    }

    @ViewBuilder
    private var coverageControls: some View {
        if currentVideo.type == nil {
            HStack(spacing: 8) {
                Text("Podcast exchanges run only for videos typed Podcast or Interview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                VideoTypePicker(video: currentVideo)
                    .disabled(store.isAnalyzing)
            }
        } else if qaSections.isEmpty && currentVideo.type?.usesPodcastPass == true {
            HStack(spacing: 8) {
                Text(AnalysisCoverage.message(for: coverage, type: currentVideo.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(AnalysisCoverage.message(for: coverage, type: currentVideo.type))
                Button("Run exchanges") { store.rerun(.exchanges, video: currentVideo) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(store.isAnalyzing || isLoading || isSaving || hasChanges || !currentVideo.isPresent)
                    .help(hasChanges ? "Apply transcript edits before running exchanges" : "Run podcast exchanges to add the Q&A view")
            }
        }
    }

    private var showLabel: String {
        tagFilter.isEmpty ? "All lines"
            : tagFilter == Self.changedByMapFilter ? "Changed by Fix Speakers"
            : tagFilter == Self.editedFilter ? "Edited (\(editedCount))"
            : tagFilter == "reel-highlight" ? "Reel" : tagFilter
    }

    private var showMenu: some View {
        Menu("Show  \(showLabel)") {
            Button("All lines") { tagFilter = "" }
            Button("Edited (\(editedCount))") { tagFilter = Self.editedFilter }
                .disabled(editedCount == 0)
            Divider()
            ForEach(allLineTags, id: \.self) { tag in
                let count = rows.count { lineTags[$0.id]?.contains(tag) == true }
                Button("\(tag == "reel-highlight" ? "Reel" : tag) (\(count))") { tagFilter = tag }
            }
            if !changedByMap.isEmpty {
                Divider()
                Button("Changed by Fix Speakers (\(changedByMap.count))") { tagFilter = Self.changedByMapFilter }
            }
        }
        .lineLimit(1).fixedSize()
        .help("Show every line, only edited lines, lines carrying a tag, or lines the last speaker map changed")
    }

    @ViewBuilder
    private func groupToggle(compact: Bool) -> some View {
        if rows.contains(where: { speakerLabels[$0.id] != nil }) {
            Toggle(compact ? "Group" : "Group by speaker", isOn: $groupBySpeaker)
                .toggleStyle(.checkbox)
                .lineLimit(1).fixedSize()
                .accessibilityLabel("Group by speaker")
                .help("Group by speaker: read each speaker's uninterrupted run as one block with one play button; turn it off to play, time or re-attribute single lines")
        }
    }

    /// One control for the whole speaker repair: the button maps who is
    /// talking again (which also splits rows where the speaker changes);
    /// the arrow holds the single steps and their undos.
    @ViewBuilder
    private func speakerActions(compact: Bool) -> some View {
        if !turns.isEmpty {
            let busy = hasChanges || editMode || isSaving || isMappingSpeakers
            Menu {
                Button("Split Lines by Speaker Only") { recut() }
                if store.previousSpeakerMaps[video.id] != nil || hasRecut { Divider() }
                if store.previousSpeakerMaps[video.id] != nil {
                    Button("Put the Previous Speakers Back") { undoMap() }
                }
                if hasRecut {
                    Button("Put the Transcriber's Lines Back") { requestUndoRecut() }
                }
            } label: {
                Label(isMappingSpeakers ? "Fixing Speakers…" : "Fix Speakers", systemImage: "person.wave.2")
                    .modifier(CompactLabel(compact: compact))
                    .lineLimit(1)
            } primaryAction: {
                fixSpeakers()
            }
            .fixedSize()
            .disabled(busy)
            .help(hasChanges || editMode ? "Apply or discard your text changes first"
                  : isMappingSpeakers ? "Working out who is talking…"
                  : "Fix Speakers: work out who is talking again from the picture and the voices, then split every line where the speaker changes so each line has one speaker. Lines you attributed by hand are kept and teach it their voices; lines whose text you edited are never split. The arrow has the split-only step and the ways back: the previous speakers (voices it learned stay learned) and the transcriber's own lines.")
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if isMappingSpeakers {
            let message = mappingJob?.status == .running ? (mappingStatus ?? "Fixing speakers…") : "Stopping…"
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(message).foregroundStyle(.secondary)
                    .truncationMode(.tail).help(message)
                    .fixedSize(horizontal: false, vertical: true)
                if let mappingJob, mappingJob.status == .running {
                    Button("Stop") { store.jobs.cancel(mappingJob.id) }
                        .fixedSize().help("Stop fixing speakers")
                }
            }
            .font(.caption).lineLimit(1)
        } else if unlearnedCorrections > 0, !turns.isEmpty {
            let pending = unlearnedCorrections
            let message = "\(pending) line\(pending == 1 ? "" : "s") attributed by hand — Fix Speakers to teach the tracker \(pending == 1 ? "that voice" : "those voices") and fix the rest of this file"
            HStack(spacing: 8) {
                Label(message, systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(Color.orange).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message + ". The speaker map still disagrees with these lines. Fix Speakers uses your attributions as ground truth, remaps every other line, splits lines where the speaker changes, and remembers the voices for other files.")
                Button("Fix Speakers") { fixSpeakers() }
                    .disabled(hasChanges || isSaving || isMappingSpeakers)
                    .controlSize(.small).fixedSize()
                    .help("Rerun who-is-talking with your attributions as ground truth")
            }
            .font(.caption).lineLimit(1)
        } else if let recutNote {
            Text(recutNote).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).help(recutNote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line: play, then who / when / tags and the line's state, then
    /// the text column, which holds text only (the spoken line and its
    /// translations, each behind its language code).
    private func segmentRow(_ row: TranscriptRow, showTags: Bool, current: Bool, repeatedSpeaker: Bool,
                            grouped: Bool = false, blockEnd: Double? = nil) -> some View {
        let playing = self.playing?.rowID == row.id
        // Grouped: only the block's first line carries playback, time
        // and speaker controls; empty columns keep the rest aligned.
        let continuation = grouped && repeatedSpeaker
        let end = grouped ? (blockEnd ?? row.endTime) : row.endTime
        let translations = (translationsByRow[row.id] ?? []).filter(shows)
        let changed = isChanged(row) || (translationsByRow[row.id] ?? []).contains(where: isChanged)
        return HStack(alignment: .top, spacing: 12) {
            if continuation {
                Spacer(minLength: 0).frame(width: 22)
            } else {
                Button {
                    Task { await togglePlayback(row, end: grouped ? end : nil) }
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(playing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .disabled(playbackUnavailable)
                .help(playbackUnavailable ? "The video is not on this Mac — download it from the Drive menu to watch it"
                      : playing ? "Stop"
                      : grouped ? "Watch this speaker's run (\(row.startTime.timecode)–\(end.timecode)) in the panel on the right"
                      : "Watch this line in the panel on the right")
                .accessibilityLabel(playing ? "Stop"
                                    : grouped ? "Play \(speakerLabel(row) ?? "speaker") from \(row.startTime.timecode) to \(end.timecode)"
                                    : "Play line at \(row.startTime.timecode)")
            }

            VStack(alignment: .leading, spacing: 5) {
                if !continuation {
                    speakerMenu(row, compact: repeatedSpeaker)
                    Text("\(row.startTime.timecode)–\(end.timecode)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if showTags, let tags = lineTags[row.id], !tags.isEmpty {
                    tagLine(row, tags: tags)
                }
                if changed {
                    Text("Changed, not applied")
                        .font(.caption).foregroundStyle(Color.orange).lineLimit(1)
                    Button("Undo line") {
                        drafts[row.id] = nil
                        for translation in translationsByRow[row.id] ?? [] { drafts[translation.id] = nil }
                    }
                    .controlSize(.mini).lineLimit(1).fixedSize()
                    .disabled(isSaving)
                    .help("Drop what you typed in this line and its translations")
                } else if row.originalText != nil {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text("Edited").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use transcriber's text") { revert(row) }
                        .controlSize(.mini).lineLimit(1).fixedSize()
                        .disabled(isSaving || hasChanges)
                        .help("Restore the transcriber's original text for this line")
                }
                ForEach(translations.filter { $0.originalText != nil && !isChanged($0) }) { translation in
                    Button(translations.count > 1 ? "Use machine \(languageCode(translation))" : "Use machine text") { revert(translation) }
                        .controlSize(.mini).lineLimit(1).fixedSize()
                        .disabled(isSaving || hasChanges)
                        .help("Replace your \(DubLanguageChoices.name(translation.language)) wording with the machine translation")
                }
            }
            .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if shows(row) {
                    textLine(code: languageCode(row)) { originalText(row) }
                }
                ForEach(translations) { translation in
                    textLine(code: languageCode(translation)) { translationText(translation, of: row) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.leading, groupBySpeaker ? 18 : 0)
        .padding(.top, continuation ? 1 : 10)
        .padding(.bottom, grouped ? 2 : 10)
        .background(current ? Color.accentColor.opacity(0.16) : changed ? Color.orange.opacity(0.07) : Color.clear)
        .overlay(alignment: .leading) {
            if current || changed {
                Rectangle().fill(current ? Color.accentColor : Color.orange).frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    private func isChanged(_ row: TranscriptRow) -> Bool { (drafts[row.id] ?? row.text) != row.text }

    private func languageCode(_ row: TranscriptRow) -> String {
        ProjectLanguageResolver.languageCode(row.language).uppercased()
    }

    /// The language code in its own narrow column, so every text starts at one edge.
    private func textLine(code: String, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(code)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
                .accessibilityLabel(DubLanguageChoices.name(code.lowercased()))
            VStack(alignment: .leading, spacing: 4) { text() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editField(_ row: TranscriptRow, prompt: String) -> some View {
        TextField(prompt, text: Binding(
            get: { drafts[row.id] ?? row.text },
            set: { drafts[row.id] = $0 }
        ), axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...8)
        .disabled(isSaving)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func originalText(_ row: TranscriptRow) -> some View {
        if editMode {
            editField(row, prompt: "Line text").font(.body)
        } else if compareMode && isCompared(row) {
            Text(comparedText(row, original: false)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(drafts[row.id] ?? row.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if compareMode && isCompared(row) {
            Text(AttributedString("Was: ") + comparedText(row, original: true))
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Transcriber's original: \(row.originalText ?? row.text)")
        }
    }

    /// A line's translation: editable with Edit Text like the line itself.
    @ViewBuilder
    private func translationText(_ row: TranscriptRow, of original: TranscriptRow) -> some View {
        if editMode {
            editField(row, prompt: "\(DubLanguageChoices.name(row.language)) translation")
            if row.originalText != nil || isChanged(row) {
                Label("Your wording. Kept when the \(DubLanguageChoices.name(original.language)) changes.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isChanged(original) {
                Text("Will be re-translated from the new text when you apply. Type in it to keep your own wording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(drafts[row.id] ?? row.text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isCompared(_ row: TranscriptRow) -> Bool {
        !row.isTranslation && (row.originalText != nil || (drafts[row.id] ?? row.text) != row.text)
    }

    private func comparedText(_ row: TranscriptRow, original: Bool) -> AttributedString {
        let tokens = TranscriptTextDiff.diff(original: row.originalText ?? row.text, edited: drafts[row.id] ?? row.text)
        var result = AttributedString()
        for token in tokens where original ? token.kind != .inserted : token.kind != .deleted {
            if !result.characters.isEmpty { result += AttributedString(" ") }
            var part = AttributedString(token.text)
            if token.kind == .deleted {
                part.foregroundColor = .red.opacity(0.75)
                part.strikethroughStyle = .single
            } else if token.kind == .inserted {
                part.foregroundColor = .accentColor
            }
            result += part
        }
        return result
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius))
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
                    PlaybackSpeedControl(rate: $speed)
                        .onChange(of: speed) { _, speed in player?.setReviewSpeed(speed) }
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

    /// Who says the line being played: one choice per person of this video
    /// plus nobody known. The marked one is the current attribution;
    /// choosing another stages a change for Apply.
    private func whoIsTalking(_ row: TranscriptRow) -> some View {
        let guess = bestTurn(for: row)
        let attribution = speakerDrafts[row.id] ?? row.speaker
        let checkedKey = attributedKey(row)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("Who says this line")
                Spacer()
                if attribution != .automatic {
                    Button("Use Detected") { attribute([row], .automatic) }
                        .controlSize(.mini).lineLimit(1).fixedSize()
                        .help("Go back to the speaker the app detected")
                }
            }
            if guess == nil {
                Text("No speaker detected under this line.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if guess?.personKey == nil {
                Text("A voice was detected that matches nobody yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(roster) { entry in
                speakerChoice(selected: checkedKey == entry.key,
                              detected: guess?.personKey == entry.key,
                              help: "This person says the line — the blue frame shows their feed") {
                    attribute([row], .person(key: entry.key))
                } label: {
                    VideoPersonAvatar(record: entry, videoURL: video.url, size: 22)
                    Text(entry.displayName).font(.callout).lineLimit(1)
                }
            }
            speakerChoice(selected: attribution == .unknown, detected: false,
                          help: "Nobody the app knows says this line") {
                attribute([row], .unknown)
            } label: {
                Text("Nobody known").font(.callout).lineLimit(1)
            }
            Text("Correcting a few lines teaches the speaker map. Fix Speakers applies it everywhere.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func speakerChoice(selected: Bool, detected: Bool, help: String, action: @escaping () -> Void,
                               @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                label()
                Spacer(minLength: 4)
                if detected {
                    Text("detected").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    /// carrying the tag. Whole chips wrap onto new rows; an HStack squeezed
    /// every chip until its label broke letter by letter.
    private func tagLine(_ row: TranscriptRow, tags: [String]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                let scene = lineScenes[row.id]?.first { $0.tags.contains(tag) }
                Button {
                    guard let scene else { return }
                    Task {
                        await play(start: scene.startTime, end: scene.endTime,
                                   label: "Scene tagged \(tag == "reel-highlight" ? "Reel" : tag)", rowID: nil)
                    }
                } label: {
                    TagChip(tag: tag).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 146, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(scene == nil)
                .help(scene.map { "Watch the scene tagged \(tag) (\($0.startTime.timecode)–\($0.endTime.timecode)) in the panel" } ?? tag)
            }
        }
    }

    // MARK: - Views, topics and caption export

    /// Lines, Q&A or Topics, as one segmented choice over the two flags.
    private var viewChoice: Binding<Int> {
        Binding(get: { showsQA ? 1 : showsTopics && !topics.isEmpty ? 2 : 0 },
                set: { choice in
                    showsQA = choice == 1
                    showsTopics = choice == 2
                })
    }

    /// The topics the analysis found: pick one to read its lines.
    private var topicsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(topics) { topic in
                    Button {
                        showTopic(topic)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(topic.startTime.timecode)–\(topic.endTime.timecode)")
                                Text(Self.topicLength(topic.duration)).foregroundStyle(.tertiary)
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(topic.title).fontWeight(.semibold).lineLimit(1)
                                if !topic.summary.isEmpty {
                                    Text(topic.summary).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal).padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the lines of this topic")
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func topicLength(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(seconds.timecode) min"
    }

    /// Back to Lines, at the first line of the topic, with every line on show.
    private func showTopic(_ topic: TopicRange) {
        tagFilter = ""
        let spoken = rows.filter { !$0.isTranslation }
        scrollTarget = (spoken.first { $0.endTime > topic.startTime } ?? spoken.last)?.id
        showsTopics = false
    }

    /// Topics and the count of undecided cuts. Both belong to the
    /// transcript in use, so another version on show has neither.
    private func loadAnalysis() async {
        guard let database = store.database else { return }
        let inUse = selectedTranscriptionKey.isEmpty || selectedTranscriptionKey == activeTranscriptionKey
        let loadedTopics = inUse ? ((try? await database.fetchTopicRanges(videoID: video.id)) ?? []) : []
        let proposals = (try? await database.fetchEditProposals(videoID: video.id)) ?? []
        guard !Task.isCancelled else { return }
        topics = loadedTopics
        pendingCuts = CleanupCutReview.summary(CleanupCutReview.cuts(proposals)).pending
        if topics.isEmpty { showsTopics = false }
    }

    private func exportSRT(_ language: TranscriptTranslationRows.Language) {
        let lines = rows.filter { $0.isTranslation == language.isTranslation && $0.language == language.code }
        guard !lines.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(video.url.deletingPathExtension().lastPathComponent)-\(language.code).srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubRipExport.document(lines).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.presentError("Could not export SRT", error)
        }
    }

    // MARK: - Re-cut by speaker

    private func recut() {
        Task {
            guard let split = await store.recutTranscriptBySpeaker(videoID: video.id) else { return }
            recutNote = split == 0 ? "No lines were split. Lines whose text you edited are left whole."
                : "\(split) row\(split == 1 ? "" : "s") split where the speaker changed."
            await load()
        }
    }

    private func requestUndoRecut() {
        guard let database = store.database else { return }
        Task {
            do {
                let current = try await database.fetchTranscripts(videoID: video.id)
                guard let backup = try await database.transcriptBackup(videoID: video.id) else { return }
                if TranscriptSpeakerRecut.hasEdits(current, beyond: backup) {
                    undoRecutEditCount = TranscriptSpeakerRecut.editedCount(current, beyond: backup)
                    confirmUndoRecut = true
                } else {
                    undoRecut()
                }
            } catch { store.presentError("Could not check the re-cut backup", error) }
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

    /// Map who is talking again; the job re-cuts the rows by the new turns.
    private func fixSpeakers() {
        store.startSpeakerMapping(video: video)
    }

    private func refreshSpeakerMapping() async {
        await load()
        guard mappingJob?.status == .done else { return }
        let changed = changedByMap.count
        recutNote = changed == 0 ? "Speakers fixed — no line changed speaker."
            : "Speakers fixed — \(changed) line\(changed == 1 ? "" : "s") changed speaker. Show ▸ Changed by Fix Speakers lists them."
    }

    /// A log line as the header shows it: the filename prefix dropped.
    nonisolated static func statusLine(_ line: String) -> String {
        if let colon = line.firstIndex(of: ":"), line[..<colon].contains(".") {
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private func undoMap() {
        Task {
            if await store.undoSpeakerMap(video: video) {
                recutNote = "The previous speakers are back. Voices learned since stay learned."
                await load()
            }
        }
    }

    // MARK: - Playback

    /// Play the line or speaker block in the panel, or stop it when it is the one playing.
    private func togglePlayback(_ row: TranscriptRow, end: Double? = nil) async {
        if playing?.rowID == row.id {
            stopPlayback(releasePlayer: false)
            return
        }
        let who = speakerLabel(row).map { "\($0) · " } ?? ""
        let range = end.map { "\(row.startTime.timecode)–\($0.timecode)" } ?? "line at \(row.startTime.timecode)"
        await play(start: row.startTime, end: end ?? row.endTime, label: who + range, rowID: row.id)
    }

    /// Seek the panel's player to a range and play it; a boundary observer
    /// stops it at `end` (nil plays on to the end of the file).
    private func play(start: Double, end: Double?, label: String, rowID: Int64?) async {
        playToken &+= 1
        let token = playToken
        guard let player = await preparedPlayer(), token == playToken else { return }
        stopPlayback(releasePlayer: false)
        await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        // A newer request or a closed sheet wins.
        guard token == playToken, player === self.player else { return }
        // A pending preview must not start behind the Q&A player.
        guard showsLines else { stopPlayback(releasePlayer: true); return }
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
        // Two clicks while the file opens share one player; a second player
        // would own observers the first one's cleanup then removes.
        if let preparing { return await preparing.value }
        let epoch = playerEpoch
        let url = video.url
        let task = Task<AVPlayer?, Never> { @MainActor in
            guard await DrivePlayback.prepare(url),
                  let asset = try? await DriveLocalAsset.make(url) else {
                if epoch == playerEpoch { playbackUnavailable = true }
                return nil
            }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.setReviewSpeed(speed)
            for _ in 0..<100 where item.status != .readyToPlay {
                if item.status == .failed {
                    if epoch == playerEpoch { playbackUnavailable = true }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The sheet closed while the file opened.
            guard epoch == playerEpoch else { return nil }
            // A line that runs to the end of the file stops with the file.
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
                Task { @MainActor in stopPlayback(releasePlayer: false) }
            }
            self.player = player
            return player
        }
        preparing = task
        let player = await task.value
        if epoch == playerEpoch { preparing = nil }
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
            preparing = nil
            playerEpoch &+= 1
            playToken &+= 1
        }
    }

    /// The speaker column: who says the line, and a menu to say otherwise —
    /// a person of this video, anyone else in the library, or Unknown; the
    /// same choices for every line that reads as this speaker; and back to
    /// automatic once overridden. Attribution saves at once, like Revert.
    private func speakerMenu(_ row: TranscriptRow, compact: Bool = false) -> some View {
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
            // The name shows once per run; the lines after it keep a small
            // handle so any single line can still be given to someone else.
            if compact, !pending, changedByMap[row.id] == nil {
                Image(systemName: overridden ? "person.fill.checkmark" : "person")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    let color = pending ? Color.orange : label.map { SpeakerColors.color(for: $0) } ?? Color.gray
                    HStack(spacing: 4) {
                        if overridden {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).accessibilityHidden(true)
                        }
                        Text(label ?? "Speaker?")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(color.opacity(0.18), in: Capsule())
                    if let before = changedByMap[row.id], before != label {
                        // What the previous map said, for judging the change.
                        Text(before)
                            .font(.caption2)
                            .strikethrough()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("The previous speaker map said \(before)")
                    }
                }
            }
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
        let selected = selectedTranscriptionKey
        let resolution = try? await database.activeTranscription(videoID: video.id)
        let key: String? = selected.isEmpty ? resolution?.key : selected
        let sets = (try? await database.transcriptionSets(videoID: video.id)) ?? []
        let loadedRows = (try? await database.fetchTranscripts(videoID: video.id, transcriptionKey: key)) ?? []
        let loadedTurns = (try? await database.fetchSpeakerTurns(videoID: video.id, transcriptionKey: key)) ?? []
        let loadedRoster = await store.videoPeople(for: video.id)
        guard !Task.isCancelled, selected == selectedTranscriptionKey else { return }
        activeTranscriptionKey = resolution?.key
        missingTranscriptionPin = resolution?.missingPin ?? false
        pinnedTranscriptionKey = (try? await database.video(id: video.id))?.activeTranscriptionKey
        transcriptionSets = sets
        if selected.isEmpty, let key {
            selectedTranscriptionKey = key
            return
        }
        if focusSetsPicker { setsPickerFocused = true }
        rows = loadedRows
        translationsByRow = TranscriptTranslationRows.attached(loadedRows)
        // Another set may have fewer languages: one always stays on show.
        let loadedLanguages = TranscriptTranslationRows.languages(loadedRows)
        hiddenLanguages.formIntersection(loadedLanguages)
        if hiddenLanguages.count >= loadedLanguages.count { hiddenLanguages = [] }
        turns = loadedTurns
        roster = loadedRoster
        let people = store.people
        // Labels read the roster-named turns; the correction logic below keeps the raw map.
        let namedTurns = TranscriptSpeakers.named(turns, roster: roster)
        speakerLabels = rows.reduce(into: [:]) { labels, row in
            labels[row.id] = TranscriptSpeakers.label(for: row, turns: namedTurns, roster: roster, people: people)
        }
        unlearnedCorrections = TranscriptSpeakers.unlearnedCorrections(rows: rows, turns: turns)
        changedByMap = TranscriptSpeakers.changedLabels(rows: rows, before: store.previousSpeakerMaps[video.id] ?? [],
                                                        after: turns, roster: roster, people: people)
        if tagFilter == Self.changedByMapFilter, changedByMap.isEmpty { tagFilter = "" }
        if tagFilter == Self.editedFilter, editedCount == 0 { tagFilter = "" }
        hasRecut = await store.hasTranscriptRecut(videoID: video.id)
        await loadAnalysis()
        refreshSceneMapping(currentVideoScenes)
        isLoading = false
    }

    private var currentVideoScenes: [SceneRecord] {
        store.scenes.filter { $0.videoID == video.id && !$0.ignored }
    }

    private func refreshSceneMapping(_ scenes: [SceneRecord]) {
        videoScenes = scenes
        lineScenes = rows.reduce(into: [:]) { result, row in
            let covering = Self.scenes(covering: row, in: scenes)
            if !covering.isEmpty { result[row.id] = covering }
        }
        lineTags = lineScenes.mapValues { Self.lineTags($0.flatMap(\.tags)) }
        if !scenes.contains(where: { $0.tags.contains("q&a") }) { showsQA = false }
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
                if !changes.isEmpty {
                    try await database.updateTranscriptTexts(changes)
                    await store.transcriptTextsChanged(videoID: video.id, transcriptionKey: editedSetKey,
                                                       rowIDs: changes.map(\.id))
                }
                for (speaker, ids) in speakerChanges {
                    await store.setTranscriptSpeaker(rowIDs: ids, videoID: video.id, speaker: speaker)
                }
                drafts = [:]
                speakerDrafts = [:]
                editMode = false
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
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await database.revertTranscriptText(id: row.id)
                drafts[row.id] = nil
                await store.transcriptTextsChanged(videoID: video.id, transcriptionKey: editedSetKey, rowIDs: [row.id])
                await load()
            } catch { store.presentError("Could not revert the transcript line", error) }
        }
    }

    /// The set on show, as the database wants it: nil means the active set.
    private var editedSetKey: String? { selectedTranscriptionKey.isEmpty ? nil : selectedTranscriptionKey }

    private func revertAll() {
        guard let database = store.database else { return }
        let ids = rows.filter { !$0.isTranslation && $0.originalText != nil }.map(\.id)
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await database.revertTranscriptTexts(videoID: video.id, transcriptionKey: editedSetKey)
                await store.transcriptTextsChanged(videoID: video.id, transcriptionKey: editedSetKey, rowIDs: ids)
                await load()
            } catch { store.presentError("Could not revert transcript edits", error) }
        }
    }

}

nonisolated enum ExchangeEdge: Equatable, Sendable {
    case only, first, middle, last
}

private struct ExchangeBracket: View {
    var edge: ExchangeEdge

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let x: CGFloat = 6
                let top = edge == .first || edge == .only
                let bottom = edge == .last || edge == .only
                let startY = top ? 1.5 : 0
                let endY = geometry.size.height - (bottom ? 1.5 : 0)
                path.move(to: CGPoint(x: x, y: startY))
                path.addLine(to: CGPoint(x: x, y: endY))
                if top {
                    path.move(to: CGPoint(x: x + 8, y: startY))
                    path.addLine(to: CGPoint(x: x, y: startY))
                }
                if bottom {
                    path.move(to: CGPoint(x: x + 8, y: endY))
                    path.addLine(to: CGPoint(x: x, y: endY))
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A toolbar label that drops its title when the bar is short of room.
private struct CompactLabel: ViewModifier {
    enum Full { case titleAndIcon, titleOnly }

    let compact: Bool
    var full = Full.titleAndIcon

    func body(content: Content) -> some View {
        if compact {
            content.labelStyle(.iconOnly)
        } else if full == .titleOnly {
            content.labelStyle(.titleOnly)
        } else {
            content.labelStyle(.titleAndIcon)
        }
    }
}
