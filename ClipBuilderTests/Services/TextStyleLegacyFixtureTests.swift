import Foundation
import Testing
@testable import Clip_Builder

struct TextStyleLegacyFixtureTests {
    nonisolated static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/TextStyle")
    }

    @Test(arguments: ["Boxed", "Karaoke", "Hormozi"])
    func legacyPresetSSIM(_ name: String) async throws {
        try await Task.detached {
            let root = Self.fixtures
            let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let image = try CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
                .render(text: "Every moment has a story", activeIndex: 1, emphasis: [3], to: scratch)
            let process = Process()
            process.executableURL = try #require(ProcessRunner.locate("ffmpeg"))
            process.arguments = ["-i", root.appendingPathComponent(name + ".png").path,
                                 "-i", image.pngURL.path, "-lavfi", "ssim", "-f", "null", "-"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let value = log.components(separatedBy: "All:").last?.split(separator: " ").first.flatMap { Double($0) }
            #expect(try #require(value) >= 0.99)
        }.value
    }
}
