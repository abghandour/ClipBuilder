import Foundation

/// Hash the highlight inputs after tag text is resolved, so an unchanged
/// request reuses the reel instead of planning and encoding it again.
nonisolated enum PodcastHighlightRenderKey {
    static let version = "podcast-highlight-render-v2"

    private struct Candidate: Encodable {
        var sourceStart: Double; var sourceEnd: Double; var framing: String; var kind: String
        var speakerKeys: [String]; var includesQuestion: Bool
    }
    private struct Video: Encodable {
        var path: String; var fingerprint: String; var duration: Double; var width: Int; var height: Int
        var videoType: String?; var podcastLayout: String?; var podcastSeamX: Double?; var podcastTilesJSON: String?
    }
    private struct Scene: Encodable {
        var id: Int64; var videoID: Int64; var videoPath: String; var startTime: Double; var endTime: Double
        var tags: [String]; var score: Double?; var narrative: String?; var excluded: Bool; var ignored: Bool
        var cropXFrac: Double?; var freeCropsJSON: String?; var centerStagePathJSON: String?; var wide: Bool
    }
    private struct Member: Encodable {
        var key: String; var name: String; var portraitAt: Double; var portraitBox: VideoPersonRecord.PortraitBox?
    }
    private struct Person: Encodable { var key: String; var name: String; var hidden: Bool; var tagText: String }
    private struct Image: Encodable {
        var path: String; var size: UInt64?; var modified: Date?
    }
    private struct Evidence: Encodable {
        var candidate: Candidate
        var video: Video
        var scenes: [Scene]
        var segments: [TranscriptSegment]
        var turns: [SpeakerTurn]
        var roster: [Member]
        var people: [Person]
        var options: WizardOptions
        var threshold: Double
        var layouts: [ScreenCropLayout]
        var profile: BrandProfile
        var tagStyle: TagStyle
        var tagImages: [Image]
    }

    /// `sourceFingerprint` identifies the recording's bytes (size and
    /// modification date), so a re-exported file never reuses a stale reel.
    @concurrent
    static func make(candidate: HighlightCandidate, request: PodcastHighlightReviewRequest,
                     layouts: [ScreenCropLayout], profile: BrandProfile, tagText: [String: String],
                     sourceFingerprint: String? = nil) async throws -> String {
        let video = request.video
        let fingerprint = try sourceFingerprint ?? SourceIdentityCache.shared.fingerprint(of: video.url)
        let style = profile.tagStyle(id: request.options.nameTagStyleID)
        let images = style.images.map { image in
            let path = (image.path as NSString).expandingTildeInPath
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return Image(path: path, size: (attributes?[.size] as? NSNumber)?.uint64Value,
                         modified: attributes?[.modificationDate] as? Date)
        }
        let evidence = Evidence(
            candidate: Candidate(sourceStart: candidate.sourceStart, sourceEnd: candidate.sourceEnd,
                                 framing: candidate.framing.rawValue, kind: candidate.kind.rawValue,
                                 speakerKeys: candidate.speakerKeys.sorted(), includesQuestion: candidate.includesQuestion),
            video: Video(path: video.path ?? "", fingerprint: fingerprint, duration: video.duration, width: video.width,
                         height: video.height, videoType: video.videoType, podcastLayout: video.podcastLayout,
                         podcastSeamX: video.podcastSeamX, podcastTilesJSON: video.podcastTilesJSON),
            scenes: request.scenes.sorted { $0.id < $1.id }.map {
                Scene(id: $0.id, videoID: $0.videoID, videoPath: $0.videoPath, startTime: $0.startTime, endTime: $0.endTime,
                      tags: $0.tags.sorted(), score: $0.score, narrative: $0.narrative, excluded: $0.excluded, ignored: $0.ignored,
                      cropXFrac: $0.cropXFrac, freeCropsJSON: $0.freeCropsJSON, centerStagePathJSON: $0.centerStagePathJSON, wide: $0.wide)
            },
            segments: request.segments,
            turns: request.turns,
            roster: request.roster.sorted { $0.key < $1.key }.map {
                Member(key: $0.key, name: $0.name, portraitAt: $0.portraitAt, portraitBox: $0.portraitBox)
            },
            people: request.people.sorted { $0.key < $1.key }.map {
                Person(key: $0.key, name: $0.name, hidden: $0.hidden, tagText: tagText[$0.key] ?? "")
            },
            options: request.options,
            threshold: request.highlightThreshold,
            layouts: layouts,
            profile: profile, tagStyle: style, tagImages: images)
        return try RenderSegmentCache.key(evidence, version: version + "/" + RenderSegmentCache.rendererVersion)
    }
}
