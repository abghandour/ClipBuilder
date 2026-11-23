import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Paused full-frame fast pan", .enabled(if: FixtureVideo.integrationsAvailable))
struct TelestratorFastPanRenderTests {
    private nonisolated struct Sample: Sendable {
        var frame: Int
        var marker: Double
        var bounded: Bool
    }

    @concurrent private static func source(_ url: URL, bars: Bool = false) async throws {
        // Full-width horizontal bits survive a horizontal pan. The white
        // marker is independent of those source-frame IDs.
        let bits = "geq=lum='if(lt(Y,256),32+192*mod(floor(N/pow(2,floor(Y/32))),2),80)':cb=128:cr=128"
        let edges = bars ? ",drawbox=x=0:y=0:w=200:h=1920:color=black:t=fill,drawbox=x=1960:y=0:w=200:h=1920:color=black:t=fill" : ""
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "nullsrc=s=2160x1920:r=30:d=1",
            "-vf", bits + ",drawbox=x=1100:y=800:w=40:h=320:color=white:t=fill" + edges,
            "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", url.path], timeout: 60)
    }

    @concurrent private static func samples(_ url: URL, folder: URL) async throws -> [Sample] {
        func strip(_ crop: String, name: String) async throws -> [UInt8] {
            let raw = folder.appendingPathComponent(UUID().uuidString + name + ".gray")
            defer { try? FileManager.default.removeItem(at: raw) }
            try await FFmpeg.run(["-y", "-i", url.path, "-an", "-vf", crop + ",format=gray",
                "-fps_mode", "passthrough", "-f", "rawvideo", raw.path], timeout: 60)
            return [UInt8](try Data(contentsOf: raw))
        }
        let row = try await strip("crop=1080:1:0:960:exact=1", name: "row")
        let column = try await strip("crop=1:1920:540:0:exact=1", name: "column")
        guard row.count.isMultiple(of: 1080), column.count == row.count / 1080 * 1920 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (0..<(row.count / 1080)).map { index in
            let pixels = row[(index * 1080)..<((index + 1) * 1080)]
            let vertical = column[(index * 1920)..<((index + 1) * 1920)]
            let frame = (0..<8).reduce(0) { value, bit in
                value | (column[index * 1920 + bit * 32 + 16] > 128 ? 1 << bit : 0)
            }
            var mass = 0.0, moment = 0.0
            for (x, value) in pixels.enumerated() {
                let weight = max(0, Double(value) - 120)
                mass += weight
                moment += Double(x) * weight
            }
            return Sample(frame: frame, marker: mass > 0 ? moment / mass : -.infinity,
                // The column is read below the frame-ID bands: their hard 32/224
                // edges ring down to black for a pixel or two after resampling.
                bounded: pixels.allSatisfy { $0 > 8 } && vertical.dropFirst(300).allSatisfy { $0 > 8 })
        }
    }

    @Test("A 100 px/frame pan matches the unpaused source frame, including a window")
    func fullAndWindow() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("fast-pan.mp4")
        try await Self.source(input)
        let path: [CameraPathKeyframe] = [
            .init(t: 0, x: 0.02, y: 0, w: 0.5, h: 1),
            .init(t: 0.2, x: 0.02, y: 0, w: 0.5, h: 1),
            .init(t: 0.5312, x: 0.48, y: 0, w: 0.5, h: 1),
            .init(t: 1, x: 0.48, y: 0, w: 0.5, h: 1)]
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        clip.videoFile = input.path
        clip.wide = true
        clip.centerStage = true
        clip.muted = true
        clip.captions = "none"
        var plain = Fixtures.timelineDocument(clips: [clip])
        plain.renderSettings = RenderSettings(preset: .portrait1080)
        plain.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 1)]
        var paused = plain
        paused.videoTrack = StrikeFreezeRules.pieces(clip, pauses: [.init(time: 0.4, duration: 0.4)])
        paused.cropBlocks[0].duration = 1.4
        plain.videoTrack[0].cameraPath = path
        let reference = try await StayRenderFixture.renderer(folder).render(document: plain, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: reference.url) }
        let expected = try await Self.samples(reference.url, folder: folder)
        try await CenterStageContinuity.$trackingOverride.withValue({ _, _, _ in
            FeedCameraPath(keyframes: path, samples: [], trackedShare: 1,
                sourceSize: CGSize(width: 2160, height: 1920), usedFallback: false)
        }) {
            for lower in [0.0, 0.3] {
                let window = MultitrackRenderer.windowed(paused, scenes: [], from: lower, to: 1.4)
                let output = try await StayRenderFixture.renderer(folder).render(document: window.document, scenes: [],
                    profile: Fixtures.brand(), database: temp.database, preview: true,
                    continuity: window.continuity, emit: { _ in })
                defer { try? FileManager.default.removeItem(at: output.url) }
                let actual = try await Self.samples(output.url, folder: folder)
                #expect(!actual.isEmpty)
                for sample in actual {
                    let baseline = try #require(expected.first { $0.frame == sample.frame })
                    #expect(sample.bounded)
                    // 1 px, plus the 3000 px/s pan over the 0.5 ms a seek time
                    // written with three decimals can be off (measured 1.00 to 1.01).
                    #expect(abs(sample.marker - baseline.marker) <= 2.5)
                }
            }
        }
    }
}
