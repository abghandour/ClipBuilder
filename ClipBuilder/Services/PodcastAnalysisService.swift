import AVFoundation
import Foundation
import ImageIO
import Vision

/// Transcript-first podcast analysis. Expensive frame sampling is deliberately
/// absent: Vision sees a small layout sample and at most two frames per turn.
actor PodcastAnalysisService {
    private let ai: AIService

    init(ai: AIService) {
        self.ai = ai
    }

    struct Result: Sendable {
        var runID: Int64
        var newPeople: [DetectedNewPerson]
        var suggestedFilename: String?
    }

    func analyze(video: VideoRecord, profile: BrandProfile, database: Database,
                 runName: String, provider: String?, model: String?, languageCode: String,
                 analyzer: Analyzer, transcription: TranscriptionService,
                 highlightThreshold: Double, holdSeconds: Double,
                 log: @escaping @Sendable (String) -> Void,
                 progress: @escaping @Sendable (Double, String) -> Void, useLocal: Bool = false,
                 capturedSettings: PodcastSettings? = nil) async throws -> Result {
        progress(0.03, "transcribing podcast")
        let segments = try await transcription.transcribePodcast(
            video: video, database: database, languageCode: languageCode, log: log)

        progress(0.30, "separating speakers")
        let turns = try await PodcastSpeakerSeparator.separate(video: video, segments: segments)

        progress(0.43, "identifying speakers")
        let peopleBefore = Set((try await database.fetchPeople()).map(\.key))
        let peopleResult = try await analyzer.detectPeopleOnly(
            video: video, profile: profile, database: database,
            provider: provider, model: model,
            sampleTimes: Self.identitySampleTimes(turns: turns, duration: video.duration), log: log)
        let roster = peopleResult.roster
        let newPeople = roster.filter { !peopleBefore.contains($0.key) }.map {
            DetectedNewPerson(key: $0.key, descriptor: $0.descriptor,
                              suggestedName: $0.name.isEmpty ? nil : $0.name,
                              videoURL: video.url, videoFilename: video.filename,
                              sampleTime: $0.portraitAt)
        }

        progress(0.55, "reading speaker motion")
        let visual = await PodcastVisualAnalyzer.analyze(video: video, turns: turns)
        try await database.setPodcastLayout(videoID: video.id, layout: visual.layout,
                                            seamX: visual.seamX,
                                            confidence: visual.layoutConfidence)
        let resolved = PodcastSpeakerTimelineResolver.resolve(
            audioTurns: turns, picture: visual.talkers, layout: visual.layout,
            roster: roster, minimumHold: holdSeconds)
        try await database.replaceSpeakerTurns(videoID: video.id, turns: resolved)
        let podcastSettings = capturedSettings ?? SettingsStore.loadSettings().podcast
        let enrichment = TranscriptFeatureAnalyzer.analyze(
            segments: segments, videoID: video.id,
            speakerKeys: Array(Set(resolved.compactMap(\.personKey))).sorted(),
            mediaDuration: video.duration,
            speakerHints: resolved.compactMap { turn in
                turn.personKey.map {
                    TranscriptSpeakerHint(startTime: turn.start, endTime: turn.end, personKey: $0)
                }
            },
            deadAirThreshold: podcastSettings.deadAirSeconds,
            fillerRunThreshold: podcastSettings.fillerRunSeconds)
        try await database.replaceTranscriptFeatures(videoID: video.id,
                                                     features: enrichment.features,
                                                     proposals: enrichment.proposals)

        progress(0.70, "grouping complete exchanges")
        let outcome = try await PodcastExchangeSegmenter(ai: ai).segment(
            segments: segments, turns: resolved, provider: provider, model: model, log: log, useLocal: useLocal)
        let tagRanges = Self.exchangeTagRanges(outcome.exchanges, layout: visual.layout,
                                               highlightThreshold: highlightThreshold)
        let runID = try await database.saveAnalysis(
            videoID: video.id, runName: runName,
            instructions: "Transcript-first podcast analysis; whole question-and-answer exchanges",
            sampleInterval: nil, notesJSON: nil, tagRanges: tagRanges, moments: [],
            analyzedTags: ["podcast"], provider: outcome.provenance?.provider,
            model: outcome.provenance?.model, mode: "speech")
        try await database.markAnalysisRunTranscribed(id: runID)

        let sceneRows = try await database.sceneRanges(runID: runID)
        let encoder = JSONEncoder()
        for scene in sceneRows {
            guard let exchange = outcome.exchanges.first(where: {
                abs($0.start - scene.start) < 0.02 && abs($0.end - scene.end) < 0.02
            }) else { continue }
            try await database.setSceneNarrative(scene.id,
                                                 narrative: "\(exchange.title) — \(exchange.summary)",
                                                 score: exchange.score)
            try await database.setSceneScore(scene.id, score: exchange.score,
                                             excitement: exchange.score / 10)
            try await database.setSceneFavorite(scene.id,
                                                favorite: Self.shouldFavorite(
                                                    score: exchange.score,
                                                    threshold: highlightThreshold))
            let path = PodcastSpeakerTimelineResolver.cameraPath(
                for: scene.start...scene.end, turns: resolved,
                layout: visual.layout, videoSize: CGSize(width: video.width, height: video.height),
                roster: roster, minimumHold: holdSeconds)
            if !path.keyframes.isEmpty, let data = try? encoder.encode(path) {
                try await database.setSceneCenterStagePath(
                    scene.id, json: String(data: data, encoding: .utf8))
            }
        }
        progress(1, "podcast ready")
        return Result(runID: runID, newPeople: newPeople,
                      suggestedFilename: peopleResult.suggestedFilename)
    }

    /// saveAnalysis creates a scene per distinct range. Every tag must use the
    /// whole exchange; question/answer subranges are deliberately not persisted.
    nonisolated static func exchangeTagRanges(_ exchanges: [PodcastExchange], layout: PodcastLayout,
                                              highlightThreshold: Double) -> [String: [(start: Double, end: Double)]] {
        var tagRanges: [String: [(start: Double, end: Double)]] = [:]
        for exchange in exchanges {
            let range = (start: exchange.start, end: exchange.end)
            for tag in ["podcast", "question", "answer", "podcast-exchange"] {
                tagRanges[tag, default: []].append(range)
            }
            if exchange.score >= highlightThreshold {
                tagRanges["reel-highlight", default: []].append(range)
            }
            if layout == .splitHorizontal {
                tagRanges["podcast:split", default: []].append(range)
            }
            for key in exchange.speakerKeys {
                tagRanges["person:\(key)", default: []].append(range)
            }
        }
        return tagRanges
    }

    nonisolated static func shouldFavorite(score: Double, threshold: Double) -> Bool {
        score >= threshold
    }

    nonisolated static func identitySampleTimes(turns: [SpeakerTurn], duration: Double) -> [Double] {
        // Three representative moments per voice, regardless of recording length.
        var times: [Double] = []
        for cluster in Set(turns.map(\.cluster)).sorted() {
            let matches = turns.filter { $0.cluster == cluster }
            for index in Set([0, matches.count / 2, matches.count - 1]).sorted() where index >= 0 {
                times.append((matches[index].start + matches[index].end) / 2)
            }
        }
        if times.isEmpty { times = [duration / 2] }
        return Array(Set(times.map { min(max(0, $0), max(0, duration - 0.1)) })).sorted()
    }
}

nonisolated enum PodcastSpeakerSeparator {
    /// Lightweight on-device voice embeddings (energy, sign changes and
    /// autocorrelation) clustered deterministically into at most two voices.
    @concurrent
    static func separate(video: VideoRecord, segments: [TranscriptSegment]) async throws -> [SpeakerTurn] {
        let segments = voiceWindows(segments)
        guard !segments.isEmpty else { return [] }
        let audioURL = try await NormalizedAudioCache.shared.audio(source: video.url)
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        var vectors: [[Double]] = []
        for segment in segments {
            try Task.checkCancellation()
            let start = max(0, segment.start)
            let duration = min(4, max(0.12, segment.end - start))
            file.framePosition = AVAudioFramePosition(start * rate)
            let count = AVAudioFrameCount(duration * rate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: count) else {
                vectors.append(Array(repeating: 0, count: 24)); continue
            }
            try file.read(into: buffer, frameCount: count)
            vectors.append(embedding(buffer))
        }
        return turns(segments: segments, embeddings: vectors, videoID: video.id)
    }

    static func voiceWindows(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            guard let words = segment.words, !words.isEmpty else { return [segment] }
            var windows: [TranscriptSegment] = []
            var first = 0
            for index in words.indices {
                guard words[index].end - words[first].start >= 1 || index == words.count - 1 else { continue }
                let group = Array(words[first...index])
                windows.append(TranscriptSegment(start: words[first].start, end: words[index].end,
                                                  text: group.map(\.word).joined(separator: " "), words: group))
                first = index + 1
            }
            return windows
        }
    }

    static func turns(segments: [TranscriptSegment], embeddings: [[Double]],
                      videoID: Int64) -> [SpeakerTurn] {
        guard segments.count == embeddings.count, !segments.isEmpty else { return [] }
        let labels = cluster(embeddings)
        let raw = segments.enumerated().map { index, segment in
            SpeakerTurn(videoID: videoID, start: segment.start, end: segment.end,
                        cluster: labels[index], confidence: clusterConfidence(
                            embeddings[index], label: labels[index], embeddings: embeddings, labels: labels))
        }
        var merged: [SpeakerTurn] = []
        for turn in raw {
            if var last = merged.last, last.cluster == turn.cluster, turn.start - last.end <= 0.7 {
                last.end = max(last.end, turn.end)
                last.confidence = (last.confidence + turn.confidence) / 2
                merged[merged.count - 1] = last
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    static func cluster(_ vectors: [[Double]]) -> [Int] {
        guard vectors.count >= 3 else { return Array(repeating: 0, count: vectors.count) }
        // Compare timbre dimensions in standard-deviation units. Raw log
        // energy is numerically much larger than autocorrelation and would
        // otherwise hide a clear pitch difference.
        let normalized = standardize(vectors)
        var a = normalized[0]
        var b = normalized.max(by: { distance($0, a) < distance($1, a) }) ?? a
        guard distance(a, b) > 0.01 else { return Array(repeating: 0, count: vectors.count) }
        var labels = Array(repeating: 0, count: vectors.count)
        for _ in 0..<8 {
            labels = normalized.map { distance($0, a) <= distance($0, b) ? 0 : 1 }
            if labels.allSatisfy({ $0 == 0 }) || labels.allSatisfy({ $0 == 1 }) {
                return Array(repeating: 0, count: vectors.count)
            }
            a = centroid(normalized.enumerated().filter { labels[$0.offset] == 0 }.map(\.element))
            b = centroid(normalized.enumerated().filter { labels[$0.offset] == 1 }.map(\.element))
        }
        return labels
    }

    private static func embedding(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channel = buffer.floatChannelData?.pointee else { return Array(repeating: 0, count: 24) }
        let count = Int(buffer.frameLength)
        guard count > 2 else { return Array(repeating: 0, count: 24) }
        let samples = (0..<count).map { Double(channel[$0]) }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
        let zcr = zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            total + ((pair.0 >= 0) != (pair.1 >= 0) ? 1 : 0)
        }
        func correlation(lag: Int) -> Double {
            guard samples.count > lag else { return 0 }
            let products = zip(samples.dropFirst(lag), samples.dropLast(lag)).map { pair in
                pair.0 * pair.1
            }
            return products.reduce(0, +) / Double(products.count)
        }
        // Fixed-rate spectral envelope adds voice timbre beyond pitch and
        // loudness. Average short Hann windows, then remove overall gain.
        let windowSize = min(512, samples.count)
        var spectrum = [Double](repeating: 0, count: 20)
        let starts = stride(from: 0, through: max(0, samples.count - windowSize),
                            by: max(windowSize, samples.count / 8))
        var windowCount = 0
        for start in starts {
            windowCount += 1
            for band in spectrum.indices {
                let mel = 200.0 + Double(band) * 120
                let frequency = 700 * (pow(10, mel / 2595) - 1)
                let coefficient = 2 * cos(2 * .pi * frequency / 16000)
                var previous = 0.0, older = 0.0
                for offset in 0..<windowSize {
                    let hann = 0.5 - 0.5 * cos(2 * .pi * Double(offset) / Double(windowSize - 1))
                    let value = samples[start + offset] * hann + coefficient * previous - older
                    older = previous
                    previous = value
                }
                spectrum[band] += max(0, previous * previous + older * older - coefficient * previous * older)
            }
        }
        spectrum = spectrum.map { log(max(1e-12, $0 / Double(max(1, windowCount)))) }
        let mean = spectrum.reduce(0, +) / Double(spectrum.count)
        return spectrum.map { $0 - mean }
            + [Double(zcr) / Double(samples.count), correlation(lag: 20) / max(1e-12, rms * rms),
               correlation(lag: 40) / max(1e-12, rms * rms), correlation(lag: 80) / max(1e-12, rms * rms)]
    }

    private static func normalize(_ vector: [Double]) -> [Double] {
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? vector.map { $0 / length } : vector
    }
    private static func standardize(_ vectors: [[Double]]) -> [[Double]] {
        guard let first = vectors.first, !first.isEmpty else { return vectors }
        let means = first.indices.map { index in
            vectors.reduce(0) { $0 + $1[index] } / Double(vectors.count)
        }
        let deviations = first.indices.map { index in
            let variance = vectors.reduce(0) { $0 + pow($1[index] - means[index], 2) }
                / Double(vectors.count)
            return sqrt(variance)
        }
        return vectors.map { vector in
            vector.indices.map { index in
                deviations[index] > 0.000_001
                    ? (vector[index] - means[index]) / deviations[index] : 0
            }
        }
    }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
    }
    private static func centroid(_ vectors: [[Double]]) -> [Double] {
        guard let first = vectors.first else { return [] }
        return first.indices.map { index in vectors.reduce(0) { $0 + $1[index] } / Double(vectors.count) }
    }
    private static func clusterConfidence(_ vector: [Double], label: Int,
                                          embeddings: [[Double]], labels: [Int]) -> Double {
        let own = centroid(embeddings.enumerated().filter { labels[$0.offset] == label }.map(\.element))
        let other = centroid(embeddings.enumerated().filter { labels[$0.offset] != label }.map(\.element))
        guard !other.isEmpty else { return 0.5 }
        let ownDistance = distance(normalize(vector), normalize(own))
        let otherDistance = distance(normalize(vector), normalize(other))
        return min(1, max(0, otherDistance / max(0.001, ownDistance + otherDistance)))
    }
}

nonisolated enum PodcastSpeakerTimelineResolver {
    static func resolve(audioTurns: [SpeakerTurn], picture: [PictureTalkerSignal],
                        layout: PodcastLayout, roster: [VideoPersonRecord],
                        minimumHold: Double) -> [SpeakerTurn] {
        var clusterSides: [Int: PodcastSpeakerSide] = [:]
        for cluster in Set(audioTurns.map(\.cluster)) {
            let overlapping = picture.filter { signal in
                audioTurns.contains { $0.cluster == cluster && signal.end > $0.start && signal.start < $0.end }
            }
            let left = overlapping.filter { $0.side == .left }.reduce(0) { $0 + $1.confidence }
            let right = overlapping.filter { $0.side == .right }.reduce(0) { $0 + $1.confidence }
            clusterSides[cluster] = left == right ? .unknown : (left > right ? .left : .right)
        }
        var personBySide: [PodcastSpeakerSide: String] = [:]
        for person in roster {
            guard let box = person.portraitBox else { continue }
            let side: PodcastSpeakerSide = box.x + box.w / 2 < 0.5 ? .left : .right
            if personBySide[side] == nil { personBySide[side] = person.key }
        }
        var result: [SpeakerTurn] = []
        // Hold time belongs to the camera, never to the speaker identity.
        // A brief interjection must still be attributed to its actual speaker.
        for var turn in audioTurns {
            let strongest = picture.filter { $0.end > turn.start && $0.start < turn.end }
                .max { $0.confidence < $1.confidence }
            let audioSide = turn.resolvedSide != .unknown ? turn.resolvedSide : (clusterSides[turn.cluster] ?? .unknown)
            let pictureWins = strongest.map {
                $0.side != .unknown && ($0.confidence >= 0.7 || $0.confidence > turn.confidence)
            } ?? false
            var side = pictureWins ? (strongest?.side ?? audioSide) : audioSide
            if layout == .singleCamera, side == .unknown, roster.count == 1 { side = .full }
            turn.pictureSide = strongest?.side ?? .unknown
            turn.pictureConfidence = strongest?.confidence ?? 0
            turn.resolvedSide = side
            turn.personKey = personBySide[side]
                ?? (layout == .singleCamera && roster.count == 1 ? roster.first?.key : nil)
            result.append(turn)
        }
        return result
    }

    static func cameraPath(for range: ClosedRange<Double>, turns: [SpeakerTurn],
                           layout: PodcastLayout, videoSize: CGSize,
                           roster: [VideoPersonRecord] = [],
                           minimumHold: Double = 1.5) -> SceneCameraPath {
        let relevant = turns.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        guard !relevant.isEmpty else { return SceneCameraPath(camera: "podcast", keyframes: []) }
        let aspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 16 / 9
        let cropWidth = min(layout == .splitHorizontal ? 0.5 : 1, (9.0 / 16.0) / aspect)
        func frame(_ turn: SpeakerTurn, at time: Double) -> CameraPathKeyframe {
            let portraitCenter = roster.first(where: { $0.key == turn.personKey })?.portraitBox
                .map { $0.x + $0.w / 2 }
            let center = layout == .singleCamera ? (portraitCenter ?? 0.5)
                : turn.resolvedSide == .right ? 0.75 : turn.resolvedSide == .left ? 0.25 : 0.5
            return CameraPathKeyframe(t: max(0, time - range.lowerBound),
                                      x: min(1 - cropWidth, max(0, center - cropWidth / 2)),
                                      y: 0, w: cropWidth, h: 1)
        }
        var frames: [CameraPathKeyframe] = []
        var previous: SpeakerTurn?
        var heldSince = range.lowerBound
        for turn in relevant {
            var time = max(range.lowerBound, turn.start)
            let changed = previous.map {
                layout == .singleCamera ? $0.personKey != turn.personKey : $0.resolvedSide != turn.resolvedSide
            } ?? false
            if changed {
                time = max(time, heldSince + max(0, minimumHold))
                guard time < min(turn.end, range.upperBound) else { continue }
            }
            if let previous, changed, time > range.lowerBound + 0.02 {
                frames.append(frame(previous, at: time - 0.01))
            }
            frames.append(frame(turn, at: time))
            if previous == nil || changed { heldSince = time }
            previous = turn
        }
        if let previous { frames.append(frame(previous, at: range.upperBound)) }
        return SceneCameraPath(camera: "podcast", keyframes: frames)
    }
}

actor PodcastVisualAnalyzer {
    struct Result: Sendable {
        var layout: PodcastLayout
        var seamX: Double?
        var layoutConfidence: Double
        var talkers: [PictureTalkerSignal]
    }

    static func analyze(video: VideoRecord, turns: [SpeakerTurn]) async -> Result {
        let layoutTimes = stride(from: 0.1, through: max(0.1, video.duration - 0.1),
                                 by: max(1, video.duration / 5)).prefix(5).map { $0 }
        let layoutFrames = await ThumbnailService.jpegFrames(url: video.url, at: layoutTimes,
                                                              maxDimension: 720, quality: 0.75)
        let available = layoutFrames.compactMap { $0 }
        let splitHits = available.filter { jpeg in
            let metrics = faceMouthMetrics(jpeg)
            return metrics.keys.contains(.left) && metrics.keys.contains(.right)
                && hasCenterSeam(jpeg)
        }.count
        let layoutConfidence = available.isEmpty ? 0 : Double(splitHits) / Double(available.count)
        let layout: PodcastLayout = layoutConfidence >= 0.6 ? .splitHorizontal : .singleCamera

        let sampled = turns.count <= 160 ? turns : turns.enumerated().compactMap {
            $0.offset.isMultiple(of: max(1, (turns.count + 159) / 160)) ? $0.element : nil
        }
        let times = sampled.flatMap { turn -> [Double] in
            let midpoint = (turn.start + turn.end) / 2
            return [max(0, midpoint - 0.12), min(video.duration, midpoint + 0.12)]
        }
        let frames = await ThumbnailService.jpegFrames(url: video.url, at: times,
                                                       maxDimension: 720, quality: 0.75)
        var signals: [PictureTalkerSignal] = []
        for (index, turn) in sampled.enumerated() {
            guard frames.indices.contains(index * 2 + 1),
                  let before = frames[index * 2], let after = frames[index * 2 + 1] else { continue }
            let first = faceMouthMetrics(before), second = faceMouthMetrics(after)
            let left = abs((second[.left] ?? 0) - (first[.left] ?? 0))
            let right = abs((second[.right] ?? 0) - (first[.right] ?? 0))
            let total = left + right
            guard total > 0.002 else { continue }
            let side: PodcastSpeakerSide = left > right ? .left : .right
            signals.append(PictureTalkerSignal(start: turn.start, end: turn.end, side: side,
                                                confidence: min(1, max(left, right) / total)))
        }
        return Result(layout: layout, seamX: layout == .splitHorizontal ? 0.5 : nil,
                      layoutConfidence: layoutConfidence, talkers: signals)
    }

    /// Two faces alone also describes an ordinary studio shot. Require a
    /// persistent image discontinuity near the center before pinning halves.
    static func hasCenterSeam(_ jpeg: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        func edge(_ x: Int) -> Double {
            var total = 0.0
            for y in 4..<(height - 4) {
                for channel in 0..<3 {
                    let offset = (y * width + x) * 4 + channel
                    total += abs(Double(pixels[offset]) - Double(pixels[offset - 4]))
                }
            }
            return total / Double((height - 8) * 3)
        }
        let middle = (46...50).map(edge).max() ?? 0
        let background = ([40, 42, 44, 52, 54, 56].map(edge).reduce(0, +)) / 6
        return middle > 8 && middle > background * 1.8
    }

    private static func faceMouthMetrics(_ jpeg: Data) -> [PodcastSpeakerSide: Double] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [:] }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var values: [PodcastSpeakerSide: Double] = [:]
        for face in request.results ?? [] {
            let centerX = face.boundingBox.midX
            let side: PodcastSpeakerSide = centerX < 0.5 ? .left : .right
            let points = face.landmarks?.outerLips?.normalizedPoints ?? []
            guard !points.isEmpty else { values[side] = 0; continue }
            let aperture = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
            values[side] = max(values[side] ?? 0, aperture)
        }
        return values
    }
}

actor PodcastExchangeSegmenter {
    private let ai: AIService
    init(ai: AIService) { self.ai = ai }

    struct Outcome: Sendable {
        var exchanges: [PodcastExchange]
        var provenance: AIProvenance?
    }

    func segment(segments: [TranscriptSegment], turns: [SpeakerTurn],
                 provider: String?, model: String?,
                 log: @escaping @Sendable (String) -> Void, useLocal: Bool = false) async throws -> Outcome {
        let sentences = Self.sentenceSegments(segments, turns: turns)
        let candidates = Self.candidateExchanges(segments: sentences, turns: turns)
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var characters = 0
        for candidate in candidates {
            let rows = sentences.filter { $0.end > candidate.start && $0.start < candidate.end }
            let count = rows.reduce(0) { $0 + $1.text.count }
            // Keep each bounded candidate together within the request budget
            // so the model can assess its question and answer in context.
            if !current.isEmpty, characters + count > 12_000 {
                chunks.append(current)
                current = []
                characters = 0
            }
            current += rows
            characters += count
        }
        if !current.isEmpty { chunks.append(current) }
        var result = Outcome(exchanges: [], provenance: nil)
        // Keep serial: AI calls append to the run's shared provenance capture;
        // concurrent completion would reorder it and change failure ordering.
        for chunk in chunks {
            try Task.checkCancellation()
            let outcome = try await segmentChunk(segments: chunk, turns: turns,
                                                 provider: provider, model: model, log: log, useLocal: useLocal)
            result.exchanges += outcome.exchanges
            result.provenance = outcome.provenance ?? result.provenance
        }
        return result
    }

    private func segmentChunk(segments: [TranscriptSegment], turns: [SpeakerTurn],
                              provider: String?, model: String?,
                              log: @escaping @Sendable (String) -> Void, useLocal: Bool = false) async throws -> Outcome {
        let candidates = Self.candidateExchanges(segments: segments, turns: turns)
        guard !candidates.isEmpty else { return Outcome(exchanges: [], provenance: nil) }
        let locked = useLocal ? candidates.map { PodcastExchange(start: $0.start, end: $0.end, title: "", summary: "", score: 0, speakerKeys: $0.speakerKeys) }.filter { PodcastLocalRules.locked($0, segments: segments, turns: turns) } : []
        log(useLocal ? "Podcast boundaries locked where unambiguous — asking the model for scores and remaining boundaries" : "Podcast exchanges — asking the model")
        let lines = segments.enumerated().map { index, sentence in
            "[\(index)] \(sentence.start.timecode)-\(sentence.end.timecode): \(sentence.text)"
        }.joined(separator: "\n")
        let hints = candidates.map { candidate in
            let indices = segments.indices.filter {
                segments[$0].end > candidate.start && segments[$0].start < candidate.end
            }
            return "\(indices.first ?? 0)-\(indices.last ?? 0)\(locked.contains { $0.start == candidate.start && $0.end == candidate.end } ? " LOCKED: score and title only; never move these boundaries" : " open for repair")"
        }.joined(separator: ", ")
        let prompt = """
        You are editing a spoken podcast. The numbered rows below are word-safe sentence
        or speaker-turn units; punctuation may be absent. Proposed exchanges: \(hints).
        Split proposed exchanges at listed sentence indices when a new question begins,
        and merge adjacent exchanges when needed to keep a question with its full answer.
        Return contiguous inclusive sentence-index ranges using first_sentence and last_sentence.
        Cover every sentence exactly once in order, with no overlaps or omissions. Never split a word.
        For each exchange, write a short title, a one-sentence summary, and a reel score
        from 0 to 10 considering the opening hook, self-contained meaning, quotability,
        emotional/surprising content, and a 20-60 second sweet spot.

        \(lines)

        Return only JSON: {"exchanges":[{"first_sentence":0,"last_sentence":1,"title":"...","summary":"...","score":7.5}]}
        """
        do {
            let response = try await ai.call(prompt: prompt, task: "soundbites", model: model,
                                             provider: provider, timeout: 240, log: log)
            guard let object = AIResponseParser.jsonObject(from: response.text),
                  let raw = object["exchanges"] as? [[String: Any]] else {
                throw AIError.unusableResponse("Podcast exchange response was not valid JSON")
            }
            var exchanges = try Self.validatedExchanges(raw, segments: segments, turns: turns)
            exchanges = PodcastLocalRules.preserve(exchanges, locked: locked)
            var provenance = response.provenance
            if useLocal { provenance.technique = "locked-exchanges" }
            return Outcome(exchanges: exchanges, provenance: provenance)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("AI exchange grouping unavailable; keeping deterministic whole exchanges (\(error))")
            return Outcome(exchanges: candidates.enumerated().map { index, item in
                PodcastExchange(start: item.start, end: item.end,
                                title: "Exchange \(index + 1)",
                                summary: "A complete question-and-answer exchange.",
                                score: useLocal ? PodcastLocalRules.score(segments: segments, start: item.start, end: item.end) : Self.heuristicScore(duration: item.end - item.start),
                                speakerKeys: item.speakerKeys)
            }, provenance: useLocal ? .local(technique: "transcript-features") : nil)
        }
    }

    /// The model may split or merge candidates, but must cover the exact ordered
    /// sentence partition. Reject the entire response rather than losing speech.
    static func validatedExchanges(_ raw: [[String: Any]], segments: [TranscriptSegment],
                                   turns: [SpeakerTurn]) throws -> [PodcastExchange] {
        var next = 0
        var exchanges: [PodcastExchange] = []
        for entry in raw {
            guard let firstNumber = entry["first_sentence"] as? NSNumber,
                  let lastNumber = entry["last_sentence"] as? NSNumber,
                  firstNumber.doubleValue == Double(firstNumber.intValue),
                  lastNumber.doubleValue == Double(lastNumber.intValue) else {
                throw AIError.unusableResponse("Podcast exchange indices must be integers")
            }
            let first = firstNumber.intValue, last = lastNumber.intValue
            guard first == next, last >= first, segments.indices.contains(last) else {
                throw AIError.unusableResponse("Podcast exchange response omitted or overlapped sentences")
            }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = (entry["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let score = (entry["score"] as? NSNumber)?.doubleValue ?? 0
            // D5: a validated AI exchange has no maximum duration. The safety
            // bound belongs only to deterministic candidates and fallback output.
            exchanges.append(PodcastExchange(
                start: segments[first].start, end: segments[last].end,
                title: title.isEmpty ? "Podcast exchange" : title,
                summary: summary.isEmpty ? "A complete question-and-answer exchange." : summary,
                score: score.isFinite ? min(10, max(0, score)) : 0,
                speakerKeys: speakerKeys(start: segments[first].start,
                                         end: segments[last].end, turns: turns)))
            next = last + 1
        }
        guard next == segments.count else {
            throw AIError.unusableResponse("Podcast exchange response omitted sentences")
        }
        return exchanges
    }

    private static func speakerKeys(start: Double, end: Double, turns: [SpeakerTurn]) -> [String] {
        Array(Set(turns.filter { $0.end > start && $0.start < end }.compactMap(\.personKey))).sorted()
    }

    private static func speakerChanged(_ first: SpeakerTurn, _ second: SpeakerTurn) -> Bool {
        if let a = first.personKey, let b = second.personKey { return a != b }
        return first.cluster != second.cluster
    }

    private static func turnIndex(_ segment: TranscriptSegment, turns: [SpeakerTurn]) -> Int? {
        turns.indices.max { a, b in
            max(0, min(segment.end, turns[a].end) - max(segment.start, turns[a].start))
                < max(0, min(segment.end, turns[b].end) - max(segment.start, turns[b].start))
        }.flatMap { index in
            turns[index].end > segment.start && turns[index].start < segment.end ? index : nil
        }
    }

    private static func questionFlags(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [Bool] {
        let openers = ["why", "how", "what", "when", "where", "who", "did", "do", "does",
                       "is", "are", "can", "could", "would", "should", "tell me", "por que",
                       "como", "o que", "quando", "onde", "quem", "voce"]
        let indices = segments.map { turnIndex($0, turns: turns) }
        var questionTurns = Set<Int>()
        return segments.indices.map { index in
            let segment = segments[index]
            let turn = indices[index]
            let atStart = index == 0 || turn == nil || turn != indices[index - 1]
            let text = segment.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let opener = openers.contains { text == $0 || text.hasPrefix($0 + " ") }
            var shortQuestion = false
            if let turn, turns.indices.contains(turn + 1) {
                let current = turns[turn], next = turns[turn + 1]
                let changed = turn == 0 || speakerChanged(turns[turn - 1], current)
                shortQuestion = changed && current.end - current.start < 15
                    && next.end - next.start > current.end - current.start
                    && speakerChanged(current, next)
            }
            let explicit = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            if explicit || (atStart && (opener || shortQuestion)) {
                if let turn { questionTurns.insert(turn) }
                return true
            }
            return turn.map { questionTurns.contains($0) } ?? false
        }
    }

    static func candidateExchanges(segments: [TranscriptSegment], turns: [SpeakerTurn])
        -> [(start: Double, end: Double, speakerKeys: [String])] {
        let segments = sentenceSegments(segments, turns: turns)
        guard !segments.isEmpty else { return [] }
        let questions = questionFlags(segments, turns: turns)
        var ranges: [ClosedRange<Int>] = []
        var first = 0
        var sawAnswer = false
        for index in segments.indices {
            var pausedChange = false
            if index > 0, segments[index].start - segments[index - 1].end >= 1.5,
               let previous = turnIndex(segments[index - 1], turns: turns),
               let current = turnIndex(segments[index], turns: turns) {
                pausedChange = speakerChanged(turns[previous], turns[current])
            }
            if index > first, sawAnswer, questions[index] || pausedChange {
                ranges += boundedRanges(segments: segments, first: first, last: index - 1, turns: turns)
                first = index
                sawAnswer = false
            }
            if !questions[index] { sawAnswer = true }
        }
        ranges += boundedRanges(segments: segments, first: first, last: segments.count - 1, turns: turns)
        return ranges.map { range in
            let start = segments[range.lowerBound].start, end = segments[range.upperBound].end
            return (start, end, speakerKeys(start: start, end: end, turns: turns))
        }
    }

    /// Prefer the longest pause at a turn boundary, then at a sentence boundary,
    /// within 180 seconds. This is a missing-signal fallback, not a reel length target.
    private static func boundedRanges(segments: [TranscriptSegment], first: Int, last: Int,
                                      turns: [SpeakerTurn]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var first = first
        while first < last, segments[last].end - segments[first].start > 180 {
            let eligible = ((first + 1)...last).filter {
                segments[$0 - 1].end - segments[first].start <= 180
            }
            let turnBoundaries = eligible.filter { index in
                guard let a = turnIndex(segments[index - 1], turns: turns),
                      let b = turnIndex(segments[index], turns: turns) else { return false }
                return speakerChanged(turns[a], turns[b])
            }
            let choices = turnBoundaries.isEmpty ? eligible : turnBoundaries
            guard let split = choices.max(by: { a, b in
                let gapA = segments[a].start - segments[a - 1].end
                let gapB = segments[b].start - segments[b - 1].end
                return gapA == gapB ? a < b : gapA < gapB
            }) else { break }
            ranges.append(first...(split - 1))
            first = split
        }
        ranges.append(first...last)
        return ranges
    }

    /// Keep punctuation boundaries, and recover word-safe units at speaker changes,
    /// long pauses, or the safety limit when SpeechTranscriber omits punctuation.
    static func sentenceSegments(_ segments: [TranscriptSegment], turns: [SpeakerTurn] = []) -> [TranscriptSegment] {
        segments.flatMap { segment -> [TranscriptSegment] in
            var words = segment.words ?? []
            if words.isEmpty {
                guard segment.end - segment.start > 180 else { return [segment] }
                // Legacy transcripts have no word times. Approximate timings only
                // for this safety fallback, retaining every complete word.
                let tokens = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !tokens.isEmpty else { return [segment] }
                let step = (segment.end - segment.start) / Double(tokens.count)
                words = tokens.enumerated().map { index, word in
                    TranscriptWord(word: word, start: segment.start + Double(index) * step,
                                   end: segment.start + Double(index + 1) * step)
                }
            }
            var result: [TranscriptSegment] = []
            var first = 0
            for index in words.indices {
                let text = words[index].word.trimmingCharacters(in: .whitespacesAndNewlines)
                let last = index == words.count - 1
                let next = last ? index : index + 1
                let turnBoundary = !last && turns.contains { turn in
                    turn.start > words[index].start && turn.start <= words[next].start
                }
                let pause = !last && words[next].start - words[index].end >= 1.5
                let limit = !last && words[next].end - words[first].start > 180
                guard text.last.map({ ".!?".contains($0) }) == true || last || turnBoundary || pause || limit else { continue }
                let sentence = Array(words[first...index])
                result.append(TranscriptSegment(start: words[first].start, end: words[index].end,
                                                text: sentence.map(\.word).joined(separator: " "), words: sentence))
                first = index + 1
            }
            return result
        }
    }

    private static func heuristicScore(duration: Double) -> Double {
        // Duration alone is not evidence of a good hook or quotable content.
        // Leave fallback scenes unscored rather than auto-favoriting them.
        0
    }
}

nonisolated enum PodcastFramingService {
    static func splitFeedWindows(sourceAspect: Double) -> (left: FreeCropRect, right: FreeCropRect) {
        let aspect = sourceAspect.isFinite && sourceAspect > 0 ? sourceAspect : 16.0 / 9.0
        let height = min(1, max(0.1, 0.5 * aspect / 1.125))
        let y = (1 - height) / 2
        return (FreeCropRect(xFrac: 0, yFrac: y, wFrac: 0.5, hFrac: height),
                FreeCropRect(xFrac: 0.5, yFrac: y, wFrac: 0.5, hFrac: height))
    }

    /// Build a vertical 50/50 frame from the two equal source halves. The
    /// Wizard then burns captions and lower thirds onto this normalized clip
    /// in its usual single encode pass.
    static func splitZoom(source: URL, start: Double, duration: Double,
                          output: URL) async throws {
        let width = RenderContext.settings.width
        let height = RenderContext.settings.height
        let halfHeight = height / 2
        let filter = """
        [0:v]crop=iw/2:ih:0:0,scale=\(width):\(halfHeight):force_original_aspect_ratio=increase,crop=\(width):\(halfHeight),setsar=1[left];\
        [0:v]crop=iw/2:ih:iw/2:0,scale=\(width):\(halfHeight):force_original_aspect_ratio=increase,crop=\(width):\(halfHeight),setsar=1[right];\
        [left][right]vstack=inputs=2[v]
        """
        var arguments = ["-y", "-ss", String(format: "%.3f", start),
                         "-t", String(format: "%.3f", duration), "-i", source.path,
                         "-filter_complex", filter, "-map", "[v]", "-map", "0:a?"]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: max(180, duration * 8))
    }
}
