import AVFoundation
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Media admission and cancellation", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable), .timeLimit(.minutes(1)))
struct MediaSchedulingTests {
    @Test func probesAndFrameDecodesProceedWhileCenterStageWaitsForFFmpeg() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await FixtureVideo.make(in: root, wide: true)
        let scheduler = MediaWorkScheduler(decoding: 2, encoding: 1)
        try await MediaWorkScheduler.$current.withValue(scheduler) {
            let progress = root.appendingPathComponent("ffmpeg-progress.txt")
            let ffmpeg = Task {
                try await FFmpeg.run([
                    "-v", "error", "-re", "-f", "lavfi", "-i", "color=s=64x64:r=30",
                    "-t", "30", "-stats_period", "0.05", "-progress", progress.path,
                    "-c:v", "libx264", root.appendingPathComponent("busy.mp4").path,
                ], timeout: 40)
            }
            defer { ffmpeg.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ((try? Data(contentsOf: progress).isEmpty) ?? true) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require((try? Data(contentsOf: progress).isEmpty) == false, "ffmpeg must report progress before testing contention")
            let export = Task {
                try await CenterStageService().reframeClip(source: source, start: 0, duration: 3,
                    path: [CameraPathKeyframe(t: 0, x: 0.34, y: 0, w: 0.32, h: 1),
                           CameraPathKeyframe(t: 3, x: 0.34, y: 0, w: 0.32, h: 1)])
            }
            defer { export.cancel() }
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 1)
            let probe = try await FFmpeg.probe(["-v", "error", "-show_entries", "format=duration", "-of", "json", source.path])
            #expect(probe.contains("duration"))
            let frame = await FFmpeg.jpegFrame(of: source, at: 0.5, maxDimension: 160)
            #expect(frame?.isEmpty == false)
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 1)
            ffmpeg.cancel()
            await #expect(throws: CancellationError.self) { try await ffmpeg.value }
            let output = try await export.value
            defer { try? FileManager.default.removeItem(at: output) }
            #expect(abs(await FFmpeg.duration(of: output) - 3) < 0.15)
            let dimensions = await FFmpeg.dimensions(of: output)
            #expect(dimensions.width == RenderEngine.outputWidth)
            #expect(dimensions.height == RenderEngine.outputHeight)
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 0, waiting: 0)
        }
    }

    @Test func queuedExportCancellationLeavesOutputUntouchedAndReleasesWaiter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await FixtureVideo.make(in: root)
        let output = root.appendingPathComponent("queued.mp4")
        let original = Data("existing output".utf8)
        try original.write(to: output)
        let scheduler = MediaWorkScheduler(encoding: 1)
        try await MediaWorkScheduler.$current.withValue(scheduler) {
            var held: MediaWorkScheduler.Permit? = try await scheduler.acquire(.encoding)
            #expect(held != nil)
            let export = Task {
                let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: source),
                                                                presetName: AVAssetExportPresetHighestQuality))
                try await MediaExport.run(session, to: output)
            }
            defer { export.cancel(); held = nil }
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 1)
            export.cancel()
            await #expect(throws: CancellationError.self) { try await export.value }
            #expect(try Data(contentsOf: output) == original)
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1, waiting: 0)
            held = nil
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 0, waiting: 0)
        }
    }

    @Test func runningExportCancellationDeletesPartialOutputBeforeReleasingCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await FixtureVideo.make(in: root, wide: true)
        let output = root.appendingPathComponent("cancelled.mp4")
        let scheduler = MediaWorkScheduler(encoding: 1)
        try await MediaWorkScheduler.$current.withValue(scheduler) {
            let export = Task {
                let asset = AVURLAsset(url: source)
                let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
                let composition = AVMutableComposition()
                let track = try #require(composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid))
                for index in 0..<40 {
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
                                              of: sourceTrack, at: CMTime(seconds: Double(index * 3), preferredTimescale: 600))
                }
                let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080))
                try await MediaExport.run(session, to: output)
            }
            defer { export.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !FileManager.default.fileExists(atPath: output.path) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(FileManager.default.fileExists(atPath: output.path), "Export must create output before cancellation")
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 1)
            export.cancel()
            await #expect(throws: CancellationError.self) { try await export.value }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            try await MediaSchedulingChecks.wait(scheduler, .encoding, active: 0, waiting: 0)
        }
    }
}
