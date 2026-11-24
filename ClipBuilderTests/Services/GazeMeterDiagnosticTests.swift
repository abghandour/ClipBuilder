import Foundation
import Testing
@testable import Clip_Builder

/// Measures a real recording. Runs only when GAZE_VIDEO names a file
/// (`TEST_RUNNER_GAZE_VIDEO=<path> scripts/test.sh -only-testing:ClipBuilderTests/GazeMeterDiagnosticTests`);
/// writes its reading to GAZE_OUT, or the temporary directory.
@Suite("Gaze meter on real footage")
struct GazeMeterDiagnosticTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GAZE_VIDEO"] != nil))
    func measure() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(environment["GAZE_VIDEO"]))
        let end = Double(environment["GAZE_END"] ?? "") ?? 30
        let started = Date()
        let samples = try await GazeMeter.measure(url: url, range: 0...end)
        let seconds = Date().timeIntervalSince(started)
        let spans = GazeMeter.spans(samples)
        var lines = [String(format: "%d samples in %.1f s; away %.0f%%", samples.count, seconds,
                            GazeMeter.share(spans, of: 0...end) * 100)]
        lines += spans.map { String(format: "%.1f-%.1f %@", $0.start, $0.end, $0.kind.rawValue) }
        lines += samples.map { String(format: "%.2f yaw %.0f pitch %.0f px %@ py %@ w %.0f", $0.time, $0.yaw, $0.pitch,
                                      $0.pupilX.map { String(format: "%.2f", $0) } ?? "-",
                                      $0.pupilY.map { String(format: "%.2f", $0) } ?? "-", $0.faceWidth) }
        let out = environment["GAZE_OUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gaze-diagnostic.txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        #expect(!samples.isEmpty)
    }
}
