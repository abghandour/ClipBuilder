import Foundation

/// Shared by the Builder, Wizard, and preview. All times are output seconds;
/// word clocks are converted before states are scheduled (including slow motion).
nonisolated enum CaptionOverlayPlan {
    /// ffmpeg takes one input per overlay; with single-threaded still decoders
    /// this stays well under the process thread limit next to the video
    /// decoders and the encoder.
    static let inputLimit = 300

    struct Page: Sendable {
        var caption: CaptionPage
        var position: String
        var language: String = ""
        var textColor: String?
        var streamID: String = ""
        var windowStart: Double?
        var windowEnd: Double?
    }

    struct Raster: Hashable, Sendable {
        var text: String
        var activeIndex: Int?
        var emphasis: [Int] = []
        var textColor: String?
        var frame = CaptionAnimation.Frame()
    }

    struct Overlay: Sendable {
        var raster: Raster
        var position: String
        var start: Double
        var end: Double
    }

    struct Plan: Sendable {
        var overlays: [Overlay]
        var usedPageFallback: Bool
        var usedRevealFallback: Bool = false
    }

    static func pages(segments: [TranscriptSegment], renderer: CaptionRenderer,
                      sourceStart: Double, speed: Double, duration: Double, position: String, language: String = "",
                      speakerTurns: [SpeakerTurn] = [], speakerRows: [TranscriptRow] = [], streamID: String = "") -> [Page] {
        guard speed.isFinite, speed > 0 else { return [] }
        return segments.flatMap { segment -> [Page] in
            let color = renderer.style.resolvedSpeakerColors
                ? CaptionSpeakerColors.color(for: segment, turns: speakerTurns, rows: speakerRows) : nil
            return renderer.pages(for: segment).compactMap { original in
                var page = original
                page.start = (original.start - sourceStart) / speed
                page.end = (original.end - sourceStart) / speed
                guard min(duration, page.end) > max(0, page.start) else { return nil }
                page.words = original.words?.map {
                    TranscriptWord(word: $0.word, start: ($0.start - sourceStart) / speed, end: ($0.end - sourceStart) / speed)
                }
                return Page(caption: page, position: position, language: language, textColor: color, streamID: streamID,
                            windowStart: 0, windowEnd: duration)
            }
        }
    }

    static func plan(pages: [Page], style: CaptionStyle, limit: Int = inputLimit) throws -> Plan {
        func raster(for item: Page, activeIndex: Int? = nil) -> Raster {
            let emphasis = style.resolvedEmphasis == "none" ? []
                : CaptionEmphasis.indices(for: item.caption, language: item.language)
            let emoji = style.resolvedEmoji ? CaptionEmphasis.emoji(for: item.caption, language: item.language) : nil
            return Raster(text: item.caption.text + (emoji.map { " " + $0 } ?? ""),
                          activeIndex: activeIndex, emphasis: emphasis, textColor: item.textColor)
        }
        func clipped(_ overlay: Overlay, to item: Page) -> Overlay? {
            var overlay = overlay
            overlay.start = max(item.windowStart ?? overlay.start, overlay.start)
            overlay.end = min(item.windowEnd ?? overlay.end, overlay.end)
            return overlay.end > overlay.start ? overlay : nil
        }
        func scheduledOverlays(reveal: Bool, revealMotion: Bool) -> [Overlay] {
            pages.flatMap { item -> [Overlay] in
                let baseRaster = raster(for: item)
                let tokens = item.caption.text.split(whereSeparator: \.isWhitespace)
                let states = !reveal && style.resolvedHighlight == "none"
                    ? [CaptionWordStates.State(page: item.caption, start: item.caption.start, end: item.caption.end)]
                    : CaptionWordStates.states(for: item.caption, words: item.caption.words)
                var visible = 0
                var isFirstOverlay = true
                let scheduled = states.flatMap { state -> [Overlay] in
                    var raster = baseRaster
                    let previousVisible = visible
                    if reveal {
                        if let activeIndex = state.activeIndex { visible = activeIndex + 1 }
                        guard visible > 0 else { return [] }
                        let prefix = tokens.prefix(visible).joined(separator: " ")
                        // The full raster already carries the optional emoji; only
                        // append that suffix once all transcript tokens are visible.
                        let suffix = visible == tokens.count ? String(baseRaster.text.dropFirst(item.caption.text.count)) : ""
                        raster.text = prefix + suffix
                        raster.emphasis = baseRaster.emphasis.filter { $0 < visible }
                    }
                    raster.activeIndex = style.resolvedHighlight == "none" ? nil : state.activeIndex
                    let animate = isFirstOverlay || (reveal && revealMotion && visible > previousVisible)
                    isFirstOverlay = false
                    guard animate, style.resolvedAnimation != "none" else {
                        return [Overlay(raster: raster, position: item.position, start: state.start, end: state.end)]
                    }
                    let duration = min(CaptionAnimation.duration(for: style.resolvedAnimation), state.end - state.start)
                    let frames = CaptionAnimation.frames(for: style.resolvedAnimation, duration: duration)
                    return frames.enumerated().compactMap { index, frame in
                        let end = index + 1 < frames.count ? state.start + frames[index + 1].at : state.end
                        let start = state.start + frame.at
                        guard end > start else { return nil }
                        var animated = raster
                        animated.frame = frame
                        animated.frame.at = 0 // Time does not affect pixels or the cache identity.
                        return Overlay(raster: animated, position: item.position, start: start, end: end)
                    }
                }
                return scheduled.compactMap { clipped($0, to: item) }
            }
        }
        let reveal = style.resolvedReveal == "word"
        let revealMotion = reveal && style.resolvedRevealMotion && style.resolvedAnimation != "none"
        var overlays = scheduledOverlays(reveal: reveal, revealMotion: revealMotion)
        var usedRevealFallback = false
        if overlays.count > limit, revealMotion {
            overlays = scheduledOverlays(reveal: true, revealMotion: false)
            usedRevealFallback = true
        }
        if overlays.count > limit, reveal {
            overlays = scheduledOverlays(reveal: false, revealMotion: false)
            usedRevealFallback = true
        }
        guard overlays.count > limit else {
            return Plan(overlays: overlays, usedPageFallback: false, usedRevealFallback: usedRevealFallback)
        }
        return Plan(overlays: try staticPages(pages, limit: limit).compactMap {
            clipped(Overlay(raster: raster(for: $0), position: $0.position,
                            start: $0.caption.start, end: $0.caption.end), to: $0)
        }, usedPageFallback: true, usedRevealFallback: usedRevealFallback)
    }

    private enum PlanningError: LocalizedError {
        case tooManyStreams
        var errorDescription: String? { "Too many simultaneous caption tracks. Reduce the number of captioned tracks and render again." }
    }

    /// Very long one-word templates can exceed the limit even without word
    /// highlights. Coarsen only the static fallback, retaining every token and
    /// each independent clip's placement. A merged page uses its first colour.
    private static func staticPages(_ pages: [Page], limit: Int) throws -> [Page] {
        guard pages.count > limit else { return pages }
        var groups: [[Page]] = []
        var keys: [String] = []
        for page in pages {
            let key = page.streamID + "|" + page.position
            if let index = keys.firstIndex(of: key) { groups[index].append(page) }
            else { keys.append(key); groups.append([page]) }
        }
        guard limit > 0, groups.count <= limit else { throw PlanningError.tooManyStreams }
        var result: [Page] = []
        var remaining = limit
        for (index, group) in groups.enumerated() {
            let quota = min(group.count, max(1, remaining / (groups.count - index)))
            let chunkSize = Int(ceil(Double(group.count) / Double(quota)))
            for start in stride(from: 0, to: group.count, by: chunkSize) {
                let chunk = group[start..<min(group.count, start + chunkSize)]
                var page = group[start]
                page.caption.text = chunk.map { $0.caption.text }.joined(separator: " ")
                page.caption.start = chunk.map { $0.caption.start }.min() ?? page.caption.start
                page.caption.end = chunk.map { $0.caption.end }.max() ?? page.caption.end
                page.caption.words = nil
                result.append(page)
                remaining -= 1
            }
        }
        return result
    }

}
