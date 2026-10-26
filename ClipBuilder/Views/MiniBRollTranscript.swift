import SwiftUI

/// One continuous transcript, with source-piece-aware press-and-drag selection.
struct MiniBRollTranscript: View {
    let transcript: MiniBRollRules.Transcript
    let pieces: [MiniBRollRules.Piece]
    @Binding var selection: MiniBRollRules.Selection?
    let selectedCuts: Set<UUID>
    /// The piece and source time of the B-roll being played, so its words
    /// light up as they are heard.
    var spokenPiece: MiniBRollRules.Piece.ID? = nil
    var spokenTime: Double = 0
    let onSelectCut: (UUID, Bool) -> Void
    @State private var frames: [Int: CGRect] = [:]
    @State private var lineStarts: Set<Int> = []
    @State private var anchor: Int?
    @State private var moved = false
    @State private var pointer: CGPoint?
    @State private var scrollDirection = 0
    private let space = "miniBRollWords"

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spaceM) {
                        ForEach(transcript.blocks) { block in
                            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                                if let speaker = block.speaker {
                                    Text(speaker).font(.caption.weight(.semibold))
                                        .foregroundStyle(SpeakerColors.color(for: speaker))
                                        .lineLimit(1).fixedSize()
                                }
                                FlowLayout(spacing: TranscriptQAWordCursor.wordSpacing, rowSpacing: TranscriptQAWordCursor.rowSpacing) {
                                    ForEach(block.words) { word in token(word) }
                                }
                            }
                            .id(block.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spaceS)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                        .onChanged { value in
                            if anchor == nil {
                                anchor = TranscriptQATrim.word(at: value.startLocation, frames: frames)
                                moved = false
                            }
                            moved = moved || abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                            pointer = value.location
                            scrollDirection = value.location.y < 30 ? -1 : value.location.y > geometry.size.height - 30 ? 1 : 0
                            if moved { updateSelection() }
                        }
                        .onEnded { _ in
                            if !moved, let anchor, let word = transcript.words.first(where: { $0.id == anchor }) {
                                click(word)
                            }
                            anchor = nil
                            pointer = nil
                            moved = false
                            scrollDirection = 0
                        })
                }
                .coordinateSpace(name: space)
                .onPreferenceChange(TranscriptQAWordFrames.self) { frames = $0; refreshLineStarts(); if moved { updateSelection() } }
                .task(id: scrollDirection) {
                    guard scrollDirection != 0 else { return }
                    while !Task.isCancelled, anchor != nil {
                        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < geometry.size.height }
                        let wordID = scrollDirection < 0 ? visible.keys.min() : visible.keys.max()
                        if let wordID {
                            let next = max(0, min(transcript.words.count - 1, wordID + scrollDirection))
                            proxy.scrollTo("word-\(next)", anchor: scrollDirection < 0 ? .top : .bottom)
                        }
                        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    }
                }
            }
        }
        .onChange(of: transcript) { _, _ in selection = nil; anchor = nil; frames = [:] }
        .onChange(of: pieces) { _, _ in refreshLineStarts() }
        .accessibilityLabel("Kept footage transcript")
    }

    private func marked(_ word: MiniBRollRules.Word) -> (BRollCut, Int)? {
        var index = 0
        for piece in pieces {
            for cut in piece.cuts {
                defer { index += 1 }
                if piece.id == word.pieceID, word.start >= cut.start, word.start < cut.end { return (cut, index) }
            }
        }
        return nil
    }

    /// The first word on each wrapped line of each B-roll, which carries the
    /// B-roll's colour bar (the Footage panel's saved-pick style).
    private func refreshLineStarts() {
        var result = Set<Int>()
        for word in transcript.words {
            guard let frame = frames[word.id], let cut = marked(word)?.0 else { continue }
            let row = Int((frame.minY * 2).rounded())
            let earlier = transcript.words.contains { other in
                other.id != word.id && other.pieceID == word.pieceID
                    && other.start >= cut.start && other.start < cut.end
                    && frames[other.id].map { Int(($0.minY * 2).rounded()) == row && $0.minX < frame.minX } == true
            }
            if !earlier { result.insert(word.id) }
        }
        if result != lineStarts { lineStarts = result }
    }

    private func token(_ word: MiniBRollRules.Word) -> some View {
        let mark = marked(word)
        let draft = selection.map { $0.pieceID == word.pieceID && word.start >= $0.range.lowerBound && word.end <= $0.range.upperBound } ?? false
        let active = draft || mark.map { selectedCuts.contains($0.0.id) } == true
        let startsLine = mark != nil && lineStarts.contains(word.id)
        let spoken = spokenPiece == word.pieceID && spokenTime >= word.start && spokenTime < word.end
        return Text(word.text)
            .id("word-\(word.id)")
            .font(.callout).fontWeight(spoken ? .bold : .regular)
            .foregroundStyle(spoken ? Color.black : active || mark != nil ? Color.primary : Color.secondary)
            .padding(.horizontal, 2)
            .padding(.leading, startsLine ? RangeReviewPalette.barWidth + RangeReviewPalette.barGap : 0)
            .background {
                if spoken {
                    RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
                } else if active || mark != nil {
                    // One opaque block across the gaps, as the Footage panel draws picks.
                    Rectangle().fill(active ? TranscriptQAWordCursor.selectionColor : RangeReviewPalette.savedBlock)
                        .overlay(alignment: .leading) {
                            if startsLine, let mark {
                                Rectangle().fill(RangeReviewPalette.bar(mark.1))
                                    .frame(width: RangeReviewPalette.barWidth)
                            }
                        }
                        .padding(.horizontal, -TranscriptQAWordCursor.wordSpacing / 2 - 0.5)
                        .padding(.vertical, -TranscriptQAWordCursor.rowSpacing / 2 - 0.5)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptQAWordFrames.self,
                        value: [word.id: geometry.frame(in: .named(space))])
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityLabel(word.text + (mark == nil ? "" : ", B-roll"))
            .accessibilityAction { click(word) }
            .help(mark == nil ? "Press and drag to select words" : "Click to edit B-roll; Command-click to select more")
    }

    private func click(_ word: MiniBRollRules.Word) {
        if let mark = marked(word) {
            selection = nil
            onSelectCut(mark.0.id, NSEvent.modifierFlags.contains(.command))
        } else if let selection, selection.pieceID == word.pieceID,
                  selection.range.contains(word.start) {
            self.selection = nil
        } else {
            selection = MiniBRollRules.selection(anchor: word.id, target: word.id, transcript: transcript)
        }
    }

    private func updateSelection() {
        guard let anchor, let pointer, let target = TranscriptQATrim.word(at: pointer, frames: frames) else { return }
        selection = MiniBRollRules.selection(anchor: anchor, target: target, transcript: transcript)
    }
}
