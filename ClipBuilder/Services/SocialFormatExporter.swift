import Foundation

actor SocialFormatExporter {
    func exportVideo(source: URL, settings: RenderSettings, destination: URL) async throws {
        try await RenderContext.$settings.withValue(settings) {
            let filter =
                "scale=\(settings.width):\(settings.height):force_original_aspect_ratio=increase,"
                + "crop=\(settings.width):\(settings.height),setsar=1,fps=30"
            try await FFmpeg.run(
                ["-y", "-i", source.path, "-vf", filter]
                    + FFmpeg.encodeArgs + [destination.path], timeout: 900)
        }
    }

    func exportCarousel(
        source: URL, duration: Double, directory: URL,
        count: Int = 5
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [URL] = []
        let safeDuration = max(0.1, duration)
        for index in 0..<count {
            let fraction = count == 1 ? 0.5 : 0.05 + 0.9 * Double(index) / Double(count - 1)
            let time = safeDuration * fraction
            let output = directory.appendingPathComponent("slide-\(index + 1).jpg")
            try await FFmpeg.run(
                [
                    "-y", "-ss", String(format: "%.3f", time), "-i", source.path,
                    "-frames:v", "1", "-vf",
                    "scale=1080:1080:force_original_aspect_ratio=increase,crop=1080:1080",
                    "-q:v", "2", output.path,
                ], timeout: 120)
            results.append(output)
        }
        return results
    }
}
