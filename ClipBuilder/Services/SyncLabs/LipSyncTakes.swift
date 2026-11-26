import Foundation

/// Lip sync takes: a lip-synced copy of one stretch of a source video, made
/// from the raw picture before any crop, camera, caption or overlay, at the
/// source's own speed and with the source's own sound. A take is a drop-in
/// for the source over its range: the renderer and the preview read pixels
/// from it and everything else (framing, captions, overlays, the dub mix)
/// happens afterwards as it always did. So a take survives every edit that
/// keeps its range and its dubbed lines: reordering, another camera, other
/// overlays or music. docs/Lip-Sync-Plan.md, "Takes (November 26, 2026)".
nonisolated enum LipSyncTakes {
    /// One dubbed line as Sync Labs hears it inside a take.
    struct Cue: Codable, Equatable, Sendable {
        /// A leaf name in the dubs cache.
        var audio: String
        /// Seconds from the start of the take's range.
        var offset: Double
        var stretch: Double
        /// How long the line is heard. Not in the key; tells a trimmed clip whether the line runs into it.
        var seconds: Double? = nil
        /// What is spoken, the same on every Mac. A paid take's cut file is
        /// named after its Drive upload too, which differs between teammates
        /// and changes on this Mac once the upload lands; this does not.
        var identity: String? = nil
        /// What the take's key and reuse compare.
        var spoken: String { identity ?? audio }

        /// Two cues are the same when the same speech sits at the same
        /// place; the local file's name and the measured length are not part of it.
        static func == (a: Cue, b: Cue) -> Bool {
            a.spoken == b.spoken && a.offset == b.offset && a.stretch == b.stretch
        }
    }

    /// What has to exist before a reel renders: one stretch of one source with its dubbed lines.
    struct Request: Equatable, Sendable {
        var sourcePath: String
        var sourceStart: Double
        var sourceEnd: Double
        var cues: [Cue]
        var seconds: Double { sourceEnd - sourceStart }
    }

    /// The sidecar beside a take's video; the pair is the whole record.
    struct Take: Codable, Equatable, Sendable {
        var key: String
        var sourcePath: String
        var sourceStart: Double
        var sourceEnd: Double
        var model: String
        var created: Date
        var cues: [Cue]
        /// The source's content when the take was made; a replaced recording no longer matches.
        var fingerprint: String?
        var seconds: Double { sourceEnd - sourceStart }
    }

    /// A take the current render may read from.
    struct Substitute: Equatable, Sendable {
        var sourcePath: String
        var sourceStart: Double
        var sourceEnd: Double
        var path: String
        var key: String
        /// The source second the take's first frame shows; the range above
        /// is only the part of the take this reel checked the lines of.
        var takeStart: Double
    }

    /// The takes this render reads pictures from. Set around the Wizard's cut
    /// extraction; empty everywhere else, where sources are read as they are.
    @TaskLocal static var current: [Substitute] = []

    /// Posted when a take is written, so lists and the preview read the folder again.
    static let changed = Notification.Name("LipSyncTakes.changed")

    /// Bump when the request Sync Labs receives changes in a way that changes the picture.
    static let version = "3"

    static var directory: URL {
        SettingsStore.cacheDirectory.appendingPathComponent("lip-sync", isDirectory: true)
    }

    static func video(_ key: String, in directory: URL = LipSyncTakes.directory) -> URL {
        directory.appendingPathComponent(key + ".mp4")
    }

    static func sidecar(_ key: String, in directory: URL = LipSyncTakes.directory) -> URL {
        directory.appendingPathComponent(key + ".json")
    }

    // MARK: Planning

    /// The stretches of source that carry dubbed speech in this document.
    /// Pieces of one kept clip (a pause splits a clip into a hold and its
    /// neighbours) are joined back into one stretch when they continue each
    /// other in the source, so a take covers the clip the user kept and not
    /// the way this reel happened to slice it.
    static func requests(document: TimelineDocument, sourcePath: (TimelineClip) -> String?) -> [Request] {
        let lines = document.dubLines ?? []
        guard document.dub?.enabled == true, !lines.isEmpty else { return [] }
        struct Run {
            var path: String
            var start: Double
            var end: Double
            var clips: Set<UUID>
            var origin: String
        }
        var runs: [Run] = []
        // Sped or slowed clips play their dub on the reel's clock, not the
        // source's, and clips with strike highlights are drawn on the source:
        // neither can read a take, so neither is paid for.
        let clips = document.videoTrack.filter {
            !$0.bumper && !$0.isCutaway && !$0.muted && $0.duration > 0
                && abs($0.effectiveSpeed - 1) < 0.0005 && $0.strikeHighlights != true
        }.sorted { $0.startTime < $1.startTime }
        let owners = Dictionary(clips.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for clip in clips {
            guard let path = sourcePath(clip), let start = clip.sourceStart, start.isFinite else { continue }
            let end = clip.hold == true ? start
                : min(clip.sourceEnd ?? .infinity, start + clip.duration * clip.effectiveSpeed)
            guard end.isFinite, end >= start else { continue }
            // Only pieces of one kept clip join: two kept clips that happen to
            // touch stay apart, so reordering them asks for the same takes.
            if let last = runs.indices.last, runs[last].path == path, runs[last].origin == clip.originKey,
               start >= runs[last].start - 0.001, start <= runs[last].end + 0.05 {
                runs[last].end = max(runs[last].end, end)
                runs[last].clips.insert(clip.uid)
            } else {
                runs.append(Run(path: path, start: start, end: end, clips: [clip.uid], origin: clip.originKey))
            }
        }
        return distinct(runs.compactMap { run -> Request? in
            guard run.end - run.start >= minimumSeconds else { return nil }
            var cues: [Cue] = []
            for line in lines where run.clips.contains(line.clipUID) {
                guard let audio = line.audio, let owner = owners[line.clipUID] else { continue }
                // Where the line is heard, in source seconds: the review may have moved it off its transcript time.
                let heard = (owner.sourceStart ?? line.sourceStart) + (line.start - owner.startTime) * owner.effectiveSpeed
                guard heard >= run.start - 0.001, heard < run.end else { continue }
                cues.append(Cue(audio: audio, offset: max(0, rounded(heard - run.start)), stretch: rounded(line.stretch),
                                seconds: rounded(max(0, line.duration) * owner.effectiveSpeed),
                                identity: line.takeID.map {
                                    DubTake.digest([$0, line.takeSource?.text ?? "", line.text, line.voice, String(rounded(line.sourceStart)),
                                                    String(rounded(line.sourceEnd)), String(line.rate)])
                                }))
            }
            cues.sort { ($0.offset, $0.spoken) < ($1.offset, $1.spoken) }
            guard !cues.isEmpty else { return nil }
            return Request(sourcePath: run.path, sourceStart: rounded(run.start), sourceEnd: rounded(run.end), cues: cues)
        })
    }

    /// A read is matched to a take by source and range alone. The same
    /// footage used twice with the same lines is one request; used twice
    /// with different lines no take can serve both, so neither is made.
    static func distinct(_ requests: [Request]) -> [Request] {
        var unique: [Request] = []
        for request in requests where !unique.contains(request) { unique.append(request) }
        return unique.filter { request in
            !unique.contains { other in
                other != request && other.sourcePath == request.sourcePath
                    && other.sourceStart < request.sourceEnd - 0.001 && request.sourceStart < other.sourceEnd - 0.001
            }
        }
    }

    /// A take on disk that already holds this request: same source and
    /// model, a range that covers it, and the same lines at the same places
    /// inside the request's range.
    static func covering(_ request: Request, fingerprint: String, model: LipSync.Model, in takes: [Take]) -> Take? {
        let path = URL(fileURLWithPath: request.sourcePath).standardizedFileURL.path
        return takes.first { take in
            guard take.fingerprint == fingerprint, take.model == model.rawValue,
                  URL(fileURLWithPath: take.sourcePath).standardizedFileURL.path == path,
                  take.sourceStart <= request.sourceStart + 0.002, take.sourceEnd >= request.sourceEnd - 0.002 else { return false }
            let shift = take.sourceStart - request.sourceStart
            let shifted = take.cues.map {
                Cue(audio: $0.audio, offset: rounded($0.offset + shift), stretch: $0.stretch, seconds: $0.seconds, identity: $0.identity)
            }
            // A line that starts before the request and is still heard inside it moves mouths the request has no line for.
            let runsIn = shifted.contains { cue in
                cue.offset < -0.002 && (cue.seconds.map { cue.offset + $0 > 0.05 } ?? true)
            }
            guard !runsIn else { return false }
            let inside = shifted.filter { $0.offset >= -0.002 && $0.offset < request.seconds }
            guard inside.count == request.cues.count else { return false }
            return zip(inside, request.cues).allSatisfy {
                $0.spoken == $1.spoken && abs($0.offset - $1.offset) < 0.003 && abs($0.stretch - $1.stretch) < 0.0015
            }
        }
    }

    /// Shorter stretches have no mouth movement worth paying for.
    static let minimumSeconds = 0.5

    /// Everything that changes the picture Sync Labs returns.
    static func key(_ request: Request, sourceFingerprint: String, model: LipSync.Model) -> String {
        DubTake.digest([version, sourceFingerprint, String(request.sourceStart), String(request.sourceEnd), model.rawValue]
            + request.cues.flatMap { [$0.spoken, String($0.offset), String($0.stretch)] })
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    // MARK: Lookup

    /// The take a read of `path` over `start ..< start + span` can come from: one that covers all of it.
    static func substitute(path: String, start: Double, span: Double, in takes: [Substitute] = current) -> Substitute? {
        guard !takes.isEmpty else { return nil }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return takes.first { take in
            URL(fileURLWithPath: take.sourcePath).standardizedFileURL.path == path
                && start >= take.sourceStart - 0.002 && start + max(0, span) <= take.sourceEnd + 0.05
        }
    }

    /// Every take on disk, newest first. A sidecar without its video is not a take.
    static func all(in directory: URL = LipSyncTakes.directory) -> [Take] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Take? in
            guard let data = try? Data(contentsOf: file), let take = try? decoder.decode(Take.self, from: data),
                  FileManager.default.fileExists(atPath: video(take.key, in: directory).path) else { return nil }
            return take
        }.sorted { $0.created > $1.created }
    }

    static func write(_ take: Take, in directory: URL = LipSyncTakes.directory) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(take).write(to: sidecar(take.key, in: directory), options: .atomic)
    }

    // MARK: Coverage

    /// How much of one kept clip already has lip-synced picture.
    struct Coverage: Equatable, Sendable {
        var synced: Double
        var total: Double
        /// The newest take that covers the whole clip, for the preview to play.
        var take: Take?

        var fraction: Double { total > 0 ? min(1, synced / total) : 0 }
        var isComplete: Bool { total > 0 && synced >= total - 0.05 }
        var isEmpty: Bool { synced < 0.05 }

        /// "Lip-synced", "Lip-synced 60%".
        var label: String? {
            if isEmpty { return nil }
            return isComplete ? "Lip-synced" : "Lip-synced \(Int((fraction * 100).rounded()))%"
        }
    }

    /// Takes are matched by source file and range only: a take made for an
    /// older wording of the dub still counts here, though a render would redo it.
    static func coverage(path: String, start: Double, end: Double, takes: [Take]) -> Coverage {
        let total = max(0, end - start)
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let mine = takes.filter { URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == path }
        var spans = mine.map { (max(start, $0.sourceStart), min(end, $0.sourceEnd)) }.filter { $0.1 > $0.0 }
        spans.sort { $0.0 < $1.0 }
        var synced = 0.0, cursor = start
        for span in spans {
            let from = max(cursor, span.0)
            if span.1 > from { synced += span.1 - from; cursor = span.1 }
        }
        let whole = mine.first { $0.sourceStart <= start + 0.002 && $0.sourceEnd >= end - 0.05 }
        return Coverage(synced: synced, total: total, take: whole)
    }

    /// "Lip sync: 3 of 5 clips ready · 42 s of 60 s", nil when nothing is synced yet.
    static func summary(_ clips: [Coverage]) -> String? {
        let ready = clips.filter(\.isComplete).count
        let synced = clips.reduce(0) { $0 + min($1.synced, $1.total) }
        let total = clips.reduce(0) { $0 + $1.total }
        guard synced >= 0.05, total > 0 else { return nil }
        return "Lip sync: \(ready) of \(clips.count) \(clips.count == 1 ? "clip" : "clips") ready · "
            + "\(Int(synced.rounded())) s of \(Int(total.rounded())) s"
    }

    // MARK: Media

    /// The raw stretch as Sync Labs sees it: full frame, no sound, re-encoded
    /// so its first frame is exactly the frame at `start`.
    static func pictureArguments(source: String, start: Double, seconds: Double, output: String, encoder: [String]) -> [String] {
        ["-y", "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", seconds), "-i", source,
         "-map", "0:v:0", "-an"] + encoder + [output]
    }

    /// The dubbed lines on silence at their places in the stretch: speech only, 16-bit WAV.
    static func speechArguments(cues: [(path: String, cue: Cue)], seconds: Double, output: String) -> [String] {
        var arguments = ["-y", "-f", "lavfi", "-t", String(format: "%.3f", seconds), "-i", "anullsrc=r=44100:cl=mono"]
        var filters: [String] = []
        var labels = ["[0:a]"]
        for (index, item) in cues.enumerated() {
            arguments += ["-i", item.path]
            let tempo = abs(item.cue.stretch - 1) > 0.0005 ? "atempo=\(DubPlanning.number(item.cue.stretch))," : ""
            let delay = Int((item.cue.offset * 1000).rounded())
            filters.append("[\(index + 1):a]\(tempo)aresample=44100,aformat=channel_layouts=mono,adelay=\(delay):all=1[c\(index)]")
            labels.append("[c\(index)]")
        }
        filters.append("\(labels.joined())amix=inputs=\(labels.count):duration=first:normalize=0[out]")
        return arguments + ["-filter_complex", filters.joined(separator: ";"), "-map", "[out]",
                            "-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le", output]
    }

    /// The synced picture with the stretch's own sound back under it, so the
    /// take stands in for the source in sound as well as picture.
    static func takeArguments(synced: String, source: String, start: Double, seconds: Double, output: String) -> [String] {
        ["-y", "-i", synced, "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", seconds), "-i", source,
         "-map", "0:v:0", "-map", "1:a:0?", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
         "-t", String(format: "%.3f", seconds), "-movflags", "+faststart", output]
    }
}
