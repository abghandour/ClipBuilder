import Foundation

/// Source-time contacts become ordinary moving clips and silent held frames.
nonisolated enum StrikeFreezeRules {
    static let minimumPiece = 0.25
    static let maximumContacts = 8
    static let holdRange = 0.05...5.0
    static let drawingHoldRange = 0.05...40.0
    static let maximumDrawings = 8

    nonisolated struct Pause: Sendable, Equatable {
        /// Absolute source seconds for pieces; cut-local screen seconds for sharedPieces.
        var time: Double
        var duration: Double
        var drawing: Telestration? = nil
        /// Drawing owner video path; nil means the main source.
        var source: String? = nil
    }

    /// An unrelated inspector edit does not invalidate an in-flight contact read.
    static func sameContactSource(_ current: TimelineClip?, _ requested: TimelineClip) -> Bool {
        guard let current else { return false }
        return current.uid == requested.uid && current.sceneID == requested.sceneID
            && current.videoFile == requested.videoFile && current.sourceStart == requested.sourceStart
            && current.sourceSpan == requested.sourceSpan && (current.hold == true) == (requested.hold == true)
            && current.strikeImpactsFrozen == requested.strikeImpactsFrozen
    }

    struct ContactSelection: Sendable, Equatable {
        var contacts: [Double] = []
        /// Only contacts in this clip's source range count as filtered.
        var filtered = 0
    }

    static func contacts(_ clip: TimelineClip, contacts: [Double]) -> [Double] {
        selection(clip, contacts: contacts).contacts
    }

    static func selection(_ clip: TimelineClip, contacts: [Double]) -> ContactSelection {
        guard !clip.bumper, !clip.isCutaway, clip.hold != true, clip.strikeImpactsFrozen != true,
              let start = clip.sourceStart, start.isFinite, start >= 0,
              clip.sourceSpan.isFinite, clip.sourceSpan > 0,
              clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0 else { return ContactSelection() }
        let end = start + clip.sourceSpan
        guard end.isFinite else { return ContactSelection() }
        let minimum = minimumPiece * clip.effectiveSpeed
        var result = ContactSelection()
        for contact in contacts.filter({ $0.isFinite && $0 >= start && $0 <= end }).sorted() {
            guard boundaryReason(start: start, end: end, speed: clip.effectiveSpeed, contact: contact) == nil,
                  contact - (result.contacts.last ?? start) >= minimum - 1e-9,
                  result.contacts.count < maximumContacts else {
                result.filtered += 1
                continue
            }
            result.contacts.append(contact)
        }
        return result
    }

    /// Shared by selection and the pre-render explanation. Keep the tolerance
    /// here so a contact on the minimum-piece boundary has one answer.
    static func boundaryReason(start: Double, end: Double, speed: Double, contact: Double) -> String? {
        let minimum = minimumPiece * speed
        if contact - start < minimum - 1e-9 { return "too close to the clip start" }
        if end - contact < minimum - 1e-9 { return "too close to the clip end" }
        return nil
    }

    /// Empty means no edit. Split on the original source clock, then add the
    /// holds' screen time, so camera paths follow exactly the hand-split math.
    static func pieces(_ clip: TimelineClip, contacts: [Double], hold: Double) -> [TimelineClip] {
        guard hold.isFinite, holdRange.contains(hold) else { return [] }
        let selected = self.contacts(clip, contacts: contacts)
        return pieces(clip, pauses: selected.map { Pause(time: $0, duration: hold) })
    }

    /// Selection has already resolved priorities and the independent caps.
    /// Validate every boundary without selecting again, then split only once.
    static func pieces(_ clip: TimelineClip, pauses: [Pause]) -> [TimelineClip] {
        guard !pauses.isEmpty, !clip.bumper, !clip.isCutaway, clip.hold != true,
              clip.strikeImpactsFrozen != true, let start = clip.sourceStart,
              start.isFinite, start >= 0, clip.sourceSpan.isFinite, clip.sourceSpan > 0,
              clip.effectiveSpeed.isFinite, clip.effectiveSpeed > 0 else { return [] }
        let end = start + clip.sourceSpan
        guard end.isFinite else { return [] }
        var previous = start
        for pause in pauses {
            let range = pause.drawing == nil ? holdRange : drawingHoldRange
            guard pause.time.isFinite, pause.duration.isFinite, range.contains(pause.duration),
                  boundaryReason(start: start, end: end, speed: clip.effectiveSpeed, contact: pause.time) == nil,
                  pause.time - previous >= minimumPiece * clip.effectiveSpeed - 1e-9 else { return [] }
            previous = pause.time
        }
        var remaining = clip
        var result: [TimelineClip] = []
        for pause in pauses {
            let contact = pause.time, hold = pause.duration
            let at = clip.startTime + (contact - start) / clip.effectiveSpeed
            guard let split = TimelineSplit.pieces(remaining, at: at, minimum: minimumPiece) else { return [] }
            result.append(split.head)
            var frozen = split.tail
            frozen.sourceStart = contact
            frozen.sourceEnd = contact
            frozen.duration = hold
            frozen.speed = nil
            frozen.hold = true
            frozen.telestration = pause.drawing.map(TelestrationMotionRules.paused)
            frozen.transIn = nil
            frozen.transOut = nil
            frozen.fadeIn = 0
            frozen.fadeOut = 0
            if let path = clip.cameraPath {
                frozen.cameraPath = HoldClipRules.cameraPath(path, at: contact - start, duration: hold)
            }
            result.append(frozen)
            remaining = split.tail
        }
        result.append(remaining)
        var cursor = clip.startTime
        for index in result.indices {
            result[index].uid = UUID()
            // The cap can leave more contacts inside the final tail. Remember
            // the edit so even that piece stays idempotent after save/reload.
            // Drawing-only splits carry it too: captions and the assembly
            // clock recognise a reel's pauses by this flag.
            result[index].strikeImpactsFrozen = true
            result[index].startTime = cursor
            cursor += result[index].duration
        }
        return result
    }
}
