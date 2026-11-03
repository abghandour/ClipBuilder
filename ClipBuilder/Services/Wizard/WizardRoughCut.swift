import Foundation

/// A rough cut is the kept reel rendered small and plain so framing and
/// focus can be checked in motion before the final render: a third of the
/// canvas, Compact quality, hard cuts, source audio, nothing laid over the
/// picture. See docs/Rough-Cut-Plan.md.
nonisolated enum WizardRoughCut {
    /// The canvas shrinks by this factor on each side.
    static let scale = 3
    static let minimumSide = 240

    /// What a rough cut leaves out, for the review sheet and the buttons.
    static let leftOut = "captions, name tags, overlays, watermark, cards, bumpers, music, dub, speech polish, looks, B-roll and transitions"

    /// Everything that is not framing turned off, before the document is
    /// built, so the engine also skips the AI work those layers need.
    static func options(_ options: WizardOptions) -> WizardOptions {
        var rough = options
        let width = options.renderSettings.width
        let height = options.renderSettings.height
        // One factor for both sides: the crop geometry must match Generate's.
        var factor = 1.0 / Double(scale)
        let shortest = Double(min(width, height))
        if shortest * factor < Double(minimumSide) { factor = min(1, Double(minimumSide) / shortest) }
        rough.renderSettings.preset = .custom
        rough.renderSettings.customWidth = even(Int((Double(width) * factor).rounded()))
        rough.renderSettings.customHeight = even(Int((Double(height) * factor).rounded()))
        rough.renderSettings.quality = .compact
        rough.renderSettings.speechPolish = nil
        rough.addCaptions = false
        rough.enableTextOverlays = false
        rough.nameTags = false
        rough.nameTagsOnly = nil
        rough.useMusic = false
        rough.musicTrack = nil
        rough.muteSource = false
        rough.dubLanguage = nil
        rough.includeWatermark = false
        rough.includeHeadline = false
        rough.includeOutro = false
        rough.includeIntroBumper = false
        rough.includeOutroBumper = false
        rough.includeMiddleBumper = false
        rough.introBumperPath = nil
        rough.outroBumperPath = nil
        rough.watermarkOverlayTemplate = nil
        rough.fixedOverlayTemplate = nil
        rough.pinnedOverlayTemplate = nil
        rough.pinnedOverlayText = nil
        rough.strikeStats = false
        rough.strikeSpeedCallouts = false
        rough.strikeGrapplingCard = false
        rough.strikeRoundCard = false
        rough.lookPreset = nil
        rough.lookIntensity = nil
        rough.useBRoll = false
        rough.transitionChoice = nil
        rough.allowedTransitions = ["cut"]
        return rough
    }

    /// The engine's generated cards, by file name (WizardEngine retains them
    /// under these names); a compilation's intro card is added whatever the
    /// options say.
    static let cardFileNames: Set<String> = ["intro_card.mp4", "outro_card.mp4"]

    /// What the engine adds regardless of options, removed from the built
    /// document: overlay items and blocks, brand layers, sound, dub, clip
    /// effects, transitions, cutaways and generated cards; every clip's
    /// captions off. Removing a leading card closes the gap it left.
    static func strip(_ document: TimelineDocument) -> TimelineDocument {
        var rough = document
        rough.textOverlays = []
        rough.imageOverlays = []
        rough.overlayBlocks = []
        rough.brandLayers = nil
        rough.soundTrack = []
        rough.dub = nil
        rough.dubLines = nil
        rough.renderSettings.speechPolish = nil
        rough.videoTrack.removeAll { clip in
            clip.isCutaway || clip.videoFile.map { cardFileNames.contains(URL(fileURLWithPath: $0).lastPathComponent) } == true
        }
        for index in rough.videoTrack.indices {
            rough.videoTrack[index].captions = "none"
            rough.videoTrack[index].effect = nil
            rough.videoTrack[index].transIn = nil
            rough.videoTrack[index].transOut = nil
        }
        if let first = rough.videoTrack.map(\.startTime).min(), first > 0 {
            for index in rough.videoTrack.indices { rough.videoTrack[index].startTime -= first }
        }
        return rough
    }

    private static func even(_ value: Int) -> Int {
        let clamped = max(minimumSide, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }
}

/// One rendered rough cut, kept in the cache until the next one.
nonisolated struct RoughCut: Equatable, Sendable, Identifiable {
    var url: URL
    var name: String
    var duration: Double
    var id: String { url.path }
}

/// A finished rough cut job: the cuts to play, the framing they were cut
/// with (editable in the sheet) and where Apply and Generate go.
nonisolated struct RoughCutReview: Equatable, Sendable {
    var projectID: Int64
    var cuts: [RoughCut]
    /// The assistant namespace of the page that asked ("express" or "full"),
    /// so the sheet's Apply and Generate reach that page's own controls.
    var namespace: String
    /// The stored request the sheet re-runs with edited framing.
    var requestID: UUID
    /// The framing the cuts were made with; the sheet's controls start here.
    var framing: Framing
    /// What the framing rows need: the footage type, the recordings and the canvas shape.
    var sourceType: VideoType
    var videoIDs: [Int64]
    var canvasAspect: Double
}

/// Everything a rough cut job was started with, kept on the store so the
/// review sheet can run it again with different framing. Only the framing
/// changes between runs; the takes, page and options stay as they were.
struct RoughCutRequest {
    var projectID: Int64
    var options: WizardOptions
    var oneReel: Bool
    var cameraFocus: Bool
    var gatherTakes: @Sendable (Database) async throws -> [WizardSelectionTake]
    var combine: @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake
    var namespace: String
}
