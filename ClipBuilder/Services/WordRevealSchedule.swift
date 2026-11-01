import Foundation

/// The Wizard's `word_reveal` text overlay: one progressive PNG per word,
/// hard-cut on staggered windows, the full text held from the last reveal to
/// the end. Shared by the Wizard's extraction and the Builder renderer, so a
/// Wizard timeline opened in the Builder reveals its words the same way.
nonisolated enum WordRevealSchedule {
    static let animation = "word_reveal"

    struct Step: Equatable, Sendable {
        /// Words drawn in this window (1...wordCount).
        var visibleWords: Int
        /// Window in seconds from the overlay's start.
        var start: Double
        var end: Double
    }

    /// Nil-safe: an overlay of one word (or none) does not reveal and gets no
    /// steps; windows past `duration` never show and are dropped.
    static func steps(duration: Double, wordCount: Int) -> [Step] {
        guard wordCount > 1, duration > 0 else { return [] }
        let step = min(0.3, max(0.1, duration / 3 / Double(wordCount)))
        return (1...wordCount).compactMap { index in
            let start = Double(index - 1) * step
            let end = min(duration, index == wordCount ? duration : Double(index) * step)
            return end > start ? Step(visibleWords: index, start: start, end: end) : nil
        }
    }
}
