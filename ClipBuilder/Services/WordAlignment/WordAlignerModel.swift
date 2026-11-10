import AVFoundation
import Accelerate
import CoreML
import CryptoKit
import Foundation

nonisolated enum WordAlignerError: Error, CustomStringConvertible {
    case notInstalled
    case downloadFailed(String)
    case corrupt(String)
    case unsupportedAudio(String)

    var description: String {
        switch self {
        case .notInstalled: "The precise word timing model is not installed on this Mac"
        case .downloadFailed(let reason): "Could not download the word timing model: \(reason)"
        case .corrupt(let reason): "The word timing model is damaged: \(reason)"
        case .unsupportedAudio(let reason): "Word timing needs 16 kHz mono audio: \(reason)"
        }
    }
}

/// How a transcript's words get their times.
nonisolated enum WordTiming: String, Sendable, CaseIterable, Identifiable {
    /// The recognizer's own times.
    case recognizer
    /// Re-timed against the audio by the word aligner, where one exists for
    /// the language and is installed.
    case precise

    var id: String { rawValue }
    var label: String {
        switch self {
        case .recognizer: "Apple (standard)"
        case .precise: "Precise (Portuguese)"
        }
    }
}

/// The optional on-device model that re-times Portuguese words: a wav2vec2
/// XLSR-53 CTC model (jonatasgrosman/wav2vec2-large-xlsr-53-portuguese,
/// Apache-2.0) converted to Core ML with 8-bit weights. About 300 MB, so it
/// is downloaded on request and lives outside the app and the data folder.
nonisolated enum WordAlignerModel {
    static let language = "pt"
    static let version = 1
    static let provenanceModel = "SpeechTranscriber + wav2vec2 word timing"
    /// Pinned so a changed or truncated download never installs.
    static let archiveSHA256 = "422f9156bc3982e8b3b66083c54a93965861415c6b5650e065655c1a711799fc"
    /// An extra asset on an app release, not a release of its own: the beta
    /// updater takes the newest release and would read a model-only release
    /// as an update with no installer.
    static let defaultDownloadURL = URL(string:
        "https://github.com/abghandour/ClipBuilder/releases/download/v1.157/PortugueseAligner-\(version).zip")!
    /// `WordAlignerModelURL` points a build at another copy (a local file while testing).
    static var downloadURL: URL {
        UserDefaults.standard.string(forKey: "WordAlignerModelURL").flatMap(URL.init(string:)) ?? defaultDownloadURL
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipBuilder/Models/PortugueseAligner-\(version)", isDirectory: true)
    }
    static var compiledURL: URL { directory.appendingPathComponent("PortugueseAligner.mlmodelc", isDirectory: true) }
    static var vocabularyURL: URL { directory.appendingPathComponent("vocab.json") }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: compiledURL.path) && FileManager.default.fileExists(atPath: vocabularyURL.path)
    }

    /// Set when the user removes the model, so a project that speaks its
    /// language does not download it again unasked; cleared by Download.
    static var autoInstallDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: "WordAlignerAutoInstallOff") }
        set { UserDefaults.standard.set(newValue, forKey: "WordAlignerAutoInstallOff") }
    }

    /// Whether a transcript in `language` gets re-timed under `timing`.
    static func applies(timing: WordTiming, language: String) -> Bool {
        timing == .precise && Locale(identifier: language).language.languageCode?.identifier == Self.language
    }

    static func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Downloads, verifies, compiles and installs the model. Safe to stop:
    /// nothing lands in `directory` until every step has succeeded.
    static func install(from source: URL = downloadURL, into directory: URL = directory,
                        log: @escaping @Sendable (String) -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbuilder-word-aligner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive: URL
        if source.isFileURL {
            archive = source
        } else {
            log("Downloading the word timing model (about 300 MB)…")
            archive = scratch.appendingPathComponent("model.zip")
            try await download(source, to: archive, log: log)
        }
        try Task.checkCancellation()
        log("Verifying…")
        let digest = try sha256(of: archive)
        guard digest == archiveSHA256 else { throw WordAlignerError.corrupt("checksum \(digest.prefix(12))… does not match") }
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                arguments: ["-x", "-k", archive.path, unpacked.path], timeout: 300)
        guard unzip.exitCode == 0 else { throw WordAlignerError.corrupt(unzip.stderrText) }
        let package = unpacked.appendingPathComponent("PortugueseAligner.mlpackage", isDirectory: true)
        let vocabulary = unpacked.appendingPathComponent("vocab.json")
        guard FileManager.default.fileExists(atPath: package.path),
              (try? JSONDecoder().decode(WordAlignerVocabulary.self, from: Data(contentsOf: vocabulary))) != nil else {
            throw WordAlignerError.corrupt("the archive is missing the model or its vocabulary")
        }
        try Task.checkCancellation()
        log("Preparing the model for this Mac…")
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        // Staged beside the destination so the last step is one rename on
        // the same volume; an existing install stays until it is replaced.
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: compiled, to: staged.appendingPathComponent(compiledURL.lastPathComponent))
        try FileManager.default.copyItem(at: vocabulary, to: staged.appendingPathComponent(vocabularyURL.lastPathComponent))
        let notice = unpacked.appendingPathComponent("NOTICE.txt")
        if FileManager.default.fileExists(atPath: notice.path) {
            try FileManager.default.copyItem(at: notice, to: staged.appendingPathComponent("NOTICE.txt"))
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: directory.path) {
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: directory)
        }
        log("Word timing model installed.")
    }

    private static func download(_ url: URL, to destination: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let progress = DownloadProgress(log: log)
        do {
            let (temporary, response) = try await session.download(from: url, delegate: progress)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw WordAlignerError.downloadFailed("HTTP \(status)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as WordAlignerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WordAlignerError.downloadFailed(error.localizedDescription)
        }
    }

    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let log: @Sendable (String) -> Void
        private var reported = -1
        private let lock = NSLock()
        init(log: @escaping @Sendable (String) -> Void) { self.log = log }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
            let changed = lock.withLock { () -> Bool in
                guard percent != reported else { return false }
                reported = percent
                return true
            }
            // The download is most of the job; compiling takes the rest.
            if changed { log("PROGRESS:\(Double(percent) / 100 * 0.9)") }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs the installed model. One file at a time; the model is loaded for a
/// run and released after it, since it holds several hundred megabytes.
actor WordAligner {
    static let shared = WordAligner()

    // An actor lets a second call in at every await; the model must not be
    // loaded twice, so runs queue here.
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Returns owning the model, or throws when the run was stopped while
    /// it queued; it then owns nothing and must not release.
    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Stopped between the check above and here: the handler
                // has already run and found nothing to resume.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// A queued run was stopped: it leaves the queue. One that was handed
    /// the model in the meantime is no longer queued and keeps it; its own
    /// cancellation check after `acquire` releases it.
    private func abandon(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().continuation.resume() }
    }

    /// Re-times `segments` against `audioURL` (the normalized 16 kHz mono
    /// file the recognizer heard).
    func retime(segments: [TranscriptSegment], audioURL: URL, modelDirectory: URL = WordAlignerModel.directory,
                log: @Sendable (String) -> Void) async throws -> (segments: [TranscriptSegment], aligned: Int, kept: Int) {
        let compiled = modelDirectory.appendingPathComponent(WordAlignerModel.compiledURL.lastPathComponent, isDirectory: true)
        let vocabularyURL = modelDirectory.appendingPathComponent(WordAlignerModel.vocabularyURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: compiled.path),
              FileManager.default.fileExists(atPath: vocabularyURL.path) else { throw WordAlignerError.notInstalled }
        let vocabulary = try JSONDecoder().decode(WordAlignerVocabulary.self, from: Data(contentsOf: vocabularyURL))
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let emissions = try await emissions(audioURL: audioURL, compiledModel: compiled, vocabulary: vocabulary, log: log)
        try Task.checkCancellation()
        let result = CTCForcedAligner.retime(segments: segments, emissions: emissions, vocabulary: vocabulary)
        // A stopped pass leaves later words untouched: never hand that back.
        try Task.checkCancellation()
        return result
    }

    /// The model sees fixed windows; each contributes its middle, so every
    /// kept frame had audio on both sides.
    func emissions(audioURL: URL, compiledModel: URL, vocabulary: WordAlignerVocabulary,
                   log: @Sendable (String) -> Void) async throws -> CTCEmissions {
        let timing = PerfSignpost.begin("WordAlignment", metadata: audioURL.lastPathComponent)
        defer { PerfSignpost.end(timing) }
        let configuration = MLModelConfiguration()
        // Measured 2026-11-09: CPU-only returns NaN at 16-bit precision and
        // the Neural Engine does not finish compiling a model this size.
        configuration.computeUnits = .cpuAndGPU
        let model = try await MLModel.load(contentsOf: compiledModel, configuration: configuration)
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        guard Int(format.sampleRate) == vocabulary.sampleRate, format.channelCount == 1 else {
            throw WordAlignerError.unsupportedAudio("\(Int(format.sampleRate)) Hz, \(format.channelCount) channels")
        }
        let window = vocabulary.windowSeconds * vocabulary.sampleRate
        let total = Int(file.length)
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(window)) else {
            throw WordAlignerError.unsupportedAudio("empty file")
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        var values: [Float] = []
        var classes = 0
        var stride = 0
        var frames = 0
        var plan: [WordAlignerWindows.Window] = []
        var index = 0
        // The first window runs before the plan exists: its output says how
        // many rows a window yields, and it always starts at sample 0.
        var current = WordAlignerWindows.Window(start: 0, count: min(window, total), rows: 0..<0)
        while true {
            try Task.checkCancellation()
            file.framePosition = AVAudioFramePosition(current.start)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(current.count))
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
                guard let base = pointer.baseAddress else { return }
                // The model was trained on audio with zero mean and unit
                // variance; silence padding stays at zero.
                var mean: Float = 0, deviation: Float = 0
                vDSP_normalize(channel, 1, base, 1, &mean, &deviation, vDSP_Length(count))
                if deviation == 0 || !deviation.isFinite { vDSP_vclr(base, 1, vDSP_Length(count)) }
                if count < window { vDSP_vclr(base + count, 1, vDSP_Length(window - count)) }
            }
            let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
            guard let emission = output.featureValue(for: "emission")?.multiArrayValue, emission.shape.count == 3 else {
                throw WordAlignerError.corrupt("unexpected model output")
            }
            let rows = emission.shape[1].intValue
            classes = emission.shape[2].intValue
            if plan.isEmpty {
                stride = WordAlignerWindows.stride(window: window, rows: rows)
                plan = WordAlignerWindows.plan(total: total, window: window, rows: rows)
                guard let first = plan.first, first.start == 0 else { break }
                current = first
            }
            let kept = current.rows
            let shaped = MLShapedArray<Float>(converting: emission)
            shaped.withUnsafeShapedBufferPointer { pointer, _, _ in
                values.append(contentsOf: pointer[(kept.lowerBound * classes)..<(kept.upperBound * classes)])
                frames += kept.count
            }
            index += 1
            log("PROGRESS:\(Double(index) / Double(plan.count))")
            guard index < plan.count else { break }
            current = plan[index]
        }
        guard frames > 0, !values.contains(where: \.isNaN) else {
            throw WordAlignerError.corrupt("the model returned no usable output")
        }
        return CTCEmissions(frames: frames, classes: classes, values: values,
                            secondsPerFrame: Double(stride) / Double(vocabulary.sampleRate))
    }
}
