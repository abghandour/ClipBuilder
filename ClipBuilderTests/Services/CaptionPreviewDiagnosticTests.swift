import AppKit
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Times the Text Looks caption preview for one real style, for judging
/// preview speed against the same look. Off unless
/// CLIPBUILDER_CAPTION_PREVIEW_STYLE names a JSON file holding one entry of
/// a profile's `caption_styles`; the report goes to
/// CLIPBUILDER_CAPTION_PREVIEW_REPORT (default: beside the style file).
@Suite("Caption preview diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_CAPTION_PREVIEW_STYLE"] != nil))
struct CaptionPreviewDiagnosticTests {
    @Test("time the preview of one caption style", .timeLimit(.minutes(10)))
    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["CLIPBUILDER_CAPTION_PREVIEW_STYLE"])
        let reportPath = environment["CLIPBUILDER_CAPTION_PREVIEW_REPORT"] ?? path + ".report.txt"
        let named = try JSONDecoder().decode(NamedCaptionStyle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let style = named.style
        var lines = ["style: \(named.name)"]
        func seconds(_ body: () throws -> Void) rethrows -> Double {
            let started = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - started
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        for pass in 1...3 {
            var frames: [CaptionPreviewImage] = []
            let began = ContinuousClock.now
            let lead = Mutex<Double?>(nil)
            let frameTime = try seconds {
                frames = try CaptionPreviewImage.frames(style: style, leadTime: 0.3) { _ in
                    let elapsed = ContinuousClock.now - began
                    lead.withLock { $0 = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 }
                }
            }
            var states: [CaptionPreviewImage.WordState] = []
            let stateTime = try seconds { states = try CaptionPreviewImage.wordStates(style: style) }
            let unique = Set(frames.map(\.data)).count
            let bytes = frames.reduce(0) { $0 + $1.data.count }
            let decodeTime = seconds {
                for frame in frames { _ = NSImage(data: frame.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            }
            lines.append(String(format: "pass %d: first frame %.3f s, all frames %.3f s (%d overlays, %d distinct images, %.1f MB PNG, largest %dx%d), word states %.3f s (%d), decode %.3f s",
                                pass, lead.withLock { $0 } ?? -1, frameTime, frames.count, unique, Double(bytes) / 1_048_576,
                                Int(frames.map(\.size.width).max() ?? 0), Int(frames.map(\.size.height).max() ?? 0),
                                stateTime, states.count, decodeTime))
        }
        try lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}
