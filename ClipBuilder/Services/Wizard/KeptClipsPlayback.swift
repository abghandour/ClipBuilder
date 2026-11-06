import Foundation

/// The rules behind the wizard pages' plain clip player: which clip plays,
/// what happens at a clip's end, and how long the whole list runs. Times
/// are source seconds; the player shows the recording itself, nothing
/// rendered over it.
nonisolated enum KeptClipsPlayback {
    /// What to do when the playhead reaches `time` in clip `index`.
    enum Step: Equatable {
        /// Still inside the clip.
        case keepPlaying
        /// Play all: go on with the next clip from its start.
        case advance(to: Int)
        /// The clip (or the whole list) is done: stop and rewind to the clip's start.
        case stop
    }

    /// A little before the end, so the periodic tick never shows a frame past the clip.
    static let endTolerance = 0.03

    static func step(time: Double, index: Int, clips: [WizardPreviewClip], playsAll: Bool) -> Step {
        guard clips.indices.contains(index) else { return .stop }
        guard time >= clips[index].end - endTolerance else { return .keepPlaying }
        return playsAll && index + 1 < clips.count ? .advance(to: index + 1) : .stop
    }

    /// Every clip end to end, in source seconds.
    static func totalDuration(_ clips: [WizardPreviewClip]) -> Double {
        clips.reduce(0) { $0 + $1.duration }
    }

    /// Analysis scenes as clips, for a page with no kept footage of its own.
    static func clips(scenes: [SceneRecord]) -> [WizardPreviewClip] {
        scenes.map {
            WizardPreviewClip(id: "scene-\($0.id)", title: "Scene", scene: $0, start: $0.startTime, end: $0.endTime)
        }
    }
}
