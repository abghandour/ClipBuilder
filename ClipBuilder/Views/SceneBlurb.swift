import SwiftUI

/// What a scene is about, in a line or two: the analysis narrative when a
/// model wrote one (podcast exchanges carry "title — summary"), else the
/// first words of transcript inside the scene.
nonisolated struct SceneBlurb: Sendable, Equatable {
    var title: String?
    var text: String
    /// True when the text is transcript, not a written summary.
    var isExcerpt: Bool

    /// Split "title — summary" into its parts; a narrative without the
    /// dash is all text.
    static func fromNarrative(_ narrative: String) -> SceneBlurb {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " — "), !trimmed[..<range.lowerBound].isEmpty,
           trimmed[..<range.lowerBound].count <= 80 {
            return SceneBlurb(title: String(trimmed[..<range.lowerBound]),
                              text: String(trimmed[range.upperBound...]), isExcerpt: false)
        }
        return SceneBlurb(title: nil, text: trimmed, isExcerpt: false)
    }

    /// The first `words` words of the transcript rows overlapping the range.
    static func fromTranscript(_ rows: [TranscriptRow], start: Double, end: Double, words: Int = 40) -> SceneBlurb? {
        let inside = rows.filter { !$0.isTranslation && $0.endTime > start && $0.startTime < end }
            .sorted { $0.startTime < $1.startTime }
        let all = inside.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
        guard !all.isEmpty else { return nil }
        let text = all.prefix(words).joined(separator: " ") + (all.count > words ? "…" : "")
        return SceneBlurb(title: nil, text: text, isExcerpt: true)
    }

    var accessibilityText: String {
        [title, text].compactMap { $0 }.joined(separator: ". ")
    }
}

/// Talk footage: a podcast or interview file, or a podcast exchange scene.
extension SceneRecord {
    func isTalk(videoType: VideoType?) -> Bool {
        videoType == .podcast || videoType == .interview || tags.contains { $0.hasPrefix("podcast") }
    }
}

/// Which frame stands for a scene on a card: the middle of the scene, or
/// for talk footage half a second in, cropped to the person speaking then
/// (the scene's stored camera path, framed for a 9:16 card).
extension SceneRecord {
    func posterFrame(videoType: VideoType?) -> (time: Double, window: FreeCropRect?) {
        guard isTalk(videoType: videoType), let path = centerStagePath, path.keyframes.count >= 2 else {
            return ((startTime + endTime) / 2, nil)
        }
        let offset = min(0.5, max(0, duration / 2))
        guard let rect = CenterStageService.interpolated(path.keyframes, at: offset) else {
            return ((startTime + endTime) / 2, nil)
        }
        return (startTime + offset, FreeCropRect(xFrac: rect.x, yFrac: rect.y, wFrac: rect.w, hFrac: rect.h))
    }
}

/// A panel over the lower part of a thumbnail that fades in while the
/// pointer rests on the card, with the scene's title and summary. Apply it
/// first, under every control; the card reports the hover from its
/// outermost layer, because SwiftUI hands hover to the topmost view and
/// the drag handle and buttons sit above the thumbnail.
struct SceneBlurbPanel: ViewModifier {
    @Environment(AppStore.self) private var store
    let scene: SceneRecord
    let hovering: Bool
    @State private var shown = false
    @State private var blurb: SceneBlurb?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if shown, let blurb {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = blurb.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                        }
                        Text(blurb.text)
                            .font(.caption2)
                            .lineLimit(blurb.title == nil ? 4 : 3)
                        if blurb.isExcerpt {
                            Text("Transcript")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 34)   // clear of the duration badge and the plus button
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75), .black.opacity(0.85)],
                                               startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .task(id: hovering) {
                guard hovering else {
                    withAnimation(.easeOut(duration: 0.15)) { shown = false }
                    return
                }
                if blurb == nil { blurb = await store.sceneBlurb(scene) }
                guard blurb != nil else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, hovering else { return }
                withAnimation(.easeIn(duration: 0.15)) { shown = true }
            }
            .accessibilityLabel(Text(blurb?.accessibilityText ?? scene.narrative ?? scene.videoFilename))
    }
}

extension View {
    /// The scene's title and summary over the thumbnail while `hovering`.
    func sceneBlurbPanel(_ scene: SceneRecord, hovering: Bool) -> some View {
        modifier(SceneBlurbPanel(scene: scene, hovering: hovering))
    }
}
