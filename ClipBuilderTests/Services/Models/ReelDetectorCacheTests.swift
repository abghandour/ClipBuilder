import Foundation
import Testing
@testable import Clip_Builder

@Suite struct ReelDetectorCacheTests {
  private enum Failure: Error { case expected }

  @Test func fullContentIdentityAndInvalidation() async throws {
    let temp = try TempDirectory()
    let first = temp.url.appendingPathComponent("first.mp4")
    let renamed = temp.url.appendingPathComponent("renamed.mp4")
    var bytes = Data(repeating: 7, count: 3 * 1024 * 1024)
    try bytes.write(to: first)
    try bytes.write(to: renamed)
    let originalDate = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let key = try await ReelDetectorCache.key(for: first, duration: 80, runtime: "ffmpeg A")
    #expect(try await ReelDetectorCache.key(for: renamed, duration: 80, runtime: "ffmpeg A") == key)
    bytes[bytes.count / 2] = 8
    try bytes.write(to: first)
    if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: first.path) }
    #expect(try await ReelDetectorCache.key(for: first, duration: 80, runtime: "ffmpeg A") != key)
    #expect(try await ReelDetectorCache.key(for: renamed, duration: 81, runtime: "ffmpeg A") != key)
    #expect(try await ReelDetectorCache.key(for: renamed, duration: 80, runtime: "ffmpeg B") != key)
    #expect(try await ReelDetectorCache.key(for: renamed, duration: 80, runtime: "ffmpeg A", version: "v2") != key)
  }

  @Test func restoresAcrossInstancesAndRecoversCorruption() async throws {
    let temp = try TempDirectory()
    let media = temp.url.appendingPathComponent("video.mp4")
    try Data("media".utf8).write(to: media)
    let root = temp.url.appendingPathComponent("cache")
    let cache = ReelDetectorCache(directory: root)
    let expected = VideoDetectors(black: [1...2], frozen: [3...5], cuts: [2, 6])
    _ = try await cache.detectors(for: media, duration: 10, runtime: "tool") { expected }
    let restored = try await ReelDetectorCache(directory: root).detectors(for: media, duration: 10, runtime: "tool") {
      throw Failure.expected
    }
    #expect(restored.black == expected.black && restored.frozen == expected.frozen && restored.cuts == expected.cuts)
    let key = try await ReelDetectorCache.key(for: media, duration: 10, runtime: "tool")
    try Data("broken".utf8).write(to: root.appendingPathComponent(key + ".json"))
    let recovered = try await cache.detectors(for: media, duration: 10, runtime: "tool") { VideoDetectors(cuts: [7]) }
    #expect(recovered.cuts == [7])
  }

  @Test func failedAndCancelledScansDoNotPublish() async throws {
    let temp = try TempDirectory()
    let media = temp.url.appendingPathComponent("video.mp4")
    try Data("media".utf8).write(to: media)
    let root = temp.url.appendingPathComponent("cache")
    let cache = ReelDetectorCache(directory: root)
    do {
      _ = try await cache.detectors(for: media, duration: 10, runtime: "tool") { throw Failure.expected }
      Issue.record("Expected scan failure")
    } catch Failure.expected { }
    let task = Task {
      try await cache.detectors(for: media, duration: 10, runtime: "tool") {
        withUnsafeCurrentTask { $0?.cancel() }
        return VideoDetectors(cuts: [1])
      }
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError { }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let retried = try await cache.detectors(for: media, duration: 10, runtime: "tool") { VideoDetectors(cuts: [2]) }
    #expect(retried.cuts == [2])
  }

  @Test func changedSourceAndUnwritableCacheDoNotPublish() async throws {
    let temp = try TempDirectory()
    let media = temp.url.appendingPathComponent("video.mp4")
    try Data("media".utf8).write(to: media)
    let root = temp.url.appendingPathComponent("cache")
    let cache = ReelDetectorCache(directory: root)
    _ = try await cache.detectors(for: media, duration: 10, runtime: "tool") {
      try Data("different media length".utf8).write(to: media)
      return VideoDetectors(cuts: [1])
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try Data("not a directory".utf8).write(to: root)
    let result = try await cache.detectors(for: media, duration: 10, runtime: "tool") { VideoDetectors(cuts: [2]) }
    #expect(result.cuts == [2])
  }

  @Test(.enabled(if: FixtureVideo.integrationsAvailable))
  @MainActor
  func cachedAndUncachedExtractionMatch() async throws {
    let temp = try TempDirectory()
    let media = try await FixtureVideo.make(in: temp.url, silent: true)
    let copy = temp.url.appendingPathComponent("copy.mp4")
    try FileManager.default.copyItem(at: media, to: copy)
    let cache = ReelDetectorCache(directory: temp.url.appendingPathComponent("cache"))
    let inspector = ReelTraitsTests.FixtureInspector()
    let cold = try await ReelTraitExtractor.traits(for: media, caption: nil, transcript: nil,
      detectorCache: cache, inspector: inspector)
    let warm = try await ReelTraitExtractor.traits(for: copy, caption: nil, transcript: nil,
      detectorCache: cache, inspector: inspector)
    let control = try await ReelTraitExtractor.traits(for: copy, caption: nil, transcript: nil, inspector: inspector)
    #expect(cold == warm && warm == control)
    let changed = try await ReelTraitExtractor.traits(for: copy, caption: "Watch this?", transcript: [],
      detectorCache: cache, inspector: inspector)
    #expect(changed.cutCount == control.cutCount)
    #expect(changed.captionLength > control.captionLength)
    #expect(changed.transcriptAvailable == 1 && control.transcriptAvailable == 0)
  }

  @Test func boundedStorage() async throws {
    let temp = try TempDirectory()
    let media = temp.url.appendingPathComponent("video.mp4")
    try Data("media".utf8).write(to: media)
    let root = temp.url.appendingPathComponent("cache")
    let value = VideoDetectors(cuts: [1, 2])
    let limit = try JSONEncoder().encode(value).count * 2
    let cache = ReelDetectorCache(directory: root, byteLimit: limit, entryLimit: 2)
    for duration in 10...15 {
      _ = try await cache.detectors(for: media, duration: Double(duration), runtime: "tool") { value }
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
    #expect(bytes <= limit && files.count <= 2)
    let newest = try await cache.detectors(for: media, duration: 15, runtime: "tool") { throw Failure.expected }
    #expect(newest.cuts == value.cuts)
  }
}
