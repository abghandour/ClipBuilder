import AVFoundation
import CoreML
import Foundation
import Synchronization

/// Voice embeddings from the bundled ECAPA-TDNN model (SpeechBrain,
/// Apache-2.0, converted to Core ML; see SpeakerEmbedding-NOTICE.txt): a
/// unit-length 192-dimensional vector per window of speech that puts the
/// same voice close together and different voices apart, far better than
/// the spectral averages `SpeakerFeatures` falls back to. Runs on-device.
nonisolated enum SpeakerEmbedder {
    static let dimension = 192
    /// The model's audio format; the normalized audio cache already is.
    static let sampleRate = 16_000.0
    /// One embedding per this many seconds of speech, stepping by half —
    /// longer than the spectral windows because the model needs a couple
    /// of seconds of voice to be sure.
    static let windowSeconds = 2.0
    static let windowStep = 0.5
    static let minimumSeconds = 1.0

    private static let cached = Mutex<Result<MLModel, Error>?>(nil)

    /// The compiled model, loaded once; nil when the bundle lacks it or
    /// Core ML cannot load it on this Mac.
    static func model() -> MLModel? {
        cached.withLock { slot in
            if slot == nil {
                slot = Result {
                    guard let url = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .all
                    return try MLModel(contentsOf: url, configuration: configuration)
                }
            }
            return try? slot?.get()
        }
    }

    static var isAvailable: Bool { model() != nil }

    /// A unit-length embedding of 16 kHz mono samples.
    static func embed(_ samples: [Float]) throws -> [Double] {
        guard let model = model() else { throw ScriptError.invalid("The speaker embedding model is not available.") }
        let array = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        samples.withUnsafeBufferPointer { source in
            let destination = array.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw ScriptError.invalid("The speaker embedding model returned nothing.")
        }
        var vector = (0..<embedding.count).map { Double(truncating: embedding[$0]) }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-9 { vector = vector.map { $0 / norm } }
        return vector
    }

    /// Embedding windows over the speech ranges of a 16 kHz mono file —
    /// the same shape `SpeakerFeatures.windows` produces, so the tracker
    /// takes either.
    static func windows(audioURL: URL, speech: [ClosedRange<Double>]) throws -> [SpeakerFeatures.Window] {
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        guard abs(rate - sampleRate) < 1, file.processingFormat.channelCount >= 1 else {
            throw ScriptError.invalid("Speaker embeddings need 16 kHz audio; got \(Int(rate)) Hz.")
        }
        // Speech ranges come from the transcript and can overrun the audio
        // by a few frames: clamp to what the file holds.
        let length = Double(file.length) / rate
        var result: [SpeakerFeatures.Window] = []
        for range in speech {
            var start = range.lowerBound
            let upper = min(range.upperBound, length)
            while start + minimumSeconds <= upper {
                let end = min(upper, start + windowSeconds)
                let frames = AVAudioFrameCount(((end - start) * rate).rounded())
                guard frames >= AVAudioFrameCount(minimumSeconds * rate),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                file.framePosition = AVAudioFramePosition((start * rate).rounded())
                try file.read(into: buffer, frameCount: frames)
                guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { break }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                result.append(SpeakerFeatures.Window(start: start, end: end, vector: try embed(samples)))
                if end >= upper { break }
                start += windowStep
            }
        }
        return result
    }
}
