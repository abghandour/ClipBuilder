import SwiftUI
import AVFoundation

/// Instant timeline playback without rendering: the video track is assembled
/// into an AVMutableComposition (clip audio + music via an AVAudioMix) and
/// played directly. Layout-affecting features the FFmpeg pipeline burns in —
/// crops, slot bands, captions, text overlays, transitions — are not applied
/// here. The sheet below offers an exact render when those details matter.

/// One non-overlapping stretch of timeline mapped to a source file range.
nonisolated struct PreviewSegment: Sendable {
    var url: URL
    var sourceStart: Double
    var timelineStart: Double
    var duration: Double
    var volume: Double          // 0-1 gain for the clip's own audio
    var bumper: Bool = false
    var speed: Double = 1
    /// Dialogue that is not the picture's own: the main clip playing under
    /// a cutaway. Entirely independent of the picture — its own file,
    /// offset, speed and gain, clamped to its own length. When set it takes
    /// the dialogue track instead of the picture's audio.
    var audio: AudioSource?
    /// A mixed-in cutaway's own sound. It plays beside the dialogue, so it
    /// gets a track of its own — two concurrent sounds never share one.
    var cutawayAudio: AudioSource?

    nonisolated struct AudioSource: Sendable, Equatable {
        var url: URL
        var sourceStart: Double
        var volume: Double
        var speed: Double = 1
    }
}

nonisolated struct PreviewMusicBlock: Sendable {
    var url: URL
    var timelineStart: Double
    var duration: Double
    var volume: Double
    /// Where in the song this block starts: nonzero for the pieces left
    /// after a bumper cuts a block, so the song continues rather than restarts.
    var sourceOffset: Double = 0
}

nonisolated enum PreviewError: Error, CustomStringConvertible {
    case compositionFailed

    var description: String { "Could not create the preview composition" }
}

/// Everything a preview player item is made of, built off the main actor.
/// `AVPlayerItem` itself is main-actor bound in the current SDK, so the
/// composer hands this back and the item is created on the main actor.
nonisolated struct PreviewComposition {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition?
    var audioMix: AVMutableAudioMix
    /// Source assets whose Drive leases the item must keep alive.
    var sources: [AVURLAsset]
}

nonisolated enum TimelinePreviewComposer {
    /// Build a playable item from resolved segments. The composition work
    /// runs off the main actor; only the item itself is created on it.
    @MainActor
    static func makePlayerItem(segments: [PreviewSegment],
                               music: [PreviewMusicBlock],
                               settings: RenderSettings = RenderSettings()) async throws -> sending AVPlayerItem {
        let built = try await makeComposition(segments: segments, music: music, settings: settings)
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        DriveLocalAsset.retainSources(built.sources, on: item)
        item.audioMix = built.audioMix
        return item
    }

    /// Assets are loaded once per distinct source file; ranges are clamped
    /// to what the file holds.
    @concurrent
    static func makeComposition(segments: [PreviewSegment],
                                music: [PreviewMusicBlock],
                                settings: RenderSettings = RenderSettings()) async throws -> sending PreviewComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let clipAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PreviewError.compositionFailed
        }

        let fitsCanvas = segments.contains(where: \.bumper)
        let canvas = CGSize(width: Double(settings.width), height: Double(settings.height))
        var instructions: [AVMutableVideoCompositionInstruction] = []
        func instruction(start: CMTime, duration: CMTime,
                         transform: CGAffineTransform? = nil) {
            guard fitsCanvas, duration.seconds > 0 else { return }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start, duration: duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            if let transform {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layer.setTransform(transform, at: start)
                instruction.layerInstructions = [layer]
            } else {
                instruction.layerInstructions = []
            }
            instructions.append(instruction)
        }
        var assets: [URL: AVURLAsset] = [:]
        func asset(for url: URL) async throws -> AVURLAsset {
            try await DriveMediaResolver.shared.ensureLocal(url)
            if let existing = assets[url] { return existing }
            let created = try await DriveLocalAsset.make(url)
            assets[url] = created
            return created
        }
        func time(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        let clipAudioParams = AVMutableAudioMixInputParameters(track: clipAudioTrack)
        // Track B: a mixed-in cutaway's own sound, which plays at the same
        // time as the dialogue on track A. Only created when some segment
        // asks for it; the video instructions never reference it, so it is
        // purely additive.
        var extraAudioTrack: AVMutableCompositionTrack?
        var extraAudioParams: AVMutableAudioMixInputParameters?
        if segments.contains(where: { $0.cutawayAudio != nil }),
           let track = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            extraAudioTrack = track
            extraAudioParams = AVMutableAudioMixInputParameters(track: track)
        }
        var videoCursor = CMTime.zero
        var audioCursor = CMTime.zero
        var extraCursor = CMTime.zero

        for segment in segments {
            if segment.bumper && !FileManager.default.fileExists(atPath: segment.url.path) {
                let end = time(segment.timelineStart + segment.duration)
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: videoCursor, end: end))
                clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: audioCursor, end: end))
                instruction(start: videoCursor, duration: end - videoCursor)
                videoCursor = end
                audioCursor = end
                continue
            }
            let source = try await asset(for: segment.url)
            let sourceDuration = (try? await source.load(.duration).seconds) ?? segment.duration
            let clamped = min(segment.duration * segment.speed, max(0, sourceDuration - segment.sourceStart))
            // A picture that has run out of source still holds its place:
            // the dialogue underneath a cutaway must keep playing.
            let hasPicture = clamped > 0.01
            let start = time(segment.timelineStart)
            let range = CMTimeRange(start: time(segment.sourceStart), duration: time(max(0.001, clamped)))
            let screenDuration = hasPicture ? time(clamped / segment.speed) : time(segment.duration)

            // Composition tracks must stay contiguous — fill timeline gaps.
            if start > videoCursor {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: videoCursor, end: start))
                instruction(start: videoCursor, duration: start - videoCursor)
            }
            if hasPicture, let sourceVideo = try await source.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: start)
                if fitsCanvas {
                    let natural = try await sourceVideo.load(.naturalSize)
                    let preferred = try await sourceVideo.load(.preferredTransform)
                    let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
                    let scale = min(canvas.width / max(1, bounds.width), canvas.height / max(1, bounds.height))
                    let transform = preferred
                        .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(translationX: (canvas.width - bounds.width * scale) / 2,
                                                       y: (canvas.height - bounds.height * scale) / 2))
                    instruction(start: start, duration: screenDuration, transform: transform)
                } else if videoTrack.preferredTransform == .identity {
                    videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                }
            } else {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: screenDuration))
                instruction(start: start, duration: screenDuration)
            }
            if hasPicture {
                videoTrack.scaleTimeRange(CMTimeRange(start: start, duration: range.duration),
                                          toDuration: screenDuration)
            }
            videoCursor = start + screenDuration

            if start > audioCursor {
                clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: audioCursor, end: start))
            }
            if let dialogue = segment.audio {
                // The clip under a cutaway keeps talking: its own file, its
                // own offset and speed, clamped against its own length.
                let voiceAsset = try await asset(for: dialogue.url)
                let voiceLength = (try? await voiceAsset.load(.duration).seconds) ?? segment.duration
                let voiceClamped = min(segment.duration * dialogue.speed,
                                       max(0, voiceLength - dialogue.sourceStart))
                let voiceRange = CMTimeRange(start: time(dialogue.sourceStart), duration: time(voiceClamped))
                let voiceScreen = time(voiceClamped / dialogue.speed)
                if voiceClamped > 0.01, dialogue.volume > 0,
                   let voice = try? await voiceAsset.loadTracks(withMediaType: .audio).first {
                    try clipAudioTrack.insertTimeRange(voiceRange, of: voice, at: start)
                    clipAudioParams.setVolume(Float(dialogue.volume), at: start)
                    clipAudioTrack.scaleTimeRange(CMTimeRange(start: start, duration: voiceRange.duration),
                                                  toDuration: voiceScreen)
                    audioCursor = start + voiceScreen
                } else {
                    clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: screenDuration))
                    clipAudioParams.setVolume(0, at: start)
                    audioCursor = start + screenDuration
                }
            } else if hasPicture, segment.volume > 0,
                      let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first {
                try clipAudioTrack.insertTimeRange(range, of: sourceAudio, at: start)
                clipAudioParams.setVolume(Float(segment.volume), at: start)
                clipAudioTrack.scaleTimeRange(CMTimeRange(start: start, duration: range.duration),
                                              toDuration: screenDuration)
                audioCursor = start + screenDuration
            } else {
                clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: screenDuration))
                clipAudioParams.setVolume(Float(hasPicture ? segment.volume : 0), at: start)
                audioCursor = start + screenDuration
            }

            if let extraAudioTrack, let extraAudioParams, let extra = segment.cutawayAudio {
                if start > extraCursor {
                    extraAudioTrack.insertEmptyTimeRange(CMTimeRange(start: extraCursor, end: start))
                }
                // Clamped against ITS OWN file, never the picture's range.
                let extraAsset = try await asset(for: extra.url)
                let extraDuration = (try? await extraAsset.load(.duration).seconds) ?? segment.duration
                let extraClamped = min(segment.duration * extra.speed,
                                       max(0, extraDuration - extra.sourceStart))
                if extraClamped > 0.01, extra.volume > 0,
                   let extraSource = try? await extraAsset.loadTracks(withMediaType: .audio).first {
                    let extraRange = CMTimeRange(start: time(extra.sourceStart), duration: time(extraClamped))
                    try extraAudioTrack.insertTimeRange(extraRange, of: extraSource, at: start)
                    extraAudioParams.setVolume(Float(extra.volume), at: start)
                    let extraScreen = time(extraClamped / extra.speed)
                    extraAudioTrack.scaleTimeRange(CMTimeRange(start: start, duration: extraRange.duration),
                                                   toDuration: extraScreen)
                    extraCursor = start + extraScreen
                }
            }
        }

        var mixParameters = [clipAudioParams]
        if let extraAudioParams { mixParameters.append(extraAudioParams) }
        if !music.isEmpty,
           let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
            var cursor = CMTime.zero
            for block in music {
                let source = try await asset(for: block.url)
                guard let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first else { continue }
                let sourceDuration = (try? await source.load(.duration).seconds) ?? block.duration
                // Overlapping blocks: start where the previous one ended.
                let start = max(block.timelineStart, cursor.seconds)
                let sourceStart = block.sourceOffset + (start - block.timelineStart)
                let clamped = min(block.duration - (start - block.timelineStart), sourceDuration - sourceStart)
                guard clamped > 0.01 else { continue }
                if time(start) > cursor {
                    musicTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: time(start)))
                }
                try musicTrack.insertTimeRange(
                    CMTimeRange(start: time(sourceStart), duration: time(clamped)),
                    of: sourceAudio, at: time(start))
                musicParams.setVolume(Float(block.volume), at: time(start))
                cursor = time(start + clamped)
            }
            mixParameters.append(musicParams)
        }

        var videoComposition: AVMutableVideoComposition?
        if fitsCanvas {
            let fitted = AVMutableVideoComposition()
            fitted.renderSize = canvas
            fitted.frameDuration = CMTime(value: 1, timescale: 30)
            fitted.instructions = instructions
            videoComposition = fitted
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        return PreviewComposition(composition: composition, videoComposition: videoComposition,
                                  audioMix: mix, sources: Array(assets.values))
    }
}

extension BuilderTimelineModel {
    /// Flatten the multi-track document into non-overlapping preview segments:
    /// at each instant the top-most clip wins, matching PreviewPane's draw
    /// order (highest track, then stack order).
    /// - Parameter musicLookup: track name → file; nil reads the Music library.
    func previewPlan(musicLookup: [String: URL]? = nil) -> (segments: [PreviewSegment], music: [PreviewMusicBlock]) {
        let clips = document.videoTrack
        typealias Candidate = (clip: TimelineClip, index: Int, end: Double)

        // Max-heap by the same draw priority the old per-interval scan used.
        // Expired entries are removed lazily when they reach the root, so
        // every clip enters and leaves the heap at most once.
        // The renderer's draw order (MultitrackRenderer.placementLayer):
        // a bumper above everything, then a cover-all cutaway, then a
        // track's cutaways above its main clips, then the higher track.
        func layer(_ clip: TimelineClip) -> Int {
            if clip.bumper { return TimelineDocument.maxTracks * 2 + 2 }
            if clip.isCutaway {
                return clip.coverAllAreas
                    ? TimelineDocument.maxTracks * 2 + 1
                    : clip.track * 2 + 1
            }
            return clip.track * 2
        }
        func outranks(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            let left = layer(lhs.clip), right = layer(rhs.clip)
            if left != right { return left > right }
            if lhs.clip.startTime != rhs.clip.startTime { return lhs.clip.startTime > rhs.clip.startTime }
            if lhs.clip.originKey != rhs.clip.originKey { return lhs.clip.originKey > rhs.clip.originKey }
            // Same as the renderer's last tie-break: later in the document
            // means drawn later, which means on top.
            return lhs.index > rhs.index
        }
        // Two segments only merge when the dialogue under them continues
        // too — a cut in the underlying clip must survive one long cutaway.
        func audioContinues(_ previous: PreviewSegment.AudioSource?,
                            with next: PreviewSegment.AudioSource?,
                            over duration: Double) -> Bool {
            switch (previous, next) {
            case (nil, nil): return true
            case let (previous?, next?):
                return previous.url == next.url && previous.volume == next.volume
                    && previous.speed == next.speed
                    && abs(previous.sourceStart + duration * previous.speed - next.sourceStart) < 0.001
            default: return false
            }
        }

        var heap: [Candidate] = []
        heap.reserveCapacity(clips.count)
        func insert(_ candidate: Candidate) {
            heap.append(candidate)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard outranks(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }
        @discardableResult
        func removeHighest() -> Candidate? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let highest = heap[0]
            heap[0] = heap.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let child = right < heap.count && outranks(heap[right], heap[left]) ? right : left
                guard outranks(heap[child], heap[parent]) else { break }
                heap.swapAt(parent, child)
                parent = child
            }
            return highest
        }

        var boundaries = Set<Double>()
        for clip in clips {
            boundaries.insert(clip.startTime)
            boundaries.insert(clip.startTime + clip.duration)
        }
        let sorted = boundaries.sorted()
        let starts = clips.enumerated().sorted {
            $0.element.startTime == $1.element.startTime
                ? $0.offset < $1.offset
                : $0.element.startTime < $1.element.startTime
        }
        var nextStart = 0

        var segments: [PreviewSegment] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end - start > 0.01 {
            while nextStart < starts.count, starts[nextStart].element.startTime <= start + 0.001 {
                let item = starts[nextStart]
                insert((item.element, item.offset, item.element.startTime + item.element.duration))
                nextStart += 1
            }
            while let highest = heap.first, highest.end <= start + 0.001 {
                removeHighest()
            }
            // The top clip decides the picture — unless its file is gone,
            // in which case the next one down takes over so the dialogue
            // under a cutaway is not lost with it.
            guard let leader = heap.first?.clip else { continue }
            // A clip whose file has been deleted cannot show a picture, so
            // the clip below takes over and its dialogue is still heard.
            // Two exceptions: a bumper owns its span outright even when its
            // file is missing (the render shows black and stays silent),
            // and Drive-backed footage is fetched on demand, so a file that
            // is simply not local yet keeps its place.
            func playable(_ clip: TimelineClip) -> URL? {
                guard let url = sourceURL(for: clip) else { return nil }
                if FileManager.default.fileExists(atPath: url.path) { return url }
                return driveBackedPaths.contains(url.path) ? url : nil
            }
            var top = leader
            var url = sourceURL(for: leader)
            if !leader.bumper, playable(leader) == nil {
                var best: Candidate?
                for candidate in heap where candidate.end > start + 0.001
                    && candidate.clip.startTime <= start + 0.001
                    && !candidate.clip.bumper
                    && playable(candidate.clip) != nil {
                    if best == nil || outranks(candidate, best!) { best = candidate }
                }
                if let best, let fallback = playable(best.clip) {
                    top = best.clip
                    url = fallback
                }
            }
            guard let url else { continue }
            let trackMuted = document.trackSettings[safe: top.track]?.muted ?? false
            let ownGain = (top.muted || trackMuted) ? 0.0 : Double(top.volume) / 5.0
            let sourceStart = (top.sourceStart ?? 0) + (start - top.startTime) * top.effectiveSpeed

            // B-roll only replaces the picture: the clip underneath keeps
            // its sound, on an audio source of its own (its file, its
            // offset, its speed — never derived from the picture's range).
            // A mixed-in cutaway's own sound plays beside it, on track B.
            var gain = ownGain
            var audio: PreviewSegment.AudioSource?
            var cutawayAudio: PreviewSegment.AudioSource?
            if top.isCutaway {
                gain = 0
                if ownGain > 0 {
                    cutawayAudio = PreviewSegment.AudioSource(url: url, sourceStart: sourceStart,
                                                              volume: ownGain, speed: top.effectiveSpeed)
                }
                var best: Candidate?
                for candidate in heap where candidate.end > start + 0.001 {
                    let clip = candidate.clip
                    guard !clip.bumper, clip.role == .main, clip.track == top.track,
                          clip.startTime <= start + 0.001, !clip.muted,
                          !(document.trackSettings[safe: clip.track]?.muted ?? false) else { continue }
                    if best == nil || outranks(candidate, best!) { best = candidate }
                }
                if let best, let audioURL = sourceURL(for: best.clip) {
                    audio = PreviewSegment.AudioSource(
                        url: audioURL,
                        sourceStart: (best.clip.sourceStart ?? 0)
                            + (start - best.clip.startTime) * best.clip.effectiveSpeed,
                        volume: Double(best.clip.volume) / 5.0,
                        speed: best.clip.effectiveSpeed)
                }
            }
            if let lastIndex = segments.indices.last,
               segments[lastIndex].url == url,
               abs(segments[lastIndex].timelineStart + segments[lastIndex].duration - start) < 0.001,
               abs(segments[lastIndex].sourceStart + segments[lastIndex].duration * top.effectiveSpeed - sourceStart) < 0.001,
               segments[lastIndex].volume == gain,
               segments[lastIndex].speed == top.effectiveSpeed, segments[lastIndex].bumper == top.bumper,
               audioContinues(segments[lastIndex].audio, with: audio,
                              over: segments[lastIndex].duration),
               audioContinues(segments[lastIndex].cutawayAudio, with: cutawayAudio,
                              over: segments[lastIndex].duration) {
                segments[lastIndex].duration += end - start
            } else {
                segments.append(PreviewSegment(url: url,
                                               sourceStart: sourceStart,
                                               timelineStart: start,
                                               duration: end - start,
                                               volume: gain, bumper: top.bumper, speed: top.effectiveSpeed,
                                               audio: audio, cutawayAudio: cutawayAudio))
            }
        }

        let musicLookup = musicLookup ?? Dictionary(uniqueKeysWithValues:
            WizardEngine.availableMusic().map { ($0.name, $0.url) })
        let bumperSpans = document.bumperSpans
        let music = document.soundTrack
            .sorted { $0.startTime < $1.startTime }
            .flatMap { item -> [PreviewMusicBlock] in
                guard let url = musicLookup[item.name], item.duration > 0 else { return [] }
                // Silent under bumpers, like the final render; each remaining
                // piece keeps its place in the song.
                return TimelineDocument.subtracting(bumperSpans, from: item.startTime..<(item.startTime + item.duration))
                    .map { PreviewMusicBlock(url: url,
                                             timelineStart: $0.lowerBound,
                                             duration: $0.upperBound - $0.lowerBound,
                                             volume: Double(item.volume) / 5.0 * 0.7,
                                             sourceOffset: $0.lowerBound - item.startTime) }
            }
        return (segments, music)
    }
}

/// Video-player-style play affordance overlaid on the poster-frame preview —
/// the primary way to preview the timeline without rendering it.
struct PreviewPlayButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Play Fast Preview", systemImage: "play.circle.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(hovering ? 0.75 : 0.55))
                .shadow(color: .black.opacity(0.4), radius: 6)
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play a fast, approximate timeline preview")
    }
}

/// Modal preview of the current timeline. Fast Preview starts immediately;
/// Render Preview uses the final multitrack pipeline and never files a video
/// in the Library.
struct TimelinePreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable {
        case fast
        case exact
    }

    @State private var fastPlayer: AVPlayer?
    @State private var exactPlayer: AVPlayer?
    @State private var exactPreviewURL: URL?
    @State private var exactPreviewTask: Task<Void, Never>?
    @State private var mode: Mode = .fast
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if let player = activePlayer {
                    PlayerView(player: player)
                } else if let failure {
                    ContentUnavailableView("Preview Unavailable",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Preparing preview…")
                }
            }
            .frame(minWidth: 430, minHeight: 620)

            if mode == .fast, store.builder.document.videoTrack.contains(where: \.isCutaway) {
                Text("Fast preview shows one picture at a time, not B-roll inside its area. "
                     + "It keeps the dialogue under B-roll. Check areas in Exact preview or the render.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spaceL)
                    .padding(.vertical, Theme.spaceS)
            }
        }
        .modalCloseButton { dismiss() }
        .task {
            await prepareFastPreview()
        }
        .onChange(of: mode) { _, newMode in
            // Both players outlive the view swap; only the visible one plays.
            switch newMode {
            case .fast:
                exactPlayer?.pause()
                fastPlayer?.play()
            case .exact:
                fastPlayer?.pause()
                exactPlayer?.play()
            }
        }
        .onDisappear {
            fastPlayer?.pause()
            exactPlayer?.pause()
            exactPreviewTask?.cancel()
            if let exactPreviewURL { try? FileManager.default.removeItem(at: exactPreviewURL) }
        }
    }

    private var activePlayer: AVPlayer? {
        switch mode {
        case .fast: fastPlayer
        case .exact: exactPlayer
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Timeline Preview")
                    .font(.headline)
                Label(mode == .exact
                      ? "Render Preview — final fidelity"
                      : "Fast Preview — approximate",
                      systemImage: mode == .exact ? "checkmark.seal.fill" : "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mode == .exact ? .green : .secondary)
                Text(mode == .exact
                     ? "This file matches the final render, including framing, captions, transitions, music, and overlays."
                     : "Fast Preview skips framing, captions, text, transitions, and overlay templates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                if exactPreviewURL != nil {
                    Picker("Preview fidelity", selection: $mode) {
                        Text("Fast").tag(Mode.fast)
                        Text("Final").tag(Mode.exact)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)
                }
                Button {
                    renderExactPreview()
                } label: {
                    if store.isBuilderPreviewRendering {
                        Label("Rendering…", systemImage: "hourglass")
                    } else {
                        Label(exactPreviewURL == nil ? "Render Preview" : "Render Again",
                              systemImage: "checkmark.seal")
                    }
                }
                .controlSize(.small)
                .disabled(store.isBuilderPreviewRendering || store.isBuilderRendering)
                .help(store.isBuilderRendering
                      ? "Wait for the Library render to finish."
                      : "Render an exact temporary preview. Nothing is added to the Library.")
                Button("Done") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func prepareFastPreview() async {
        let model = store.builder
        let plan = model.previewPlan()
        guard !plan.segments.isEmpty else {
            failure = "Add clips to the timeline first."
            return
        }
        do {
            let item = try await TimelinePreviewComposer.makePlayerItem(segments: plan.segments,
                                                                        music: plan.music, settings: model.document.renderSettings)
            let player = AVPlayer(playerItem: item)
            let playhead = model.playhead
            if playhead > 0.1 && playhead < model.totalDuration - 0.1 {
                await player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600))
            }
            player.play()
            fastPlayer = player
        } catch {
            failure = "Could not build the preview: \(error.localizedDescription)"
        }
    }

    private func renderExactPreview() {
        exactPreviewTask?.cancel()
        exactPreviewTask = Task {
            guard let url = await store.renderBuilderExactPreview() else { return }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            if let exactPreviewURL { try? FileManager.default.removeItem(at: exactPreviewURL) }
            exactPreviewURL = url
            exactPlayer?.pause()
            fastPlayer?.pause()
            let player = AVPlayer(url: url)
            exactPlayer = player
            mode = .exact
            player.play()
        }
    }
}
