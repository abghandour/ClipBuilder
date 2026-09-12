import Foundation
import NaturalLanguage

nonisolated protocol ReelFrameInspector: Sendable {
  func inspect(_ data: Data) async throws -> VisionImageTagger.Signals
  func quality(_ data: Data) -> FrameQuality.Metrics?
}
nonisolated extension ReelFrameInspector {
  func quality(_ data: Data) -> FrameQuality.Metrics? { FrameQuality.metrics(data) }
}
nonisolated struct VisionReelFrameInspector: ReelFrameInspector {
  func inspect(_ data: Data) async throws -> VisionImageTagger.Signals {
    try await VisionImageTagger.inspect(data)
  }
}

nonisolated enum ReelTraitExtractor {
  struct Frame: Sendable {
    var time: Double
    var signals: VisionImageTagger.Signals
    var quality: FrameQuality.Metrics
  }

  @concurrent
  static func traits(
    for url: URL, caption: String?, transcript: [TranscriptSegment]?,
    cachedDetectors: VideoDetectors? = nil,
    inspector: any ReelFrameInspector = VisionReelFrameInspector()
  ) async throws -> ReelTraits {
    let info = await FFmpeg.info(of: url)
    guard info.duration > 0 else {
      throw AIError.unusableResponse("Cannot compute traits: no video duration.")
    }
    let detectors: VideoDetectors
    if let cachedDetectors {
      detectors = cachedDetectors
    } else {
      detectors = try await FFmpeg.detectors(of: url, duration: info.duration)
    }
    let times = Array(
      Set(
        ([0.25, 0.75, 1.5, 2.5]
          + (0..<12).map {
            info.duration * (Double($0) + 0.5) / 12
          }).filter { $0 < info.duration })
    ).sorted()
    let images = await ThumbnailService.jpegFrames(url: url, at: times)
    var frames: [Frame] = []
    for (time, image) in zip(times, images) {
      try Task.checkCancellation()
      guard let image, let quality = inspector.quality(image) else { continue }
      frames.append(Frame(time: time, signals: try await inspector.inspect(image), quality: quality))
    }
    guard !frames.isEmpty else {
      throw AIError.unusableResponse("Cannot compute traits: no readable frames.")
    }
    let box = await RenderEngine().detectContentBox(source: url, start: 0, duration: info.duration)
    let loudness = info.hasAudio ? await Analyzer.loudnessCurve(url: url) : []
    return assemble(
      duration: info.duration, width: info.width, height: info.height,
      detectors: detectors, frames: frames, caption: caption, transcript: transcript,
      crop: box.map { $0.h < 0.95 ? .letterboxed : ($0.w < 0.95 ? .pillarboxed : .full) } ?? .full,
      loudness: loudness, hasAudio: info.hasAudio)
  }

  /// Pure reduction, also used by deterministic golden tests; no text enters the result.
  static func assemble(
    duration: Double, width: Int, height: Int, detectors: VideoDetectors,
    frames: [Frame], caption: String?, transcript: [TranscriptSegment]?,
    crop: ReelTraits.Crop = .full, loudness: [Double] = [], hasAudio: Bool = false
  ) -> ReelTraits {
    var value = ReelTraits()
    value.duration = max(0, duration)
    let span = max(0.001, duration)
    let cuts = Array(Set(detectors.cuts.filter { $0 > 0 && $0 < duration })).sorted()
    value.cutCount = cuts.count
    value.cutsPerMinute = Double(cuts.count) * 60 / span
    let boundaries = [0] + cuts + [duration]
    let intervals = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }
    let mean = average(intervals)
    value.cutIntervalVariance = average(intervals.map { pow($0 - mean, 2) })
    value.blackFraction = fraction(detectors.black, duration: duration)
    value.frozenFraction = fraction(detectors.frozen, duration: duration)
    value.faceFirstSecond = average(
      frames.filter { $0.time < 1 }.map { $0.signals.faces.isEmpty ? 0 : 1 })
    value.faceFirstThreeSeconds = average(
      frames.filter { $0.time < 3 }.map { $0.signals.faces.isEmpty ? 0 : 1 })
    value.textFirstThreeSeconds = average(
      frames.filter { $0.time < 3 }.map { min(1, $0.signals.textArea) })
    value.textArea = average(frames.map { min(1, $0.signals.textArea) })
    value.sharpnessMedian = median(frames.map { $0.quality.variance })
    value.luminanceMedian = median(frames.map { $0.quality.luminance })
    func mix(_ names: [String]) -> Double {
      average(
        frames.map { frame in Double(names.compactMap { frame.signals.labels[$0] }.max() ?? 0) })
    }
    value.actionMix = mix(["sport", "sports", "wrestling", "boxing", "martial_arts"])
    value.crowdMix = mix(["crowd"])
    value.landscapeMix = mix(["landscape", "cityscape", "scenery"])
    value.graphicMix = average(
      frames.map { VisionImageTagger.localTag($0.signals) == "graphic" ? 1 : 0 })
    value.aspect = width > height ? .landscape : (width == height ? .square : .portrait)
    value.crop = crop
    value.loudnessDB = loudness.isEmpty ? -120 : median(loudness.filter(\.isFinite))
    // Audio without a music classifier is unknown, never falsely labeled as music.
    value.musicPresence = hasAudio ? .unknown : .absent
    if let transcript {
      value.transcriptAvailable = 1
      let features = TranscriptFeatureAnalyzer.analyze(
        segments: transcript, videoID: 0, speakerKeys: [],
        mediaDuration: duration, deadAirThreshold: 0.3, fillerRunThreshold: 0.3
      ).features
      func ranges(_ kind: TranscriptFeatureSegment.Kind) -> [ClosedRange<Double>] {
        features.filter { $0.kind == kind && $0.endTime >= $0.startTime }.map {
          $0.startTime...$0.endTime
        }
      }
      value.speechFraction = fraction(ranges(.speech) + ranges(.filler), duration: duration)
      value.fillerFraction = fraction(ranges(.filler), duration: duration)
      value.deadAirFraction = fraction(ranges(.silence), duration: duration)
      value.wordsPerMinute =
        Double(transcript.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count })
        * 60 / span
    }
    let text = caption ?? ""
    value.captionLength = text.count
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "#" }.map(
      String.init)
    value.hashtagCount = words.filter { $0.hasPrefix("#") && $0.count > 1 }.count
    value.questionWords =
      words.filter { ["who", "what", "why", "how", "quem", "como", "porqué"].contains($0) }.count
      + (text.contains("?") ? 1 : 0)
    value.hookWords =
      words.filter {
        ["watch", "wait", "secret", "never", "stop", "olha", "nunca", "mira"].contains($0)
      }.count
    if !text.isEmpty {
      switch NLLanguageRecognizer.dominantLanguage(for: text) {
      case .english: value.language = .english
      case .portuguese: value.language = .portuguese
      case .spanish: value.language = .spanish
      case nil: value.language = .unknown
      default: value.language = .other
      }
    }
    return value
  }

  static func applying(caption: String?, to traits: ReelTraits) -> ReelTraits {
    let fields = assemble(
      duration: traits.duration, width: 0, height: 1, detectors: VideoDetectors(),
      frames: [], caption: caption, transcript: nil)
    var updated = traits
    updated.captionLength = fields.captionLength
    updated.hashtagCount = fields.hashtagCount
    updated.questionWords = fields.questionWords
    updated.hookWords = fields.hookWords
    updated.language = fields.language
    return updated
  }

  static func average(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
  }
  static func median(_ values: [Double]) -> Double {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return 0 }
    return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
  }
  static func fraction(_ ranges: [ClosedRange<Double>], duration: Double) -> Double {
    guard duration > 0 else { return 0 }
    var end = 0.0
    var covered = 0.0
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let start = max(end, max(0, range.lowerBound))
      let stop = min(duration, range.upperBound)
      covered += max(0, stop - start)
      end = max(end, stop)
    }
    return min(1, covered / duration)
  }
}
