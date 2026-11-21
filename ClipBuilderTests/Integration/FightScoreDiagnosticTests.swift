import AppKit
import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

/// Runs the fight scoring pass on a real recording with the real provider and
/// writes the events it logged, for judging sampling and prompt changes
/// against the same fight. Off unless CLIPBUILDER_FIGHT_DIAG_DB names a
/// profile database copy whose video (CLIPBUILDER_FIGHT_DIAG_VIDEO) points
/// at a local file outside ~/Documents; the report goes to
/// CLIPBUILDER_FIGHT_DIAG_REPORT. CLIPBUILDER_FIGHT_DIAG_PROVIDER and
/// CLIPBUILDER_FIGHT_DIAG_MODEL choose who scores (default: the app's routing).
@Suite("Fight score diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_FIGHT_DIAG_DB"] != nil))
struct FightScoreDiagnosticTests {
    @Test("score the reference fight and report the events", .timeLimit(.minutes(60)))
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let dbPath = try #require(environment["CLIPBUILDER_FIGHT_DIAG_DB"])
        let videoID = try #require(Int64(environment["CLIPBUILDER_FIGHT_DIAG_VIDEO"] ?? ""))
        let reportPath = environment["CLIPBUILDER_FIGHT_DIAG_REPORT"] ?? dbPath + ".report.txt"
        let database = try Database(path: URL(fileURLWithPath: dbPath))
        let video = try #require(try await database.fetchVideos().first { $0.id == videoID })
        let before = try await database.fetchFightEvents().filter { $0.videoID == videoID }
        var profile = BrandProfile(name: "Diagnostic")
        profile.contentDomain = "MMA"

        let lines = Mutex<[String]>([])
        let started = ContinuousClock.now
        let count = try await Analyzer(ai: AIService(config: AIConfig())).scoreFightAction(
            video: video, profile: profile, database: database,
            provider: environment["CLIPBUILDER_FIGHT_DIAG_PROVIDER"], model: environment["CLIPBUILDER_FIGHT_DIAG_MODEL"],
            log: { line in lines.withLock { $0.append(line) } })
        let elapsed = (ContinuousClock.now - started).seconds
        let events = try await database.fetchFightEvents().filter { $0.videoID == videoID }.sorted { $0.time < $1.time }

        func digest(_ events: [FightEventRecord]) -> String {
            FightScoreDigest.fighters(events: events).map { FightScoreDigest.line($0, name: $0.key.isEmpty ? "unattributed" : $0.key) }
                .joined(separator: "\n  ")
        }
        var report = "\(video.filename): \(count) event(s) in \(Int(elapsed)) s\n"
        report += "before (\(before.count) events):\n  \(digest(before))\nafter (\(events.count) events):\n  \(digest(events))\n\nevents:\n"
        for event in events {
            let finish = event.endTime.map { String(format: "–%.2f", $0) } ?? ""
            report += String(format: "%7.2f%@  %@  %@", event.time, finish,
                             event.fighterKey.isEmpty ? "?" : event.fighterKey, event.action)
                + (event.outcome.map { " · \($0)" } ?? "") + "\n"
        }
        report += "\nlog:\n" + lines.withLock { $0.joined(separator: "\n") } + "\n"
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        #expect(count == events.count)
    }
}

/// Builds the strike highlight for given moments of a real recording and
/// writes one picture per moment (the contact frame with the highlight
/// drawn), for judging the pose rules by eye. Off unless
/// CLIPBUILDER_STRIKE_HIGHLIGHT_VIDEO names a local file outside ~/Documents;
/// CLIPBUILDER_STRIKE_HIGHLIGHT_TIMES is "12.5,34.57:kick|left|legs|" (time,
/// optionally a stored strike detail), CLIPBUILDER_STRIKE_HIGHLIGHT_OUT the folder.
@Suite("Strike highlight diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_STRIKE_HIGHLIGHT_VIDEO"] != nil))
struct StrikeHighlightDiagnosticTests {
    @Test("draw the highlight on the contact frame of each strike", .timeLimit(.minutes(10)))
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(environment["CLIPBUILDER_STRIKE_HIGHLIGHT_VIDEO"]))
        let out = URL(fileURLWithPath: try #require(environment["CLIPBUILDER_STRIKE_HIGHLIGHT_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report = ""
        for item in (environment["CLIPBUILDER_STRIKE_HIGHLIGHT_TIMES"] ?? "").split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let time = try #require(Double(parts[0]))
            let detail = StrikeDetail(parts.count > 1 ? parts[1] : nil)
            let started = ContinuousClock.now
            let track = await StrikeHighlightFinder.find(url: url, time: time, detail: detail).track
            let took = (ContinuousClock.now - started).seconds
            guard let track, let contact = track.keyframes.min(by: { abs($0.time - track.contact) < abs($1.time - track.contact) }) else {
                report += String(format: "%.2f  none (%.1f s)\n", time, took)
                continue
            }
            #expect(track.contact >= time - StrikeHighlightRules.contactWindow
                    && track.contact <= time + StrikeHighlightRules.contactWindow)
            report += String(format: "%.2f  %@ %@, attacker %@, contact %.2f, cost %.2f, %d keyframes %.2f–%.2f (%.1f s)\n",
                             time, contact.highlight.limbSide.rawValue, contact.highlight.usesArm ? "arm" : "leg",
                             contact.highlight.attackerOnLeft ? "left" : "right", contact.time, contact.highlight.cost,
                             track.keyframes.count, track.start, track.end, took)
            let stills = await ThumbnailService.jpegFrames(url: url, at: [contact.time], maxDimension: 960, tolerance: 0)
            guard let jpeg = stills.first ?? nil, let rep = NSBitmapImageRep(data: jpeg), let image = rep.cgImage,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.draw(image, in: rect)
            StrikeHighlightPainter.draw(contact.highlight, opacity: 1, in: context, rect: rect, topLeftOrigin: false)
            let label = NSAttributedString(string: String(format: "%.2f ", time) + parts.dropFirst().reversed().joined(separator: " "),
                attributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.yellow,
                             .backgroundColor: NSColor.black])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            label.draw(at: CGPoint(x: 8, y: 8))
            NSGraphicsContext.restoreGraphicsState()
            if let drawn = context.makeImage() {
                try NSBitmapImageRep(cgImage: drawn).representation(using: .jpeg, properties: [.compressionFactor: 0.7])?
                    .write(to: out.appendingPathComponent(String(format: "strike_%06.2f.jpg", time)))
            }
        }
        try report.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
