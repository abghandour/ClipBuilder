import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

/// Plans Interview focus on a real scene of a single-camera interview: refines
/// the roster from faces at the shot starts, prints the camera path, and
/// crops a frame at each keyframe and mid-ramp moment with the rectangle the
/// renderer would show, for judging the framing by eye. Off unless
/// CLIPBUILDER_INTERVIEW_DIAG_DB names a profile database copy;
/// CLIPBUILDER_INTERVIEW_DIAG_SCENE picks the scene,
/// CLIPBUILDER_INTERVIEW_DIAG_OUT the folder for the report and crops.
@Suite("Interview focus diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_INTERVIEW_DIAG_DB"] != nil))
struct InterviewFocusDiagnosticTests {
    @Test("plan Interview focus on a real scene and crop frames along the path")
    @MainActor
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let dbPath = try #require(environment["CLIPBUILDER_INTERVIEW_DIAG_DB"])
        let sceneID = Int64(environment["CLIPBUILDER_INTERVIEW_DIAG_SCENE"] ?? "826") ?? 826
        let out = URL(fileURLWithPath: environment["CLIPBUILDER_INTERVIEW_DIAG_OUT"] ?? dbPath + ".interview")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let database = try Database(path: URL(fileURLWithPath: dbPath))
        let scene = try #require(try await database.fetchScenes(sceneID: sceneID).first)
        let video = try #require(try await database.fetchVideos().first { $0.id == scene.videoID })
        let turns = try await database.fetchSpeakerTurns(videoID: video.id)
        let roster = try await database.fetchVideoPeople(videoID: video.id)
        let range = scene.startTime...scene.endTime
        var report = ["scene \(scene.id) \(scene.startTime)–\(scene.endTime) of \(video.filename) \(video.width)x\(video.height)",
                      "roster: " + roster.map { "\($0.key) vip=\($0.vip.map(String.init) ?? "nil") box=\($0.portraitBox.map { "\($0)" } ?? "-")" }.joined(separator: "; "),
                      "tiles: " + video.podcastTiles.map { "\($0.index):\($0.personKey ?? "?") x=\($0.x) w=\($0.w) face=\($0.faceX ?? -1),\($0.faceY ?? -1)" }.joined(separator: "; "),
                      "turns in range: " + turns.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
                        .map { "\($0.start)-\($0.end) tile=\($0.tile.map(String.init) ?? "?") key=\($0.personKey ?? "?")" }.joined(separator: "; ")]
        var log: [String] = []
        let refined = await InterviewFaceSampling.refinedRoster(video: video, roster: roster, range: range, turns: turns,
                                                                log: { line in log.append(line) })
        report += log
        report.append("refined: " + refined.map { "\($0.key) box=\($0.portraitBox.map { "\($0)" } ?? "-") at=\($0.portraitAt)" }.joined(separator: "; "))
        let plan = try CropRecipePlanner.plan(CropRecipe(kind: .interview), video: video, range: range, turns: turns,
                                              roster: refined, layouts: ScreenCropStore.all(), canvasAspect: 9.0 / 16)
        report.append("layout \(plan.layout.name) slots \(plan.slots.count) notes \(plan.notes)")
        let path = try #require(plan.slots.first?.path)
        for frame in path { report.append(String(format: "  t=%.2f x=%.4f y=%.4f w=%.4f h=%.4f", frame.t, frame.x, frame.y, frame.w, frame.h)) }
        #expect(CenterStageService.pathMatchesCanvas(path, sourceSize: CGSize(width: video.width, height: video.height), canvasAspect: 9.0 / 16))
        let model = BuilderTimelineModel(mode: .transient)
        let result = model.compose(plan, source: .scene(scene), at: 0, highlightTalker: false)
        let clip = try #require(model.document.videoTrack.first)
        report.append("composed \(result.clips.count) clip(s): centerStage=\(clip.centerStage) path=\(clip.cameraPath?.count ?? 0) region=\(clip.areaRegion.map { "\($0)" } ?? "-")")
        // Crop a frame at every keyframe and halfway through every ramp.
        func rect(at t: Double) -> CameraPathKeyframe {
            guard let after = path.firstIndex(where: { $0.t >= t }) else { return path[path.count - 1] }
            guard after > 0 else { return path[0] }
            let a = path[after - 1], b = path[after]
            let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return CameraPathKeyframe(t: t, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f,
                                      w: a.w + (b.w - a.w) * f, h: a.h + (b.h - a.h) * f)
        }
        var moments = path.map(\.t)
        for (a, b) in zip(path, path.dropFirst()) where b.t - a.t > 0.2 && (a.x != b.x || a.w != b.w) { moments.append((a.t + b.t) / 2) }
        for t in Set(moments).sorted() {
            let r = rect(at: t)
            let source = range.lowerBound + t
            let name = String(format: "t%06.2f.png", t)
            let crop = String(format: "crop=iw*%.4f:ih*%.4f:iw*%.4f:ih*%.4f", r.w, r.h, r.x, r.y)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-ss", String(format: "%.3f", source), "-i", video.url.path,
                                 "-frames:v", "1", "-vf", "\(crop),scale=-2:480", out.appendingPathComponent(name).path]
            try process.run(); process.waitUntilExit()
            report.append("crop \(name) at source \(String(format: "%.2f", source)) exit \(process.terminationStatus)")
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
