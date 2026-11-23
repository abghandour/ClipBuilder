import Foundation

/// Row metadata only: the editor still belongs to the containing page.
nonisolated struct TelestrationSource: Hashable, Sendable {
    var videoID: Int64
    var videoURL: URL
    var name: String
    var range: ClosedRange<Double>
    var areaName: String? = nil
    var mainAreaName: String? = nil

    var menuName: String {
        areaName.map { "\(name) (\($0))" } ?? name
    }

    static func drawingTime(_ time: Double) -> String {
        (time.isFinite ? floor(max(0, time)) : 0).timecode
    }

    static func drawingLabel(_ drawing: Telestration) -> String {
        "\(drawingTime(drawing.time)) · \(drawing.figures.count) \(drawing.figures.count == 1 ? "figure" : "figures")"
    }

    /// "0:21 · 2 figures", with the picture's speed when it keeps moving.
    static func drawingSummary(_ drawing: Telestration) -> String {
        drawingLabel(drawing) + (drawing.motion.map { " · picture at \(TelestrationPlayback.label($0).lowercased())" } ?? " · paused")
    }

    static func companions(clip: WizardPlanClip, sceneMap: [Int64: SceneRecord]) -> [Self] {
        clip.areaClips.compactMap { area in
            let end = min(area.end, area.start + clip.end - clip.start)
            guard let scene = sceneMap[area.sceneID], area.start.isFinite, end.isFinite, end > area.start else { return nil }
            let mainArea = ScreenCropStore.area(reference: clip.screenCrop)?.name
                ?? clip.layout.flatMap { ScreenCropStore.layout(named: $0)?.areas.first?.name }
            return Self(videoID: scene.videoID, videoURL: scene.videoURL,
                name: scene.videoFilename, range: area.start...end,
                areaName: area.area, mainAreaName: mainArea)
        }
    }
}
