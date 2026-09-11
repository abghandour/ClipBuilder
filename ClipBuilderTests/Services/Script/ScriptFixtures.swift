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

@MainActor
extension ScriptFixtures {
    /// A document exercising every lane the gap commands touch. `persistent`
    /// loads it the way the app does (Apply requires a persistent timeline);
    /// the default is a transient model for ScriptRunner/session tests.
    static func gapModel(persistent: Bool = false) -> BuilderTimelineModel {
        var document = Fixtures.timelineDocument(clips: [Fixtures.timelineClip()])
        document.normalizeCropBlocks()
        document.videoTrack[0].wide = true
        var bumper = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 5)
        bumper.bumper = true
        bumper.bumperMode = .overlap
        document.videoTrack.append(bumper)
        document.soundTrack = [SoundItem(name: "fixture.mp3")]
        document.textOverlays = [TextOverlayItem(text: "Before")]
        document.imageOverlays = [ImageOverlayItem(path: "/tmp/photo.png")]
        document.overlayBlocks = [OverlayBlockItem()]
        document.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 10)]
        if persistent {
            let model = BuilderTimelineModel()
            model.loadTimeline(id: 1, document: document)
            model.onTimelineAutosave = { _, _ in }
            return model
        }
        let model = BuilderTimelineModel(mode: .transient)
        model.seed(document: document, scenes: [Fixtures.scene()])
        return model
    }

    static func gapLibrary() -> ScriptLibrarySnapshot {
        var result = library()
        result.people = [PersonRecord(id: 1, key: "alex", name: "Alex Smith", descriptor: "Host")]
        result.templates = [OverlayTemplate(name: "Title Card", composition: OverlayComposition(
            texts: [TextOverlayItem(text: "Snapshot title", endTime: 5)]))]
        result.logoPath = "/tmp/logo.png"
        return result
    }

    static func gapCommands(_ model: BuilderTimelineModel) -> [BuilderCommand] {
        let clip = model.document.videoTrack[0].uid.uuidString
        let bumper = model.document.videoTrack[1].uid.uuidString
        let text = model.document.textOverlays[0].uid.uuidString
        return [
            .setBumperMode(clip: bumper, mode: .pause),
            .setCropBlockDuration(block: model.document.cropBlocks[0].uid.uuidString, duration: 8),
            .splitCropBlock(at: 2),
            .removeSound(sound: model.document.soundTrack[0].uid.uuidString),
            .addOverlay(template: "Title Card", at: 1, duration: 4),
            .setImageGeometry(overlay: model.document.imageOverlays[0].uid.uuidString, x: 0.2, y: 0.3, width: 0.4, opacity: 0.6),
            .setOverlayPosition(overlay: text, x: 0.2, y: 0.3),
            .setTextStyle(overlay: text, style: .init(["fontsize": .number(60), "bold": .bool(true)])),
            .setClipVolume(clip: bumper, volume: 2),
            .setClipPosition(clip: clip, position: "top"),
            .setClipCrop(clip: clip, fraction: 0.3),
            .splitZoomFeeds(clip: clip, left: "Left", right: "Right"),
            .clearTimeline
        ]
    }
}
