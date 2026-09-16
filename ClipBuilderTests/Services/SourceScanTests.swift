import Foundation
import Testing
@testable import Clip_Builder

@Suite("Source folder scan", .tags(.integration),
       .enabled(if: FixtureVideo.integrationsAvailable, "Install ffmpeg and ffprobe to run."))
struct SourceScanTests {
    private func makeProfile(input: URL) -> BrandProfile {
        var profile = BrandProfile(name: "Scan test \(UUID().uuidString)")
        profile.sourceFolder = input.path
        return profile
    }

    /// The path as the scan enumerates it: the temp root is reached through
    /// the /var symlink, and URL.resolvingSymlinksInPath strips /private again.
    private func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func age(_ url: URL, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-seconds)],
                                              ofItemAtPath: url.path)
    }

    @Test("A file still being copied is not registered; it registers once, after it settles")
    func copyInProgressWaits() async throws {
        let temp = try TempDatabase()
        let input = realPath(temp.directory.url).appendingPathComponent("Input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let whole = try Data(contentsOf: source)
        let arriving = input.appendingPathComponent("Podcast 02.mp4")
        // The first half, written just now, as a copy in progress looks.
        try whole.prefix(whole.count / 2).write(to: arriving)
        let analyzer = Analyzer(ai: AIService(config: AIConfig()))
        let profile = makeProfile(input: input)
        Analyzer.settlePause = .milliseconds(300)
        defer { Analyzer.settlePause = .seconds(1) }

        // Fresh and unchanged during the pause: the truncated file would be
        // registered by a naive scan. Make it grow during the pause instead.
        let growth = Task {
            try await Task.sleep(for: .milliseconds(100))
            try whole.write(to: arriving)
        }
        let first = try await analyzer.scanSourceFolder(profile: profile, database: temp.database)
        try await growth.value
        #expect(first == Analyzer.SourceScan(discovered: 0, settling: 1, repaired: 0))
        #expect(try await temp.database.fetchVideos().isEmpty)

        // Finished and untouched for a while: registered once, with its duration.
        try age(arriving, seconds: 60)
        let second = try await analyzer.scanSourceFolder(profile: profile, database: temp.database)
        #expect(second == Analyzer.SourceScan(discovered: 1, settling: 0, repaired: 0))
        let videos = try await temp.database.fetchVideos()
        #expect(videos.count == 1 && videos.first?.path == arriving.path && (videos.first?.duration ?? 0) > 2.5)

        // The same file dragged in again changes nothing.
        let third = try await analyzer.scanSourceFolder(profile: profile, database: temp.database)
        #expect(third == Analyzer.SourceScan())
        #expect(try await temp.database.fetchVideos().count == 1)
    }

    @Test("A zero-duration row left by an earlier mid-copy registration is removed once the file has a real row")
    func repairsGhostRegistration() async throws {
        let temp = try TempDatabase()
        let input = realPath(temp.directory.url).appendingPathComponent("Input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let source = try await FixtureVideo.make(in: temp.directory.url, wide: true)
        let file = input.appendingPathComponent("Carlos Prates YT video 1.mov")
        try FileManager.default.copyItem(at: source, to: file)
        try age(file, seconds: 60)
        // What the old scan left behind: the truncated copy's fingerprint, no duration.
        let ghost = try await temp.database.registerVideo(
            hash: "truncated-copy", filename: file.lastPathComponent, path: file.path,
            duration: 0, width: 0, height: 0, wide: false)
        // A row with a zero duration for a different file stays: it is a probe failure, not a duplicate.
        let other = input.appendingPathComponent("unreadable.mov")
        try Data("not a video".utf8).write(to: other)
        try age(other, seconds: 60)

        let analyzer = Analyzer(ai: AIService(config: AIConfig()))
        let scan = try await analyzer.scanSourceFolder(profile: makeProfile(input: input), database: temp.database)
        #expect(scan.discovered == 2 && scan.repaired == 1 && scan.settling == 0)
        let videos = try await temp.database.fetchVideos()
        #expect(!videos.contains { $0.id == ghost })
        #expect(videos.filter { $0.path == file.path }.count == 1)
        #expect(videos.first { $0.path == file.path }.map { $0.duration > 2.5 } == true)
        #expect(videos.contains { $0.path == other.path && $0.duration == 0 })
    }
}
