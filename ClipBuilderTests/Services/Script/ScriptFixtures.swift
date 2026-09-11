import Foundation
@testable import Clip_Builder

@MainActor
enum ScriptFixtures {
    static func model(clips: [TimelineClip]? = nil) -> BuilderTimelineModel {
        let model = BuilderTimelineModel(mode: .transient)
        var document = Fixtures.timelineDocument(clips: clips ?? [Fixtures.timelineClip()])
        document.normalizeCropBlocks()
        model.seed(document: document, scenes: [Fixtures.scene()])
        return model
    }

    static func library() -> ScriptLibrarySnapshot {
        var result = ScriptLibrarySnapshot(projectID: 1)
        result.videos = [Fixtures.video()]
        result.scenes = [Fixtures.scene()]
        result.layouts = ScreenCropStore.builtIn
        result.bumpers = ["intro": BumperAsset(path: "/tmp/intro.mp4", displayName: "Intro", duration: 1)]
        result.sounds = ["music": "fixture.mp3"]
        result.images = ["photo": "/tmp/photo.png"]
        return result
    }

    static func session(clips: [TimelineClip]? = nil) -> BuilderScriptSession {
        BuilderScriptSession(live: model(clips: clips), library: library())
    }
}
