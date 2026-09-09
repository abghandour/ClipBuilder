import Foundation
import Testing
@testable import Clip_Builder

struct LongRecordingClassifierTests {
    @Test func rules() {
        let one = VisionImageTagger.Signals(labels: [:], faces: [CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)], textArea: 0)
        let frames = Array(repeating: one, count: 5)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 1, speechFraction: nil) == nil)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 1, speechFraction: 0.9) == "interview")
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 13, speechFraction: 0.9) == nil)
        #expect(LongRecordingClassifier.classify(frames: [], cutsPerMinute: 0, speechFraction: 1) == nil)
    }
}

extension LongRecordingClassifierTests {
    private static func signals(faces: [CGRect], textArea: Double = 0) -> VisionImageTagger.Signals {
        .init(labels: [:], faces: faces, textArea: textArea)
    }
    @Test func twoStableFacesArePodcast() {
        let pair = [CGRect(x: 0.1, y: 0.3, width: 0.15, height: 0.2), CGRect(x: 0.7, y: 0.3, width: 0.15, height: 0.2)]
        let frames = Array(repeating: Self.signals(faces: pair), count: 5)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 0.5, speechFraction: nil) == "podcast")
        // Order of detection per frame must not matter.
        var shuffled = frames
        shuffled[2] = Self.signals(faces: pair.reversed())
        #expect(LongRecordingClassifier.classify(frames: shuffled, cutsPerMinute: 0.5, speechFraction: nil) == "podcast")
    }
    @Test func driftingOrMismatchedFacesAskTheModel() {
        let face = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
        var frames = Array(repeating: Self.signals(faces: [face]), count: 5)
        frames[3] = Self.signals(faces: [face.offsetBy(dx: 0.3, dy: 0)])
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 1, speechFraction: 0.9) == nil)
        frames[3] = Self.signals(faces: [face, face.offsetBy(dx: 0.5, dy: 0)])
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 1, speechFraction: 0.9) == nil)
        frames[3] = Self.signals(faces: [])
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 1, speechFraction: 0.9) == nil)
    }
    @Test func recapNeedsFastCutsAndOnScreenText() {
        let text = Self.signals(faces: [], textArea: 0.1)
        let plain = Self.signals(faces: [])
        #expect(LongRecordingClassifier.classify(frames: [text, text, text, plain, plain], cutsPerMinute: 13, speechFraction: nil) == "recap")
        #expect(LongRecordingClassifier.classify(frames: [text, text, plain, plain, plain], cutsPerMinute: 13, speechFraction: nil) == nil)
        #expect(LongRecordingClassifier.classify(frames: [text, text, text, plain, plain], cutsPerMinute: 12, speechFraction: nil) == nil)
    }
    @Test func middlingCutRateAndBadInputsAskTheModel() {
        let face = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
        let frames = Array(repeating: Self.signals(faces: [face]), count: 5)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: 5, speechFraction: 1) == nil)
        #expect(LongRecordingClassifier.classify(frames: Array(frames.prefix(4)), cutsPerMinute: 1, speechFraction: 1) == nil)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: .infinity, speechFraction: 1) == nil)
        #expect(LongRecordingClassifier.classify(frames: frames, cutsPerMinute: .nan, speechFraction: 1) == nil)
    }
}
