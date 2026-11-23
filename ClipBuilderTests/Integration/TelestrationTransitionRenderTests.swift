import Foundation
import Synchronization
import Testing
@testable import Clip_Builder

@Suite("Staying figure overlap pixels", .enabled(if: FixtureVideo.integrationsAvailable))
struct TelestrationTransitionRenderTests {
    @Test(arguments: ["fade", "dissolve"], [false, true])
    func strengthAndPosition(name: String, fallback: Bool) async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        var doc = StayRenderFixture.document(source: input, linger: 0.4)
        if fallback {
            // An anisotropic free crop on both sides has matching first-frame
            // source placement, while deliberately taking the source fallback.
            for i in doc.videoTrack.indices {
                doc.videoTrack[i].freeCrops = [.init(src: .init(wFrac: 0.8), dst: .init())]
            }
        }
        let plain = try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: plain.url) }
        doc.videoTrack[1].transIn = name
        let joined = try await StayRenderFixture.renderer(folder).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: joined.url) }
        let pieces = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: []))
        let overlaps = MultitrackRenderer.crossfadeOverlaps(durations: pieces.segments.map(\.duration),
            transitions: pieces.transitions, transitionDuration: RenderContext.transitions.xfadeDuration)
        let overlap = (try #require(overlaps[0]) * 30).rounded() / 30
        let join = doc.videoTrack[0].duration
        for elapsed in [0.0, (overlap * 15).rounded(.down) / 30, overlap - 1.0 / 30] {
            let reference = try await StayRenderFixture.pixels(plain.url, time: join + elapsed, folder: folder)
            let actual = try await StayRenderFixture.pixels(joined.url, time: join - overlap + elapsed, folder: folder)
            #expect(reference.count == actual.count && actual.count == 640 * 360 * 3)
            // Compare the complete figure footprint and strength, not bytes or
            // a single favorable point. Codec noise is below the 5% allowance.
            let positions = stride(from: 0, to: reference.count, by: 3).filter {
                reference[$0] > 30 && reference[$0 + 1] > 30 && reference[$0 + 2] < 20
            }
            #expect(!positions.isEmpty)
            let energy = positions.reduce(0.0) { $0 + Double(reference[$1]) + Double(reference[$1 + 1]) }
            let error = positions.reduce(0.0) {
                $0 + abs(Double(actual[$1]) - Double(reference[$1])) + abs(Double(actual[$1 + 1]) - Double(reference[$1 + 1]))
            }
            #expect(error / max(1, energy) <= 0.05)
            let extra = stride(from: 0, to: actual.count, by: 3).filter {
                actual[$0] > 50 && actual[$0 + 1] > 50 && reference[$0] < 20
            }
            #expect(extra.count <= 4)
        }
    }

    @Test func movingTransitionLogsOnce() async throws {
        let temp = try await TempDatabase()
        let input = temp.directory.url.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        var doc = StayRenderFixture.document(source: input)
        doc.videoTrack[1].transIn = "zoom_punch"
        let logs = Mutex<[String]>([])
        let result = try await StayRenderFixture.renderer(temp.directory.url).render(document: doc, scenes: [],
            profile: Fixtures.brand(), database: temp.database, preview: true,
            emit: { line in logs.withLock { $0.append(line) } })
        defer { try? FileManager.default.removeItem(at: result.url) }
        #expect(logs.withLock { $0.filter { $0 == TelestrationTransition.cutMessage }.count } == 1)
        #expect(doc.videoTrack[1].transIn == "zoom_punch")
    }

    @Test func previewEndingInsideOverlapMatchesExportPixels() async throws {
        let temp = try await TempDatabase()
        let folder = temp.directory.url
        let input = folder.appendingPathComponent("source.mp4")
        try await StayRenderFixture.source(input)
        var doc = StayRenderFixture.document(source: input, linger: 0.4)
        doc.videoTrack[1].transIn = "fade"
        let renderer = StayRenderFixture.renderer(folder)
        let full = try await renderer.render(document: doc, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: full.url) }
        let join = doc.videoTrack[0].duration
        let lower = join - 0.3
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: lower, to: join - 1.0 / 30)
        let preview = try await renderer.render(document: window.document, scenes: [], profile: Fixtures.brand(),
            database: temp.database, preview: true, lingering: window.lingering, lingerHolds: window.lingerHolds,
            stayTransitions: window.stayTransitions, emit: { _ in })
        defer { try? FileManager.default.removeItem(at: preview.url) }
        for elapsed in [0.0, 0.1, 0.2] {
            let expected = try await StayRenderFixture.pixels(full.url, time: lower + elapsed, folder: folder)
            let actual = try await StayRenderFixture.pixels(preview.url, time: elapsed, folder: folder)
            #expect(expected.count == actual.count)
            let energy = expected.reduce(0.0) { $0 + Double($1) }
            let error = zip(expected, actual).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            #expect(energy > 0 && error / energy <= 0.05)
        }
    }

}
