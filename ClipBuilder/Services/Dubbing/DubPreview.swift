import AVFoundation
import Foundation

/// Build a short source-video composition off the main actor; playback is explicitly user initiated.
nonisolated enum DubPreview {
    @concurrent
    static func item(for line: DubLine, prepared: DubPreparation.Prepared) async throws -> sending AVPlayerItem {
        guard let clip = DubPreparation.playbackClip(for: line, document: prepared.document),
              let path = clip.videoFile, let sourceStart = clip.sourceStart else {
            throw ScriptError.invalid("The source clip for this line is unavailable.")
        }
        guard let audio = line.audio, audio == URL(fileURLWithPath: audio).lastPathComponent,
              FileManager.default.fileExists(atPath: DubSynthesizer.cacheDirectory.appendingPathComponent(audio).path) else {
            throw ScriptError.invalid("The dub audio is missing. Use Update line to prepare it again.")
        }
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: URL(fileURLWithPath: path))
        let speech = AVURLAsset(url: DubSynthesizer.cacheDirectory.appendingPathComponent(audio))
        let start = sourceStart + (line.start - clip.startTime) * clip.effectiveSpeed
        let assetDuration = try await source.load(.duration).seconds
        let sourceSeconds = min(max(0, assetDuration - start), line.duration * clip.effectiveSpeed)
        guard sourceSeconds > 0 else { throw ScriptError.invalid("The source clip has no video at this line.") }
        let sourceRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: sourceSeconds, preferredTimescale: 600))
        let shownDuration = CMTime(seconds: sourceSeconds / clip.effectiveSpeed, preferredTimescale: 600)
        guard let video = try await source.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScriptError.invalid("The source video is unavailable.")
        }
        try videoTrack.insertTimeRange(sourceRange, of: video, at: .zero)
        videoTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration), toDuration: shownDuration)
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        var parameters: [AVAudioMixInputParameters] = []
        if let original = try await source.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(sourceRange, of: original, at: .zero)
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration), toDuration: shownDuration)
            let volume = AVMutableAudioMixInputParameters(track: track)
            volume.setVolume(prepared.settings.replaceOriginal ? 0 : Float(prepared.settings.originalLevel), at: .zero)
            parameters.append(volume)
        }
        guard let dub = try await speech.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScriptError.invalid("The dub audio could not be opened. Use Update line to prepare it again.")
        }
        let duration = try await speech.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: dub, at: .zero)
        track.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                             toDuration: CMTime(seconds: duration.seconds / line.stretch, preferredTimescale: 600))
        let item = AVPlayerItem(asset: composition)
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        item.audioMix = mix
        item.audioTimePitchAlgorithm = .spectral
        try Task.checkCancellation()
        return item
    }
}
