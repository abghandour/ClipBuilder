import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Expansion source continuity and eligibility")
struct BuilderExpansionFramingTests {
    @Test func speedPreservesSourceStartAndUsesInspectorRounding() {
        for speed in [0.5, 0.75, 1.5, 2.0] {
            let model = ScriptFixtures.model()
            let clip = model.document.videoTrack[0]
            let result = ScriptRunner().run([.init(.setClipSpeed(clip: clip.uid.uuidString, speed: speed))],
                                            model: model, library: ScriptFixtures.library())
            #expect(!result.contains { $0.isRefused })
            let after = model.document.videoTrack[0]
            #expect(after.sourceStart == clip.sourceStart && after.sourceEnd == clip.sourceEnd)
            #expect(after.duration == ((clip.sourceSpan / speed) * 10).rounded() / 10)
            #expect(abs(after.sourceSpan - clip.sourceSpan) <= speed * 0.05 + 1e-9)
        }
    }

    @Test func speedRefusesRoundingPastSourceAndClampsCutawayFades() {
        var clip = Fixtures.timelineClip(sourceStart: 0, duration: 4)
        clip.sceneID = nil
        var library = ScriptFixtures.library()
        library.videos[0].duration = 4
        let model = ScriptFixtures.model(clips: [clip])
        let before = model.document
        let result = ScriptRunner().run([.init(.setClipSpeed(clip: clip.uid.uuidString, speed: 1.5))],
                                        model: model, library: library)
        #expect(result.contains { $0.isRefused }) // 2.7 × 1.5 exceeds four source seconds.
        #expect(ScriptValue.stored(model.document) == ScriptValue.stored(before))

        clip.role = .cutaway
        clip.fadeIn = 2; clip.fadeOut = 2
        let cutaway = ScriptFixtures.model(clips: [clip])
        let edited = ScriptRunner().run([.init(.setClipSpeed(clip: clip.uid.uuidString, speed: 2))],
                                        model: cutaway, library: ScriptFixtures.library())
        #expect(!edited.contains { $0.isRefused })
        #expect(cutaway.document.videoTrack[0].fadeIn == 1 && cutaway.document.videoTrack[0].fadeOut == 1)
    }

    @Test func cutawayFadesAndCaptions() {
        var clip = Fixtures.timelineClip()
        clip.role = .cutaway
        let model = ScriptFixtures.model(clips: [clip])
        let command = BuilderCommand.setClipFades(clip: clip.uid.uuidString, fadeIn: 0.2, fadeOut: 0.3)
        let runner = ScriptRunner()
        #expect(!runner.run([.init(command)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        #expect(model.document.videoTrack[0].fadeIn == 0.2 && model.document.videoTrack[0].fadeOut == 0.3)
        guard case .unchanged = runner.run([.init(command)], model: model, library: ScriptFixtures.library()).first else {
            Issue.record("Fades must be idempotent"); return
        }
        for command in [BuilderCommand.setClipFades(clip: clip.uid.uuidString, fadeIn: 3, fadeOut: 0),
                        .setClipCaptions(clip: clip.uid.uuidString, captions: "bottom"),
                        .setClipCenterStage(clip: clip.uid.uuidString, enabled: true)] {
            #expect(runner.run([.init(command)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        }
    }

    @Test func trackingAndAreaFramingRequireEditableContext() throws {
        var clip = Fixtures.timelineClip()
        clip.wide = true
        let model = ScriptFixtures.model(clips: [clip])
        let runner = ScriptRunner()
        let tracking = BuilderCommand.setClipCenterStage(clip: clip.uid.uuidString, enabled: true)
        #expect(!runner.run([.init(tracking)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        #expect(model.document.videoTrack[0].centerStage)
        guard case .unchanged = runner.run([.init(tracking)], model: model, library: ScriptFixtures.library()).first else {
            Issue.record("Tracking must be idempotent"); return
        }
        let window = BuilderCommand.setClipAreaWindow(clip: clip.uid.uuidString, x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        #expect(runner.run([.init(window)], model: model, library: ScriptFixtures.library()).contains { $0.isRefused })
        let library = ScriptFixtures.library()
        let layout = try #require(library.layouts.first { !$0.areas.isEmpty })
        library.withLayouts {
            model.setCropLayout(CropLayoutRef(name: layout.name), for: model.document.cropBlocks[0].uid)
        }
        let area = try #require(library.withLayouts { model.area(forTrack: 0, at: 0) })
        let defaultWindow = AreaFramer.defaultWindow(for: area, sourceSize: CGSize(width: 1920, height: 1080))
        let width = defaultWindow.wFrac / 2
        let height = defaultWindow.hFrac / 2
        let fitted = BuilderCommand.setClipAreaWindow(clip: clip.uid.uuidString, x: 0.1, y: 0.2, width: width, height: height)
        #expect(!runner.run([.init(fitted)], model: model, library: library).contains { $0.isRefused })
        #expect(model.document.videoTrack[0].areaWindow == FreeCropRect(xFrac: 0.1, yFrac: 0.2, wFrac: width, hFrac: height))
        guard case .unchanged = runner.run([.init(fitted)], model: model, library: library).first else {
            Issue.record("Area window must be idempotent"); return
        }
    }
}
