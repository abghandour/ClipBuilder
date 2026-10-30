import SwiftUI

/// The card's left and middle columns share only explicit selection state.
struct MiniBRollPanel: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    @Binding var settings: MiniWizardSettings
    @State private var transcript = MiniBRollRules.Transcript()
    @State private var library: [MiniBRollLibrary.Item] = []
    @State private var scenes: [SceneRecord] = []
    @State private var selection: MiniBRollRules.Selection?
    @State private var selectedCuts: Set<UUID> = []
    @State private var picker: PickerRequest?
    @State private var error: String?
    @State private var loading = true
    /// The editors' natural height: the card grows to it so only the transcript scrolls.
    @State private var editorsHeight: CGFloat = 0
    /// The B-roll being played and the source time heard, for the transcript highlight.
    @State private var spoken: (piece: MiniBRollRules.Piece.ID, cut: UUID, time: Double)?

    private struct PickerRequest: Identifiable {
        let id = UUID()
        var pieceID: MiniBRollRules.Piece.ID
        var cutID: UUID?
    }
    private var pieces: [MiniBRollRules.Piece] { MiniBRollRules.pieces(run) }
    private var allCuts: [BRollCut] { pieces.flatMap(\.cuts) }
    private var loadKey: String {
        "\(store.profileGeneration):\(run.batchID):\(store.scenesVersion):" + pieces.map {
            "\($0.id.selectionID):\($0.id.clipIndex):\($0.range.lowerBound):\($0.range.upperBound)"
        }.joined(separator: ",")
    }

    var body: some View {
        // A plain row, not a split view: a split pane whose height follows a
        // player's size can loop AppKit's constraint passes on macOS 27.
        HStack(alignment: .top, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                SectionLabel("Kept footage")
                if loading { ProgressView("Loading transcript…") }
                if let error {
                    FormCaption(error, tone: .warning)
                    Button("Retry") { Task { await load() } }.lineLimit(1).fixedSize()
                } else if !loading, transcript.words.isEmpty {
                    FormCaption("No transcript words in the kept footage.")
                }
                MiniBRollTranscript(transcript: transcript, pieces: pieces, selection: $selection,
                    selectedCuts: selectedCuts, spokenPiece: spoken?.piece, spokenTime: spoken?.time ?? 0) { id, additive in
                        if additive {
                            if selectedCuts.contains(id) { selectedCuts.remove(id) } else { selectedCuts.insert(id) }
                        } else { selectedCuts = [id] }
                    }
            }
            .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    if let selection {
                        Text("“\(selection.text)” · \(selection.range.upperBound - selection.range.lowerBound, specifier: "%.1f")s")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack { selectionButtons(selection) }
                            VStack(alignment: .leading) { selectionButtons(selection) }
                        }
                    }
                    ForEach(pieces) { piece in
                        ForEach(piece.cuts.filter { selectedCuts.contains($0.id) }) { cut in
                            editor(cut, piece: piece)
                        }
                    }
                    if selection == nil, selectedCuts.isEmpty {
                        FormCaption("Select words, then pick a scene. Click coloured words to edit their B-roll; Command-click to select more.")
                    }
                }
                .padding(Theme.spaceS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorsHeight = $0 }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: max(420, editorsHeight))
        .disabled(store.isWizardRunning)
        .task(id: loadKey) { await load() }
        .onChange(of: selection) { _, value in if value != nil { selectedCuts = [] } }
        .onChange(of: allCuts) { _, cuts in selectedCuts.formIntersection(Set(cuts.map(\.id))) }
        .sheet(item: $picker) { request in
            MiniBRollScenePicker(items: library, usedSceneIDs: Set(allCuts.map(\.sceneID))) { scene in
                guard let piece = pieces.first(where: { $0.id == request.pieceID }) else { return }
                if let id = request.cutID, let cut = piece.cuts.first(where: { $0.id == id }) {
                    let replacement = MiniBRollRules.replacing(cut, scene: scene)
                    save(piece.cuts.map { $0.id == id ? replacement : $0 }, piece: piece)
                } else if let selection, let cut = MiniBRollRules.makeCut(selection: selection, piece: piece, scene: scene) {
                    save(piece.cuts + [cut], piece: piece)
                    self.selection = nil
                    selectedCuts = [cut.id]
                }
            }
        }
    }

    private func editor(_ cut: BRollCut, piece: MiniBRollRules.Piece) -> some View {
        MiniBRollEditor(cut: cut, piece: piece, words: transcript.words,
            scene: scenes.first { $0.id == cut.sceneID },
            paletteIndex: allCuts.firstIndex { $0.id == cut.id } ?? 0,
            sourceURL: run.video.path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            onSpoken: { time in
                if let time { spoken = (piece.id, cut.id, time) } else if spoken?.cut == cut.id { spoken = nil }
            },
            onChange: { edited in save(piece.cuts.map { $0.id == cut.id ? edited : $0 }, piece: piece) },
            onReplace: { picker = PickerRequest(pieceID: piece.id, cutID: cut.id) },
            onRemove: {
                save(piece.cuts.filter { $0.id != cut.id }, piece: piece)
                selectedCuts.remove(cut.id)
            })
    }

    @ViewBuilder private func selectionButtons(_ selection: MiniBRollRules.Selection) -> some View {
        Button("Pick Scene") { picker = PickerRequest(pieceID: selection.pieceID) }
            .buttonStyle(.borderedProminent).lineLimit(1).fixedSize().disabled(loading || library.isEmpty)
        Button("Clear Selection") { self.selection = nil }.lineLimit(1).fixedSize()
    }

    private func save(_ cuts: [BRollCut], piece: MiniBRollRules.Piece) {
        guard store.miniRun?.batchID == run.batchID, !store.isWizardRunning else { return }
        store.setMiniBRoll(cuts, piece: piece, batchID: run.batchID)
        settings.didEditBRoll()
    }

    private func load() async {
        guard let database = store.database else { return }
        let key = loadKey
        loading = true
        error = nil
        do {
            let rows = try await database.fetchTranscripts(videoID: run.video.id)
            let speakers = await store.speakerTurns(videoID: run.video.id)
            let active = try await database.fetchScenes(projectID: run.projectID, scope: .active, includeExcluded: true)
            let stored = try await database.fetchScenes(ids: Set(allCuts.map(\.sceneID)))
            let people = store.people
            let videoID = run.video.id
            let keptPieces = pieces
            let result = await Task.detached {
                let named = TranscriptSpeakers.named(speakers.turns, roster: speakers.roster)
                let labels = rows.reduce(into: [Int64: String]()) { result, row in
                    result[row.id] = TranscriptSpeakers.label(for: row, turns: named,
                        roster: speakers.roster, people: people)
                }
                let source = TranscriptQATrim.Transcript(.init(rows: rows, labels: labels, videoID: videoID,
                    speakerSpans: TranscriptSpeakers.spans(turns: named, roster: speakers.roster)))
                return MiniBRollRules.transcript(pieces: keptPieces, source: source)
            }.value
            let catalog = await MiniBRollLibrary.catalog(scenes: active, people: people)
            guard !Task.isCancelled, key == loadKey, store.miniRun?.batchID == run.batchID else { return }
            transcript = result
            library = catalog
            scenes = Array(Dictionary((active + stored).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            loading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, key == loadKey else { return }
            self.error = "Could not load B-roll: \(error.localizedDescription)"
            loading = false
        }
    }
}
