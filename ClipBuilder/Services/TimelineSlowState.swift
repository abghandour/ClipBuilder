import Foundation

/// Edit provenance, not render state. Original knots and optional speed values
/// let Remove recover the unsplit clip, including its original uid. All fields
/// are optional so older saved edits remain decodable when this state evolves.
nonisolated struct TimelineSlowState: Codable, Sendable, Equatable {
    struct Group: Codable, Sendable, Equatable {
        var id: UUID?
        var stretch: StrikeImpactRules.Stretch?
        var strength: StrikeImpactRules.Strength?
    }
    struct Clip: Codable, Sendable, Equatable {
        var value: TimelineClip?
        var uid: UUID?
        var videoFile: String?
        var sceneID: Int64?
        var duration: Double?
        var fadeIn: Double?
        var fadeOut: Double?
        var sourceStart: Double?
        var sourceEnd: Double?
        var sceneFullDuration: Double?
    }
    var groups: [Group]?
    var originals: [Clip]?
    var resolved: [Clip]?
    var editedRoots: [UUID]?
    var applied: [Clip]?
    var owners: [UUID: UUID]?
    var lanes: Lanes?
    var appliedLanes: Lanes?

    var stretches: [StrikeImpactRules.Stretch] { (groups ?? []).compactMap(\.stretch).sorted { $0.start < $1.start } }

    // TimelineClip's ordinary save format omits uids. Provenance must keep them
    // even on normal-speed head/tail pieces and after reopening the document.
    static func saved(_ clips: [TimelineClip]) -> [Clip] {
        clips.map { .init(value: $0, uid: $0.uid, videoFile: $0.videoFile, sceneID: $0.sceneID,
                         duration: $0.duration, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut, sourceStart: $0.sourceStart,
                         sourceEnd: $0.sourceEnd, sceneFullDuration: $0.sceneFullDuration) }
    }
    static func clips(_ saved: [Clip]?) -> [TimelineClip] {
        (saved ?? []).compactMap {
            guard var clip = $0.value, let uid = $0.uid else { return nil }
            clip.uid = uid
            clip.videoFile = $0.videoFile
            clip.sceneID = $0.sceneID
            clip.duration = $0.duration ?? clip.duration
            clip.fadeIn = $0.fadeIn ?? clip.fadeIn
            clip.fadeOut = $0.fadeOut ?? clip.fadeOut
            clip.sourceStart = $0.sourceStart
            clip.sourceEnd = $0.sourceEnd
            clip.sceneFullDuration = $0.sceneFullDuration
            return clip
        }
    }

    /// UI equality intentionally omits camera/source evidence. Snapshot
    /// restoration must notice those edits as well as the visible controls.
    /// `sceneFullDuration` is not compared: it is filled in at run time and
    /// is absent on a reopened document, so it is no evidence of an edit.
    static func matchesSavedClip(_ current: TimelineClip, _ saved: TimelineClip) -> Bool {
        current == saved && current.cameraPath == saved.cameraPath
            && current.cameraPathSource == saved.cameraPathSource
            && sameSourceEnd(current, saved)
            && current.contentWindow == saved.contentWindow
    }

    /// Saving writes a trimmed clip's end as start + span, so a reopened
    /// clip's end can differ from the snapshot in the last bits, or be set
    /// where the snapshot had none.
    private static func sameSourceEnd(_ a: TimelineClip, _ b: TimelineClip) -> Bool {
        func end(_ clip: TimelineClip) -> Double? {
            clip.sourceEnd ?? clip.sourceStart.map { $0 + clip.sourceSpan }
        }
        switch (end(a), end(b)) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 1e-6
        default: return false
        }
    }

    mutating func preserveChanges(in document: TimelineDocument) {
        guard let applied else { return }
        let expected = Self.clips(applied)
        var edited = Set(editedRoots ?? [])
        for clip in expected {
            let current = document.videoTrack.first { $0.uid == clip.uid }
            if current.map({ Self.matchesSavedClip($0, clip) }) != true {
                edited.insert(owners?[clip.uid] ?? clip.uid)
            }
        }
        editedRoots = edited.isEmpty ? nil : Array(edited)
        if let appliedLanes { lanes?.discardChanged(current: Lanes(document), expected: appliedLanes) }
    }

    struct Lanes: Codable, Sendable, Equatable {
        var sounds: [SoundItem]?
        var texts: [TextOverlayItem]?
        var images: [ImageOverlayItem]?
        var overlays: [OverlayBlockItem]?
        var crops: [CropBlockItem]?
        var identities: [String: [UUID]]?

        init(_ document: TimelineDocument) {
            sounds = document.soundTrack
            texts = document.textOverlays
            images = document.imageOverlays
            overlays = document.overlayBlocks
            crops = document.cropBlocks
            var ids = ["sounds": document.soundTrack.map(\.uid), "texts": document.textOverlays.map(\.uid),
                       "images": document.imageOverlays.map(\.uid), "overlays": document.overlayBlocks.map(\.uid),
                       "crops": document.cropBlocks.map(\.uid)]
            for (index, block) in document.overlayBlocks.enumerated() {
                ids["texts-\(index)"] = block.composition.texts.map(\.uid)
                ids["images-\(index)"] = block.composition.images.map(\.uid)
            }
            identities = ids
        }

        func restoreIDs(in document: inout TimelineDocument) {
            guard let identities else { return }
            for (i, uid) in (identities["sounds"] ?? []).enumerated() where document.soundTrack.indices.contains(i) { document.soundTrack[i].uid = uid }
            for (i, uid) in (identities["texts"] ?? []).enumerated() where document.textOverlays.indices.contains(i) { document.textOverlays[i].uid = uid }
            for (i, uid) in (identities["images"] ?? []).enumerated() where document.imageOverlays.indices.contains(i) { document.imageOverlays[i].uid = uid }
            for (i, uid) in (identities["crops"] ?? []).enumerated() where document.cropBlocks.indices.contains(i) { document.cropBlocks[i].uid = uid }
            for (i, uid) in (identities["overlays"] ?? []).enumerated() where document.overlayBlocks.indices.contains(i) {
                document.overlayBlocks[i].uid = uid
                for (j, id) in (identities["texts-\(i)"] ?? []).enumerated() where document.overlayBlocks[i].composition.texts.indices.contains(j) {
                    document.overlayBlocks[i].composition.texts[j].uid = id
                }
                for (j, id) in (identities["images-\(i)"] ?? []).enumerated() where document.overlayBlocks[i].composition.images.indices.contains(j) {
                    document.overlayBlocks[i].composition.images[j].uid = id
                }
            }
        }

        mutating func restoreIDs() {
            var document = TimelineDocument()
            document.soundTrack = sounds ?? []
            document.textOverlays = texts ?? []
            document.imageOverlays = images ?? []
            document.overlayBlocks = overlays ?? []
            document.cropBlocks = crops ?? []
            restoreIDs(in: &document)
            if sounds != nil { sounds = document.soundTrack }
            if texts != nil { texts = document.textOverlays }
            if images != nil { images = document.imageOverlays }
            if overlays != nil { overlays = document.overlayBlocks }
            if crops != nil { crops = document.cropBlocks }
        }

        mutating func discardChanged(current: Lanes, expected: Lanes) {
            if current.sounds != expected.sounds { sounds = nil }
            if current.texts != expected.texts { texts = nil }
            if current.images != expected.images { images = nil }
            if current.overlays != expected.overlays { overlays = nil }
            if current.crops != expected.crops { crops = nil }
        }

        /// Restore exact original arithmetic/knots only for untouched lanes;
        /// edits made since insertion keep their inverse-mapped values.
        func restoreUnedited(in document: inout TimelineDocument, current: Lanes, expected: Lanes) {
            if current.sounds == expected.sounds, let sounds { document.soundTrack = sounds }
            if current.texts == expected.texts, let texts { document.textOverlays = texts }
            if current.images == expected.images, let images { document.imageOverlays = images }
            if current.overlays == expected.overlays, let overlays { document.overlayBlocks = overlays }
            if current.crops == expected.crops, let crops { document.cropBlocks = crops }
        }
    }
}
