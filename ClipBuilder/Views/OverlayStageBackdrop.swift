import SwiftUI

/// What the Overlays stage shows behind a template: black, a solid colour,
/// or one frame of a source video. A preview aid kept in user defaults, never
/// written into the template.
struct OverlayStageBackdrop: Equatable {
    enum Mode: String, CaseIterable {
        case black, color, video

        var label: String {
            switch self {
            case .black: "Black"
            case .color: "Colour"
            case .video: "Video"
            }
        }
    }

    struct Frame: Equatable {
        var url: URL
        var time: Double
    }

    var mode: Mode
    var colorHex: String
    var videoPath: String
    var time: Double

    var color: Color {
        mode == .color ? overlayColor(colorHex) : .black
    }

    /// The source frame to draw, or nil for black, colour, or no source chosen.
    var frame: Frame? {
        guard mode == .video, !videoPath.isEmpty else { return nil }
        return Frame(url: URL(fileURLWithPath: videoPath), time: max(0, time))
    }
}
