import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

extension MultitrackRenderTests {
    @Test("blurred fill is deterministic across cold and warm caches and matches the preview at both seams")
    func blurredFillMatchesPreview() async throws {
        let temp = try TempDatabase()
        let png = temp.directory.url.appendingPathComponent("landscape.png")
        try FitTestImage.write(FitTestImage.source(), to: png)
        let source = temp.directory.url.appendingPathComponent("landscape.mp4")
        try await FFmpeg.run(["-y", "-loop", "1", "-i", png.path,
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "1",
            "-r", "30", "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        // Use the decoded input so input encoding isn't counted as a preview error.
        let inputFrame = temp.directory.url.appendingPathComponent("decoded-source.png")
        try await FFmpeg.run(["-y", "-i", source.path, "-frames:v", "1", inputFrame.path], timeout: 60)
        let sourceImage = try FitTestImage.read(inputFrame)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1)
        clip.videoFile = source.path
        clip.wide = true
        clip.captions = "none"
        clip.framingPlan = .static(window: nil, fit: .blurredFill, feather: 0.2, blur: 0.5)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 540, customHeight: 960)
        let cache = RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("warm-cache"))
        var outputs: [URL] = []
        defer { for output in outputs { try? FileManager.default.removeItem(at: output) } }
        for index in 0..<3 {
            // Two independent encodes, followed by a cache restore of the second.
            let selectedCache = index == 0
                ? RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cold-cache")) : cache
            let result = try await MultitrackRenderer(render: RenderEngine(), segmentCache: selectedCache).render(
                document: document, scenes: [], profile: Fixtures.brand(), database: temp.database,
                preview: true, emit: { _ in })
            outputs.append(result.url)
        }
        for output in outputs.dropFirst() {
            let comparison = try await Self.compareDecoded(output, outputs[0])
            #expect(comparison.videoTimingIdentical)
            #expect(!comparison.frameSSIM.isEmpty && comparison.minimumSSIM >= 0.98)
        }
        let exported = temp.directory.url.appendingPathComponent("export.png")
        try await FFmpeg.run(["-y", "-ss", "0.3", "-i", outputs[0].path, "-frames:v", "1", exported.path], timeout: 60)
        let exportedImage = try FitTestImage.read(exported)
        for y in [20, 940] {
            let pixel = try FitTestImage.pixel(exportedImage, x: 270, y: y)
            #expect(pixel.prefix(3).allSatisfy { $0 > 20 })
        }
        let spec = FitSpec(sourceSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            destination: CGRect(x: 0, y: 0, width: 540, height: 960), canvasSize: CGSize(width: 540, height: 960),
            fit: .blurredFill, feather: 0.2, blur: 0.5)
        let preview = temp.directory.url.appendingPathComponent("preview.png")
        try FitTestImage.write(FitTestImage.draw(sourceImage, spec: spec), to: preview)
        let seamHeight = Int(spec.featherPixels) + 16
        let regions = [CGRect(x: 0, y: 0, width: 540, height: 960),
            CGRect(x: 0, y: Int(spec.foreground.minY) - 8, width: 540, height: seamHeight),
            CGRect(x: 0, y: Int(spec.foreground.maxY) - seamHeight + 8, width: 540, height: seamHeight)]
        for (index, region) in regions.enumerated() {
            let stats = temp.directory.url.appendingPathComponent("fit-ssim-\(index).log")
            let crop = "crop=\(Int(region.width)):\(Int(region.height)):\(Int(region.minX)):\(Int(region.minY)),format=yuv420p"
            try await FFmpeg.run(["-v", "error", "-i", preview.path, "-i", exported.path,
                "-filter_complex", "[0:v]\(crop)[a];[1:v]\(crop)[b];[a][b]ssim=stats_file=\(stats.path)",
                "-frames:v", "1", "-f", "null", "-"], timeout: 60)
            let line = try String(contentsOf: stats, encoding: .utf8)
            let start = try #require(line.range(of: "All:"))
            let ssim = try #require(Double(line[start.upperBound...].prefix { "0123456789.".contains($0) }))
            #expect(ssim >= (index == 0 ? 0.98 : 0.95))
        }
    }
}

extension MultitrackRenderTests {
    // Serialized: six concurrent ffmpeg graphs hold the encoding permits long enough to
    // starve other suites' ffmpeg calls past their time limits when the whole suite runs.
    @Test("fit graphs render aspect, feather and blur endpoints at two resolutions", .serialized, arguments: 0..<6)
    func fitGraphGeometryMatrix(_ index: Int) async throws {
        let directory = try TempDirectory()
        let source = directory.url.appendingPathComponent("source.png")
        try FitTestImage.write(FitTestImage.source(), to: source)
        let widths = [540, 1080, 540, 540, 540, 540]
        let heights = [960, 1920, 960, 960, 960, 960]
        let sizes = [CGSize(width: 960, height: 540), CGSize(width: 960, height: 540),
            CGSize(width: 540, height: 960), CGSize(width: 320, height: 960),
            CGSize(width: 540, height: 540), CGSize(width: 960, height: 540)]
        let width = widths[index], height = heights[index]
        let destination = index == 5 ? CGRect(x: 40, y: 80, width: 120, height: 240)
            : CGRect(x: 0, y: 0, width: width, height: height)
        let spec = FitSpec(sourceSize: sizes[index], destination: destination,
            canvasSize: CGSize(width: width, height: height), fit: .blurredFill,
            feather: index.isMultiple(of: 2) ? 0 : 0.2, blur: index.isMultiple(of: 2) ? 0 : 1)
        var inputs: [URL] = []
        let graph = try FitComposer.graph(spec, inputLabel: "source", outputLabel: "out", extraInputs: &inputs)
        var args = ["-y", "-i", source.path]
        for input in inputs { args += ["-threads", "1", "-loop", "1", "-i", input.path] }
        let output = directory.url.appendingPathComponent("fit.png")
        args += ["-filter_complex", "[0:v]scale=\(Int(sizes[index].width)):\(Int(sizes[index].height)),setsar=1[source];" + graph,
            "-map", "[out]", "-frames:v", "1", output.path]
        try await FFmpeg.run(args, timeout: 60)
        let result = try FitTestImage.read(output)
        #expect(result.width == width && result.height == height)
        for point in [CGPoint(x: destination.midX, y: destination.minY + 4),
                      CGPoint(x: destination.midX, y: destination.maxY - 4),
                      CGPoint(x: destination.minX + 4, y: destination.midY),
                      CGPoint(x: destination.maxX - 4, y: destination.midY)] {
            #expect(try FitTestImage.pixel(result, x: Int(point.x), y: Int(point.y)).prefix(3).allSatisfy { $0 > 20 })
        }
    }

    @Test("podcast extraction strips baked bars without changing source clocks; nil keeps the source")
    func podcastFitStripsBakedBars() async throws {
        let temp = try TempDatabase()
        let source = temp.directory.url.appendingPathComponent("bars.mp4")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "color=c=0x80a0c0:s=640x360:r=30",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-vf", "pad=640:640:0:140:black",
            "-t", "2", "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path], timeout: 60)
        let render = RenderEngine()
        let box = try #require(await render.detectContentBox(source: source, start: 0.5, duration: 1))
        #expect(box.y > 0.2 && box.h < 0.6)
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0.5, duration: 1)
        clip.videoFile = source.path
        clip.framingPlan = .static(window: nil, fit: .blurredFill, feather: 0, blur: 0.5)
        var document = Fixtures.timelineDocument(clips: [clip])
        document.renderSettings = RenderSettings(preset: .custom, customWidth: 360, customHeight: 640)
        let output = temp.directory.url.appendingPathComponent("stripped.mp4")
        try await ExpressPodcastRenderer.extract(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, render: render, camera: "balanced", overlays: [], look: nil, mute: false,
            clipNumber: 1, duration: 1, output: output, contentSource: source, contentBox: box,
            cache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")), emit: { _ in })
        let frame = temp.directory.url.appendingPathComponent("stripped.png")
        try await FFmpeg.run(["-y", "-ss", "0.3", "-i", output.path, "-frames:v", "1", frame.path], timeout: 60)
        let image = try FitTestImage.read(frame)
        for y in [20, 620] {
            #expect(try FitTestImage.pixel(image, x: 180, y: y).prefix(3).allSatisfy { $0 > 30 })
        }
        #expect(await render.detectContentBox(source: output, start: 0, duration: 1) == nil)
        let noStrip = temp.directory.url.appendingPathComponent("no-strip.mp4")
        try await ExpressPodcastRenderer.extract(document: document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, render: render, camera: "balanced", overlays: [], look: nil, mute: false,
            clipNumber: 1, duration: 1, output: noStrip, contentSource: source, contentBox: nil,
            cache: RenderSegmentCache(directory: temp.directory.url.appendingPathComponent("cache")), emit: { _ in })
        #expect(await render.detectContentBox(source: noStrip, start: 0, duration: 1) != nil)
        #expect(document.videoTrack[0].sourceStart == 0.5)
    }
}
