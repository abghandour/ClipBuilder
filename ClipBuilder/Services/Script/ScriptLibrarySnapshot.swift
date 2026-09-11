import Foundation

/// App-resolved inputs, never decoded from a script. Callers pass only the
/// active project's videos and scenes. All later reads use this value copy.
nonisolated struct ScriptLibrarySnapshot: Sendable {
    var projectID: Int64?
    var prerequisiteOutcomes: [Int64: [BuilderPrerequisiteKind: PrerequisiteOutcome]] = [:]
    var videos: [VideoRecord] = []
    var scenes: [SceneRecord] = []
    var people: [PersonRecord] = []
    var videoPeople: [Int64: [VideoPersonRanges]] = [:]
    var videosWithPeople: Set<Int64> = []
    var transcripts: [TranscriptRow] = []
    var features: [TranscriptFeatureSegment] = []
    var proposals: [EditProposal] = []
    var tags: [String] = []
    var layouts: [ScreenCropLayout] = []
    var bumpers: [String: BumperAsset] = [:]
    var sounds: [String: String] = [:]
    var images: [String: String] = [:]
    var templates: [OverlayTemplate] = []
    var logoPath: String? = nil

    var templateRows: [TemplateQueryRow] {
        [TemplateQueryRow(name: "Lower Third", kind: "lower_third",
                          duration: LowerThirdOverlay.composition(name: "NAME", role: "ROLE / TITLE", logoPath: logoPath).duration)]
            + templates.filter { $0.name.caseInsensitiveCompare("Lower Third") != .orderedSame }
                .sorted { $0.name < $1.name }
                .map { TemplateQueryRow(name: $0.name, kind: "template", duration: max(1, ($0.composition.duration * 10).rounded() / 10)) }
    }

    func overlay(named name: String, person reference: String?) throws -> OverlayTemplate {
        if name.caseInsensitiveCompare("Lower Third") == .orderedSame {
            if let reference {
                let eligible = people.filter { !$0.hidden && !$0.name.isEmpty }
                let keyed = eligible.filter { $0.key.caseInsensitiveCompare(reference) == .orderedSame }
                let matches = keyed.isEmpty ? eligible.filter { $0.displayName.caseInsensitiveCompare(reference) == .orderedSame } : keyed
                guard matches.count == 1, let person = matches.first else {
                    throw BuilderCommandFailure.invalid("Person is missing or ambiguous in the roster.")
                }
                return OverlayTemplate(name: "Lower Third — \(person.displayName)",
                    composition: LowerThirdOverlay.composition(name: person.displayName,
                        role: person.descriptor.isEmpty ? "Guest" : person.descriptor, logoPath: logoPath))
            }
            return OverlayTemplate(name: "Lower Third", composition: LowerThirdOverlay.composition(
                name: "NAME", role: "ROLE / TITLE", logoPath: logoPath))
        }
        guard reference == nil else { throw BuilderCommandFailure.invalid("person is only valid for Lower Third.") }
        let matches = templates.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let template = matches.first else {
            throw BuilderCommandFailure.invalid("Template is missing or ambiguous in the snapshot.")
        }
        return template
    }

    /// Explicit Library refresh preserves resource identities captured at session
    /// creation. It never subscribes to AppStore or hydrates the live document.
    func refreshed(database: Database, language: String = "") async throws -> Self {
        var copy = self
        copy.videos = try await database.fetchVideos(projectID: projectID)
        copy.scenes = try await database.fetchScenes(projectID: projectID)
        copy.people = try await database.fetchPeople()
        copy.transcripts = []; copy.features = []; copy.proposals = []
        copy.videoPeople = [:]; copy.videosWithPeople = []; copy.prerequisiteOutcomes = [:]
        let started = ContinuousClock.now
        for video in copy.videos {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(10) else {
                throw ScriptError.invalid("Library snapshot exceeded ten seconds.")
            }
            copy.transcripts += try await database.fetchTranscripts(videoID: video.id)
            copy.features += try await database.fetchTranscriptFeatures(videoID: video.id)
            copy.proposals += try await database.fetchEditProposals(videoID: video.id)
            let roster = try await database.fetchVideoPeopleRanges(videoID: video.id)
            copy.videoPeople[video.id] = roster
            if !roster.isEmpty { copy.videosWithPeople.insert(video.id) }
            for kind in BuilderPrerequisiteKind.allCases {
                let signature = "v1:\(video.hash):\(kind == .transcript ? language : "")"
                if let outcome = try await database.prerequisiteResult(kind: kind, video: video,
                                                                       signature: signature, language: language) {
                    copy.prerequisiteOutcomes[video.id, default: [:]][kind] = outcome
                }
            }
        }
        return copy
    }

    /// Task-local lookup confines resource overrides to a synchronous edit;
    /// normal UI and rendering continue resolving their live resources.
    @MainActor
    func withLayouts<T>(_ body: () throws -> T) rethrows -> T {
        try ScriptLayoutScope.$layouts.withValue(layouts, operation: body)
    }

    func videoID(for clip: TimelineClip, scene: SceneRecord?) -> Int64? {
        if let scene { return scene.videoID }
        if let id = clip.sceneID, let linked = scenes.first(where: { $0.id == id }) { return linked.videoID }
        return videos.first { $0.path == clip.videoFile }?.id
    }

    func rosterPeople(for clip: TimelineClip, scene: SceneRecord?) -> [VideoPersonRanges] {
        guard let video = videoID(for: clip, scene: scene) else { return [] }
        return (videoPeople[video] ?? []).filter { person in
            if person.ranges.isEmpty { return true }
            guard let start = clip.sourceStart, start.isFinite, clip.sourceSpan > 0 else { return false }
            return person.ranges.contains { $0.overlaps(start: start, end: start + clip.sourceSpan) }
        }
    }

    /// Query-only inference: never attaches a scene to the document or changes edit predicates.
    func inferredScene(for clip: TimelineClip) -> SceneRecord? {
        guard clip.sceneID == nil, let video = videoID(for: clip, scene: nil),
              let start = clip.sourceStart, start.isFinite, clip.sourceSpan > 0 else { return nil }
        let candidates = scenes.filter {
            $0.videoID == video
                && min($0.endTime, start + clip.sourceSpan) - max($0.startTime, start) >= clip.sourceSpan / 2
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func sourceDuration(for clip: TimelineClip) -> Double? {
        if let id = clip.sceneID, let scene = scenes.first(where: { $0.id == id }) { return scene.videoDuration }
        return videos.first { $0.path == clip.videoFile }?.duration
    }
}

nonisolated enum ScriptLayoutScope {
    @TaskLocal static var layouts: [ScreenCropLayout]?
}
