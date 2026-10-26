import Foundation

/// A run's base renderer plus person overrides sharing the same canvas rules.
nonisolated struct CaptionRendererSet: Sendable {
    let base: CaptionRenderer
    let perSpeaker: [String: CaptionRenderer]

    init(base: CaptionRenderer, speakerStyles: [String: CaptionStyle] = [:]) {
        self.base = base
        perSpeaker = speakerStyles.mapValues { style in
            var renderer = base
            renderer.style = style
            return renderer
        }
    }

    var usesSpeakers: Bool { !perSpeaker.isEmpty }
    var styles: [String: CaptionStyle] { perSpeaker.mapValues(\.style) }

    func renderer(styleID: String?) -> CaptionRenderer {
        styleID.flatMap { perSpeaker[$0] } ?? base
    }

    func renderer(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow])
        -> (CaptionRenderer, styleID: String?) {
        renderer(for: segment, speakers: CaptionSpeakerColors.Sorted(turns: turns, rows: rows))
    }

    func renderer(for segment: TranscriptSegment, speakers: CaptionSpeakerColors.Sorted)
        -> (CaptionRenderer, styleID: String?) {
        let speaker = CaptionSpeakerColors.speakerKey(for: segment, sorted: speakers)
        guard let key = CaptionSpeakerColors.personKey(speaker), let renderer = perSpeaker[key] else {
            return (base, nil)
        }
        return (renderer, key)
    }
}
