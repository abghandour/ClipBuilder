import Foundation
import Testing
@testable import Clip_Builder

/// Composes a real scene by every crop recipe and prints what lands in the
/// timeline document and its lane layout, for judging a Builder report
/// against real speaker turns. Off unless CLIPBUILDER_COMPOSE_DIAG_DB
/// names a profile database copy; CLIPBUILDER_COMPOSE_DIAG_SCENE picks the
/// scene (default 586).
@Suite("Compose diagnostic",
       .enabled(if: ProcessInfo.processInfo.environment["CLIPBUILDER_COMPOSE_DIAG_DB"] != nil))
struct ComposeDiagnosticTests {
    @Test("compose a scene by every recipe and report the document")
    @MainActor
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let dbPath = try #require(environment["CLIPBUILDER_COMPOSE_DIAG_DB"])
        let sceneID = Int64(environment["CLIPBUILDER_COMPOSE_DIAG_SCENE"] ?? "586") ?? 586
        let database = try Database(path: URL(fileURLWithPath: dbPath))
        let scene = try #require(try await database.fetchScenes(sceneID: sceneID).first)
        let video = try #require(try await database.fetchVideos().first { $0.id == scene.videoID })
        let turns = try await database.fetchSpeakerTurns(videoID: video.id)
        let roster = try await database.fetchVideoPeople(videoID: video.id)
        var report: [String] = ["scene \(scene.id) \(scene.startTime)–\(scene.endTime) of \(video.filename); \(turns.count) turns; roster \(roster.map(\.key))",
                                "tiles: \(video.podcastTiles.map { "\($0.index):\($0.personKey ?? "?") \($0.x),\($0.y),\($0.w),\($0.h)" })"]
        for kind in CropRecipe.Kind.allCases {
            for highlight in [false, true] {
                let model = BuilderTimelineModel(mode: .transient)
                let recipe = CropRecipe(kind: kind, highlightTalker: highlight)
                do {
                    let plan = try CropRecipePlanner.plan(recipe, video: video, range: scene.startTime...scene.endTime,
                                                          turns: turns, roster: roster, layouts: ScreenCropStore.all(),
                                                          canvasAspect: model.document.renderSettings.aspectRatio)
                    let result = model.compose(plan, source: .scene(scene), at: 0, highlightTalker: highlight)
                    let document = model.document
                    let layout = model.timelineLayout()
                    report.append("== \(kind.name) highlight=\(highlight): \(result.clips.count) clips, layout \(plan.layout), slots \(plan.slots.count), notes \(plan.notes)")
                    report.append("  trackCount \(document.trackCount) sequential \(document.trackSequential) totalDuration \(model.totalDuration) contentWidth \((model.totalDuration + 15) * Double(model.pointsPerSecond))")
                    report.append("  cropBlocks \(document.cropBlocks.map { "\($0.startTime)+\($0.duration) \($0.layout)" })")
                    for clip in document.videoTrack.sorted(by: { ($0.track, $0.startTime) < ($1.track, $1.startTime) }) {
                        report.append("  clip track \(clip.track) start \(clip.startTime) dur \(clip.duration) src \(clip.sourceStart ?? -1)…\(clip.sourceEnd ?? -1) muted \(clip.muted) area \(clip.areaWindow.map { "\($0)" } ?? "-") region \(clip.areaRegion.map { "\($0)" } ?? "-") path \(clip.cameraPath?.count ?? 0) effect \(clip.effect?.preset ?? "-") cutaway \(clip.isCutaway)")
                    }
                    for (index, track) in layout.videoTracks.enumerated() {
                        report.append("  lane \(index): rows \(track.rowCount) cutawayRows \(track.cutawayRowCount) height \(track.laneHeight) rowsByClip \(track.rows.values.sorted())")
                    }
                    let values: [Double] = document.videoTrack.flatMap { clip -> [Double] in [clip.startTime, clip.duration, clip.sourceStart ?? 0, clip.sourceEnd ?? 0] }
                        + document.cropBlocks.flatMap { block -> [Double] in [block.startTime, block.duration] }
                    let finite = values.allSatisfy { $0.isFinite }
                    let trackCount = document.trackCount
                    let onLanes = document.videoTrack.allSatisfy { $0.track < trackCount }
                    let positive = document.videoTrack.allSatisfy { $0.duration > 0 }
                    #expect(finite, "\(kind.name): non-finite value in the document")
                    #expect(onLanes, "\(kind.name): a clip sits on a track the layout has no lane for")
                    #expect(positive, "\(kind.name): a clip has no duration")
                } catch {
                    report.append("== \(kind.name) highlight=\(highlight): plan failed — \(error)")
                }
            }
        }
        let path = environment["CLIPBUILDER_COMPOSE_DIAG_REPORT"] ?? dbPath + ".compose.txt"
        try report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
