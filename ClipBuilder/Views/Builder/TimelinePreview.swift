import SwiftUI
import AVFoundation

/// Instant timeline playback without rendering: the video track is assembled
/// into an AVMutableComposition (clip audio + music via an AVAudioMix) and
/// played directly. Layout-affecting features the FFmpeg pipeline burns in —
/// crops, slot bands, captions, text overlays, transitions, intro/outro —
/// are not applied here; the render remains the source of truth.

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
        var boundaries = Set<Double>()
        for clip in clips {
            boundaries.insert(clip.startTime)
            boundaries.insert(clip.startTime + clip.duration)
        }
        let sorted = boundaries.sorted()

        var segments: [PreviewSegment] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end - start > 0.01 {
            let midpoint = (start + end) / 2
            let active = clips.filter { $0.startTime <= midpoint && midpoint < $0.startTime + $0.duration }
            guard let top = active.max(by: { ($0.track, $0.stackOrder) < ($1.track, $1.stackOrder) }),
                  let url = sourceURL(for: top) else { continue }
            let trackMuted = document.trackSettings[safe: top.track]?.muted ?? false
            let gain = (top.muted || trackMuted) ? 0.0 : Double(top.volume) / 5.0
            segments.append(PreviewSegment(url: url,
                                           sourceStart: (top.sourceStart ?? 0) + (start - top.startTime),
                                           timelineStart: start,
                                           duration: end - start,
                                           volume: gain))
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
            Image(systemName: "play.circle.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(hovering ? 0.75 : 0.55))
                .shadow(color: .black.opacity(0.4), radius: 6)
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play the timeline instantly without rendering")
    }
}

/// Modal live preview of the current timeline. Starts from the playhead.
struct TimelinePreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Timeline Preview")
                    .font(.headline)
                Text("Approximate — crops, captions, text and transitions appear only in the final render")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Group {
                if let player {
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
        .task {
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
                self.player = player
            } catch {
                failure = "Could not build the preview: \(error.localizedDescription)"
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
