import CoreGraphics
import Foundation

nonisolated enum LongRecordingClassifier {
    static func classify(frames: [VisionImageTagger.Signals], cutsPerMinute: Double, speechFraction: Double?) -> String? {
        guard frames.count == 5, cutsPerMinute.isFinite, cutsPerMinute >= 0 else { return nil }
        if cutsPerMinute > 12, frames.filter({ $0.textArea > 0 }).count >= 3 { return "recap" }
        guard cutsPerMinute < 3, let first = frames.first else { return nil }
        let count = first.faces.count
        guard count == 1 || count == 2, frames.allSatisfy({ $0.faces.count == count }) else { return nil }
        let baseline = first.faces.sorted { $0.midX < $1.midX }
        for frame in frames {
            let faces = frame.faces.sorted { $0.midX < $1.midX }
            guard zip(baseline, faces).allSatisfy({ abs($0.minX - $1.minX) <= 0.1 && abs($0.minY - $1.minY) <= 0.1 && abs($0.width - $1.width) <= 0.1 && abs($0.height - $1.height) <= 0.1 }) else { return nil }
        }
        if count == 2 { return "podcast" }
        return (speechFraction ?? 0) >= 0.8 ? "interview" : nil
    }
    static func splitFeed(_ frames: [VisionImageTagger.Signals]) -> Bool {
        frames.filter { frame in
            frame.faces.count == 2 && frame.faces.filter { $0.midX < 0.5 }.count == 1
        }.count > frames.count / 2
    }
}
