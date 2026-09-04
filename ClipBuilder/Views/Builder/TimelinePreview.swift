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
}

nonisolated struct PreviewMusicBlock: Sendable {
    var url: URL
    var timelineStart: Double
    var duration: Double
    var volume: Double
}

nonisolated enum PreviewError: Error, CustomStringConvertible {
    case compositionFailed

    var description: String { "Could not create the preview composition" }
}

nonisolated enum TimelinePreviewComposer {
    /// Build a playable item from resolved segments. Assets are loaded once
    /// per distinct source file; ranges are clamped to what the file holds.
    static func makePlayerItem(segments: [PreviewSegment],
                               music: [PreviewMusicBlock]) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let clipAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PreviewError.compositionFailed
        }

        var assets: [URL: AVURLAsset] = [:]
        func asset(for url: URL) -> AVURLAsset {
            if let existing = assets[url] { return existing }
            let created = AVURLAsset(url: url)
            assets[url] = created
            return created
        }
        func time(_ seconds: Double) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        let clipAudioParams = AVMutableAudioMixInputParameters(track: clipAudioTrack)
        var videoCursor = CMTime.zero
        var audioCursor = CMTime.zero

        for segment in segments {
            let source = asset(for: segment.url)
            let sourceDuration = (try? await source.load(.duration).seconds) ?? segment.duration
            let clamped = min(segment.duration, max(0, sourceDuration - segment.sourceStart))
            guard clamped > 0.01 else { continue }
            let start = time(segment.timelineStart)
            let range = CMTimeRange(start: time(segment.sourceStart), duration: time(clamped))

            // Composition tracks must stay contiguous — fill timeline gaps.
            if start > videoCursor {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: videoCursor, end: start))
            }
            if let sourceVideo = try await source.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: start)
                if videoTrack.preferredTransform == .identity {
                    videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                }
            } else {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: range.duration))
            }
            videoCursor = start + range.duration

            if start > audioCursor {
                clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: audioCursor, end: start))
            }
            if segment.volume > 0,
               let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first {
                try clipAudioTrack.insertTimeRange(range, of: sourceAudio, at: start)
            } else {
                clipAudioTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: range.duration))
            }
            clipAudioParams.setVolume(Float(segment.volume), at: start)
            audioCursor = start + range.duration
        }

        var mixParameters = [clipAudioParams]
        if !music.isEmpty,
           let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
            var cursor = CMTime.zero
            for block in music {
                let source = asset(for: block.url)
                guard let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first else { continue }
                let sourceDuration = (try? await source.load(.duration).seconds) ?? block.duration
                // Overlapping blocks: start where the previous one ended.
                let start = max(block.timelineStart, cursor.seconds)
                let clamped = min(block.duration - (start - block.timelineStart), sourceDuration)
                guard clamped > 0.01 else { continue }
                if time(start) > cursor {
                    musicTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: time(start)))
                }
                try musicTrack.insertTimeRange(
                    CMTimeRange(start: time(start - block.timelineStart), duration: time(clamped)),
                    of: sourceAudio, at: time(start))
                musicParams.setVolume(Float(block.volume), at: time(start))
                cursor = time(start + clamped)
            }
            mixParameters.append(musicParams)
        }

        let item = AVPlayerItem(asset: composition)
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        item.audioMix = mix
        return item
    }
}

extension BuilderTimelineModel {
    /// Flatten the multi-track document into non-overlapping preview segments:
    /// at each instant the top-most clip wins, matching PreviewPane's draw
    /// order (highest track, then stack order).
    func previewPlan() -> (segments: [PreviewSegment], music: [PreviewMusicBlock]) {
        let clips = document.videoTrack
        typealias Candidate = (clip: TimelineClip, index: Int, end: Double)

        // Max-heap by the same draw priority the old per-interval scan used.
        // Expired entries are removed lazily when they reach the root, so
        // every clip enters and leaves the heap at most once.
        func outranks(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.clip.track != rhs.clip.track { return lhs.clip.track > rhs.clip.track }
            if lhs.clip.startTime != rhs.clip.startTime { return lhs.clip.startTime > rhs.clip.startTime }
            return lhs.index < rhs.index
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
            guard let top = heap.first?.clip, let url = sourceURL(for: top) else { continue }
            let trackMuted = document.trackSettings[safe: top.track]?.muted ?? false
            let gain = (top.muted || trackMuted) ? 0.0 : Double(top.volume) / 5.0
            let sourceStart = (top.sourceStart ?? 0) + (start - top.startTime)
            if let lastIndex = segments.indices.last,
               segments[lastIndex].url == url,
               abs(segments[lastIndex].timelineStart + segments[lastIndex].duration - start) < 0.001,
               abs(segments[lastIndex].sourceStart + segments[lastIndex].duration - sourceStart) < 0.001,
               segments[lastIndex].volume == gain {
                segments[lastIndex].duration += end - start
            } else {
                segments.append(PreviewSegment(url: url,
                                               sourceStart: sourceStart,
                                               timelineStart: start,
                                               duration: end - start,
                                               volume: gain))
            }
        }

        let musicLookup = Dictionary(uniqueKeysWithValues:
            WizardEngine.availableMusic().map { ($0.name, $0.url) })
        let music = document.soundTrack
            .sorted { $0.startTime < $1.startTime }
            .compactMap { item -> PreviewMusicBlock? in
                guard let url = musicLookup[item.name] else { return nil }
                return PreviewMusicBlock(url: url,
                                         timelineStart: item.startTime,
                                         duration: item.duration,
                                         volume: Double(item.volume) / 5.0 * 0.7)
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
                                                                        music: plan.music)
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
