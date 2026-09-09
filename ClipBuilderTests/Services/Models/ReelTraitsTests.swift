import AppKit
import Foundation
import Testing

@testable import Clip_Builder

@Suite struct ReelTraitsTests {
  nonisolated struct FixtureInspector: ReelFrameInspector {
    var captioned = false
    func inspect(_ data: Data) throws -> VisionImageTagger.Signals {
      .init(labels: [:], faces: [], textArea: captioned ? 0.1 : 0)
    }
    func quality(_ data: Data) -> FrameQuality.Metrics? { .init(luminance: 0.5, variance: 100) }
  }

  @Test func fieldsAreNumbersOrSmallEnums() throws {
    let value = ReelTraits()
    for field in Mirror(reflecting: value).children {
      let mirror = Mirror(reflecting: field.value)
      #expect(
        field.value is Int || field.value is Double || mirror.displayStyle == .enum,
        "Identifying/non-numeric field: \(field.label ?? "unknown")")
    }
    let data = try JSONEncoder().encode(value)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSNumber])
    #expect(object.count == Mirror(reflecting: value).children.count)
  }

  @Test func pureGoldenAndDeterminism() {
    let frames = [0.5, 1.5, 2.5].map {
      ReelTraitExtractor.Frame(
        time: $0, signals: .init(labels: [:], faces: [], textArea: 0),
        quality: .init(luminance: 0.5, variance: 100))
    }
    var golden = ReelTraits()
    golden.duration = 3
    golden.sharpnessMedian = 100
    golden.luminanceMedian = 0.5
    golden.musicPresence = .absent
    let first = ReelTraitExtractor.assemble(
      duration: 3, width: 720, height: 1280, detectors: VideoDetectors(),
      frames: frames, caption: nil, transcript: nil)
    let second = ReelTraitExtractor.assemble(
      duration: 3, width: 720, height: 1280, detectors: VideoDetectors(),
      frames: frames, caption: nil, transcript: nil)
    #expect(first == golden)
    #expect(first == second)
  }

  /// Vision is faked; ffmpeg fixture generation and content-box probing are integration checks.
  @Test(.enabled(if: FixtureVideo.integrationsAvailable))
  @MainActor
  func fixtureVideoPaddedAndCaptionedGoldens() async throws {
    let directory = try TempDirectory()
    let original = try await FixtureVideo.make(in: directory.url, silent: true)
    let padded = try await FixtureVideo.makeLetterboxed(in: directory.url)
    let captioned = directory.url.appendingPathComponent("captioned.mp4")
    let overlay = NSImage(size: NSSize(width: 720, height: 1280))
    overlay.lockFocus()
    ("Fixture caption" as NSString).draw(
      at: NSPoint(x: 40, y: 120),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.white,
      ])
    overlay.unlockFocus()
    let cgImage = try #require(overlay.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let png = try #require(
      NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
    let captionImage = directory.url.appendingPathComponent("caption.png")
    try png.write(to: captionImage)
    _ = try await FFmpeg.run([
      "-y", "-i", original.path, "-i", captionImage.path,
      "-filter_complex", "[0:v][1:v]overlay=0:0", "-an", captioned.path,
    ])
    for (url, crop, text) in [
      (original, ReelTraits.Crop.full, false), (padded, .letterboxed, false),
      (captioned, .full, true),
    ] {
      var golden = ReelTraits()
      golden.duration = 3
      golden.crop = crop
      golden.musicPresence = .absent
      golden.sharpnessMedian = 100
      golden.luminanceMedian = 0.5
      golden.textArea = text ? 0.1 : 0
      golden.textFirstThreeSeconds = text ? 0.1 : 0
      let first = try await ReelTraitExtractor.traits(
        for: url, caption: nil, transcript: nil,
        cachedDetectors: VideoDetectors(), inspector: FixtureInspector(captioned: text))
      let second = try await ReelTraitExtractor.traits(
        for: url, caption: nil, transcript: nil,
        cachedDetectors: VideoDetectors(), inspector: FixtureInspector(captioned: text))
      #expect(first == second)
      // Sum reduction can differ in the final bit from a decimal literal.
      #expect(
        first.features.allSatisfy {
          abs($0.value - (golden.features[$0.key] ?? .infinity)) < 0.000001
        })
    }
  }

  @Test func transcriptAndCaptionStayAnonymous() {
    let traits = ReelTraitExtractor.assemble(
      duration: 10, width: 1080, height: 1920,
      detectors: VideoDetectors(black: [0...1, 0.5...2], frozen: [], cuts: [2, 5]), frames: [],
      caption: "Watch this! Why? #sports #reel",
      transcript: [TranscriptSegment(start: 1, end: 3, text: "um")])
    #expect(traits.blackFraction == 0.2)
    #expect(traits.fillerFraction == 0.2)
    #expect(traits.deadAirFraction == 0.8)
    #expect(traits.hashtagCount == 2)
    #expect(traits.hookWords == 1)
    #expect(traits.questionWords == 2)
  }
}
