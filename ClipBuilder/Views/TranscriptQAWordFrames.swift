import SwiftUI

/// Word bounds in a transcript viewport's named coordinate space, kept by the
/// lines themselves: each line stores its words' placement as the layout
/// reports it and its origin as it scrolls; the panel reads the union of the
/// lines on screen. A direct store rather than a preference: a line the lazy
/// stack brings back can be drawn with its layout untouched, so nothing
/// re-emits its frames and the line cannot be clicked until something re-lays
/// it out (Express Transcript, 2026-11-04). Here a line's placement outlives
/// its view, and its origin is refreshed by whichever view shows it next.
@MainActor @Observable
final class TranscriptQAWordFrames {
    /// Every on-screen line's word frames in the viewport space.
    private(set) var frames: [Int: CGRect] = [:]
    /// Word frames local to each line's layout, kept while the line is off screen.
    @ObservationIgnored private var placements: [Int: [Int: CGRect]] = [:]
    @ObservationIgnored private var origins: [Int: CGPoint] = [:]
    @ObservationIgnored private var onScreen: Set<Int> = []
    /// The word IDs each line currently contributes to `frames`.
    @ObservationIgnored private var published: [Int: Set<Int>] = [:]
    /// Lines placed since the last flush. Placement arrives during layout,
    /// where the observed `frames` must not change; one flush per turn
    /// publishes them all.
    @ObservationIgnored private var placed: Set<Int> = []
    @ObservationIgnored private var flushScheduled = false

    /// Safe to call during layout: the frames change on the next turn.
    func place(line: Int, frames newPlacement: [Int: CGRect]) {
        guard placements[line] != newPlacement else { return }
        placements[line] = newPlacement
        placed.insert(line)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { self.flush() }
    }

    /// Publish the placements reported since the last flush.
    func flush() {
        flushScheduled = false
        let lines = placed
        placed = []
        for line in lines { publish(line) }
    }

    func move(line: Int, to origin: CGPoint) {
        guard origins[line] != origin else { return }
        origins[line] = origin
        publish(line)
    }

    func appear(line: Int) {
        guard onScreen.insert(line).inserted else { return }
        publish(line)
    }

    func disappear(line: Int) {
        guard onScreen.remove(line) != nil else { return }
        publish(line)
    }

    /// After the transcript changes: words that no longer exist leave at once;
    /// the rest keep their measurements until the layout reports again, so an
    /// unchanged line (which SwiftUI need not lay out again) stays clickable.
    func keep(wordIDs: Set<Int>) {
        placements = placements.mapValues { $0.filter { wordIDs.contains($0.key) } }
        frames = frames.filter { wordIDs.contains($0.key) }
        published = published.mapValues { $0.intersection(wordIDs) }
    }

    private func publish(_ line: Int) {
        for id in published[line] ?? [] { frames.removeValue(forKey: id) }
        guard onScreen.contains(line), let placed = placements[line], let origin = origins[line] else {
            published[line] = nil
            return
        }
        let offset = TranscriptQATrim.offsetFrames(placed, by: origin)
        frames.merge(offset, uniquingKeysWith: { _, new in new })
        published[line] = Set(offset.keys)
    }
}
