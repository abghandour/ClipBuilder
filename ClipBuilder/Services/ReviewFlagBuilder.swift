import Foundation
import Synchronization

/// One moment of a rendered reel the pipeline was unsure about, so the
/// editor can jump straight to it in the Builder instead of rewatching the
/// export. Stored on the generated video as `review_flags_json`.
nonisolated struct ReviewFlag: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case unnamedSpeaker
        case lowConfidenceSpeaker
        case framingFallback
        case noTrackingPath
        case qualityWarning
    }

    enum Severity: String, Codable, Sendable {
        case info
        case warning
    }

    /// Stable: derived from kind, clip origin, time and a discriminator.
    var id: String
    var kind: Kind
    /// Output (timeline) seconds.
    var time: Double
    var endTime: Double?
    var clipOriginKey: String?
    var severity: Severity
    var message: String

    init(id: String, kind: Kind, time: Double, endTime: Double? = nil,
         clipOriginKey: String? = nil, severity: Severity, message: String) {
        self.id = id
        self.kind = kind
        self.time = time
        self.endTime = endTime
        self.clipOriginKey = clipOriginKey
        self.severity = severity
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, time, endTime, clipOriginKey, severity, message
    }

    /// Every field is optional on disk so older or partial JSON keeps loading;
    /// an unknown kind or severity reads as a generic quality note.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }
            .flatMap(Kind.init(rawValue:)) ?? .qualityWarning
        time = (try? container.decodeIfPresent(Double.self, forKey: .time)).flatMap { $0 } ?? 0
        endTime = (try? container.decodeIfPresent(Double.self, forKey: .endTime)).flatMap { $0 }
        clipOriginKey = (try? container.decodeIfPresent(String.self, forKey: .clipOriginKey)).flatMap { $0 }
        severity = (try? container.decodeIfPresent(String.self, forKey: .severity)).flatMap { $0 }
            .flatMap(Severity.init(rawValue:)) ?? .info
        message = (try? container.decodeIfPresent(String.self, forKey: .message)).flatMap { $0 } ?? ""
        id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 }
            ?? ReviewFlagBuilder.flagID(kind: kind, origin: clipOriginKey, time: time, detail: message)
    }
}

/// A clip whose tracking camera failed or fell back to a static crop during
/// a render. `startTime` is in the rendered document's timeline; the source
/// fields let a caller that rendered a sub-document (one wizard cut) map it
/// back onto the full document.
nonisolated struct RenderFramingFallback: Codable, Sendable, Hashable {
    var clipOriginKey: String?
    var startTime: Double
    var reason: String
    var sourcePath: String? = nil
    var sourceStart: Double? = nil
}

/// Collects framing fallbacks from every render that runs while it is the
/// task-local `current` (child tasks inherit it), so callers whose renders
/// are nested several layers deep need not thread a result through.
nonisolated final class RenderFramingFallbackCollector: Sendable {
    @TaskLocal static var current: RenderFramingFallbackCollector?

    private let items = Mutex<[RenderFramingFallback]>([])

    init() {}

    func record(_ fallbacks: [RenderFramingFallback]) {
        guard !fallbacks.isEmpty else { return }
        items.withLock { $0.append(contentsOf: fallbacks) }
    }

    var all: [RenderFramingFallback] { items.withLock { $0 } }
}

nonisolated enum ReviewFlagBuilder {
    /// Below this, neither the voice nor the picture evidence names the
    /// speaker with any confidence.
    static let lowConfidence = 0.5
    /// Consecutive turns of one speaker closer than this merge into one flag.
    static let mergeGap = 1.0

    static func flags(document: TimelineDocument, scenes: [Int64: SceneRecord],
                      turns: [SpeakerTurn], quality: ReelQualityReport?,
                      renderFallbacks: [RenderFramingFallback]) -> [ReviewFlag] {
        var flags: [ReviewFlag] = []
        let videoIDByPath = Dictionary(scenes.values.map { ($0.videoPath, $0.videoID) },
                                       uniquingKeysWith: { first, _ in first })
        let turnsByVideo = Dictionary(grouping: turns, by: \.videoID)
        let main = document.videoTrack
            .filter { $0.track == 0 && !$0.isCutaway && !$0.bumper }
            .sorted { $0.startTime < $1.startTime }

        // Speakers.
        for clip in main {
            guard let sourceStart = clip.sourceStart, clip.duration > 0 else { continue }
            let speed = clip.speed ?? 1
            guard speed > 0 else { continue }
            let sourceEnd = clip.sourceEnd ?? (sourceStart + clip.duration * speed)
            let videoID = clip.sceneID.flatMap { scenes[$0]?.videoID }
                ?? clip.videoFile.flatMap { videoIDByPath[$0] }
            guard let videoID, let videoTurns = turnsByVideo[videoID] else { continue }
            let clipEnd = clip.startTime + clip.duration
            func output(_ source: Double) -> Double {
                min(clipEnd, max(clip.startTime, clip.startTime + (source - sourceStart) / speed))
            }
            var pending: (kind: ReviewFlag.Kind, cluster: Int, start: Double, end: Double,
                          confidence: Double)?
            func flush() {
                guard let run = pending else { return }
                pending = nil
                let time = output(run.start)
                let end = output(run.end)
                guard end > time else { return }
                let speaker = "Speaker \(run.cluster + 1)"
                let message = run.kind == .unnamedSpeaker
                    ? "\(speaker) is not named; captions and name tags may be wrong."
                    : "\(speaker)'s identity is uncertain (\(Int((run.confidence * 100).rounded()))% confidence)."
                flags.append(ReviewFlag(
                    id: flagID(kind: run.kind, origin: clip.originKey, time: time, detail: "\(run.cluster)"),
                    kind: run.kind, time: time, endTime: end, clipOriginKey: clip.originKey,
                    severity: run.kind == .unnamedSpeaker ? .warning : .info, message: message))
            }
            for turn in videoTurns.sorted(by: { $0.start < $1.start })
            where turn.start < sourceEnd && turn.end > sourceStart {
                let confidence = max(turn.confidence, turn.pictureConfidence)
                let kind: ReviewFlag.Kind
                if turn.personKey == nil {
                    kind = .unnamedSpeaker
                } else if confidence < lowConfidence {
                    kind = .lowConfidenceSpeaker
                } else {
                    flush()
                    continue
                }
                if let run = pending, run.kind == kind, run.cluster == turn.cluster,
                   turn.start - run.end <= mergeGap {
                    pending = (kind, turn.cluster, run.start, max(run.end, turn.end),
                               min(run.confidence, confidence))
                } else {
                    flush()
                    pending = (kind, turn.cluster, max(turn.start, sourceStart), min(turn.end, sourceEnd), confidence)
                }
            }
            flush()
        }

        // Wide scenes that fit portrait poorly and were never tracked.
        for clip in document.videoTrack where !clip.bumper && !clip.isCutaway {
            guard let sceneID = clip.sceneID, let scene = scenes[sceneID], scene.wide,
                  scene.tags.contains("portrait-fit:poor"),
                  scene.centerStagePathJSON?.isEmpty != false,
                  clip.cameraPath?.isEmpty != false else { continue }
            flags.append(ReviewFlag(
                id: flagID(kind: .noTrackingPath, origin: clip.originKey, time: clip.startTime, detail: ""),
                kind: .noTrackingPath, time: clip.startTime, endTime: clip.startTime + clip.duration,
                clipOriginKey: clip.originKey, severity: .info,
                message: "Wide shot with a poor portrait fit and no tracking path; check who is in frame."))
        }

        // Framing that fell back to a static crop during the render.
        for fallback in renderFallbacks {
            let owner = fallback.clipOriginKey.flatMap { key in
                Self.fallbackOwner(fallback, among: document.videoTrack.filter { $0.originKey == key })
            } ?? document.videoTrack.first {
                !$0.isCutaway && fallback.startTime >= $0.startTime - 0.001
                    && fallback.startTime < $0.startTime + $0.duration
            }
            let time = owner?.startTime ?? max(0, fallback.startTime)
            let origin = owner?.originKey ?? fallback.clipOriginKey
            let reason = fallback.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            flags.append(ReviewFlag(
                id: flagID(kind: .framingFallback, origin: origin, time: time, detail: ""),
                kind: .framingFallback, time: time, endTime: owner.map { $0.startTime + $0.duration },
                clipOriginKey: origin, severity: .warning,
                message: "Framing fell back to the static crop" + (reason.isEmpty ? "." : ": \(reason)")))
        }

        // Quality-gate notes apply to the whole reel.
        if let quality {
            for failure in quality.failures {
                flags.append(ReviewFlag(id: flagID(kind: .qualityWarning, origin: nil, time: 0, detail: failure),
                                        kind: .qualityWarning, time: 0, severity: .warning, message: failure))
            }
            for warning in quality.warnings {
                flags.append(ReviewFlag(id: flagID(kind: .qualityWarning, origin: nil, time: 0, detail: warning),
                                        kind: .qualityWarning, time: 0, severity: .info, message: warning))
            }
        }

        var seen: Set<String> = []
        return flags
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if abs(lhs.time - rhs.time) > 0.0005 { return lhs.time < rhs.time }
                if lhs.severity != rhs.severity { return lhs.severity == .warning }
                return lhs.id < rhs.id
            }
    }

    /// The clip a fallback belongs to among the pieces of one origin (a clip
    /// split by cuts keeps its origin key): the piece whose source range
    /// holds the fallback's source start, else the one whose timeline range
    /// holds its time, else the earliest.
    static func fallbackOwner(_ fallback: RenderFramingFallback, among pieces: [TimelineClip]) -> TimelineClip? {
        let ordered = pieces.sorted { $0.startTime < $1.startTime }
        if let start = fallback.sourceStart, let piece = ordered.first(where: { clip in
            guard let sourceStart = clip.sourceStart,
                  fallback.sourcePath == nil || clip.videoFile == nil || clip.videoFile == fallback.sourcePath
            else { return false }
            return start >= sourceStart - 0.05 && start < sourceStart + clip.sourceSpan
        }) {
            return piece
        }
        if let piece = ordered.first(where: {
            fallback.startTime >= $0.startTime - 0.001 && fallback.startTime < $0.startTime + $0.duration
        }) {
            return piece
        }
        return ordered.first
    }

    /// Fallbacks recorded while rendering a sub-document (one wizard cut)
    /// carry that sub-document's clock and origin keys. Re-anchor each on
    /// the full document's clip with the same source file and start.
    static func anchored(_ fallbacks: [RenderFramingFallback],
                         in document: TimelineDocument) -> [RenderFramingFallback] {
        fallbacks.map { fallback in
            guard let path = fallback.sourcePath, let start = fallback.sourceStart,
                  let clip = document.videoTrack
                    .filter({ $0.videoFile == path && abs(($0.sourceStart ?? -1) - start) < 0.05 })
                    .min(by: { $0.startTime < $1.startTime }) else { return fallback }
            var anchored = fallback
            anchored.clipOriginKey = clip.originKey
            anchored.startTime = clip.startTime
            return anchored
        }
    }

    static func encode(_ flags: [ReviewFlag]) -> String? {
        guard !flags.isEmpty, let data = try? JSONEncoder().encode(flags) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [ReviewFlag] {
        guard let data = json?.data(using: .utf8),
              let flags = try? JSONDecoder().decode([ReviewFlag].self, from: data) else { return [] }
        return flags
    }

    static func flagID(kind: ReviewFlag.Kind, origin: String?, time: Double, detail: String) -> String {
        let base = "\(kind.rawValue)|\(origin ?? "-")|\(String(format: "%.2f", time))"
        return detail.isEmpty ? base : "\(base)|\(detail)"
    }

    /// "1:05" style label for a flag's time.
    static func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
