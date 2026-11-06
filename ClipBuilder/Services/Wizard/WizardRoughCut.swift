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
    /// The same once the sheet's Overlays tab puts the overlay layers back.
    static let leftOutWithOverlays = "cards, bumpers, music, dub, speech polish, looks, B-roll and transitions"
    static func leftOut(overlays: Bool) -> String { overlays ? leftOutWithOverlays : leftOut }

    /// Everything that is not framing turned off, before the document is
    /// built, so the engine also skips the AI work those layers need. The
    /// effect and transition the user added in the review sheet (none by
    /// default) are the one exception, and with `extras.overlays` the
    /// sheet's Overlays tab puts captions, name tags, safe area, watermark
    /// and the overlay design back through Express's own mapping.
    static func options(_ options: WizardOptions, extras: RoughCutExtras = RoughCutExtras()) -> WizardOptions {
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
        rough.lookPreset = extras.look
        rough.lookIntensity = extras.look == nil ? nil : options.lookIntensity
        rough.useBRoll = false
        rough.transitionChoice = extras.transition
        // Random draws from the page's allowed set; a named effect needs
        // only itself; none keeps every boundary a hard cut.
        rough.allowedTransitions = extras.transition == nil ? ["cut"]
            : extras.transition == WizardPlanRules.randomTransitionChoice ? options.allowedTransitions
            : [extras.transition!]
        if let overlays = extras.overlays {
            // The same round trip Express's previewOptions takes.
            var step2 = rough.step2
            overlays.settings.applyOverlayOptions(to: &step2)
            rough = WizardOptions.merge(step1: rough.step1, step2: step2, base: rough)
            // A dubbed reel captions in the dub language; the rough cut has
            // no dub, so the captions follow the same target on their own.
            if overlays.settings.dub, rough.addCaptions {
                rough.captionLanguage = overlays.settings.dubLanguage ?? DubLanguageChoices.defaultLanguage
            }
        }
        return rough
    }

    /// The engine's generated cards, by file name (WizardEngine retains them
    /// under these names); a compilation's intro card is added whatever the
    /// options say.
    static let cardFileNames: Set<String> = ["intro_card.mp4", "outro_card.mp4"]

    /// What the engine adds regardless of options, removed from the built
    /// document: overlay items and blocks, brand layers, sound, dub, clip
    /// effects, transitions, cutaways and generated cards; every clip's
    /// captions off. Removing a leading card closes the gap it left. A
    /// chosen effect or transition stays on the clips, and with
    /// `extras.overlays` so do the overlay items, blocks, brand layers and
    /// captions the options asked for.
    static func strip(_ document: TimelineDocument, extras: RoughCutExtras = RoughCutExtras()) -> TimelineDocument {
        var rough = document
        if extras.overlays == nil {
            rough.textOverlays = []
            rough.imageOverlays = []
            rough.overlayBlocks = []
            rough.brandLayers = nil
        }
        rough.soundTrack = []
        rough.dub = nil
        rough.dubLines = nil
        rough.renderSettings.speechPolish = nil
        rough.videoTrack.removeAll { clip in
            clip.isCutaway || clip.videoFile.map { cardFileNames.contains(URL(fileURLWithPath: $0).lastPathComponent) } == true
        }
        for index in rough.videoTrack.indices {
            if extras.overlays == nil { rough.videoTrack[index].captions = "none" }
            if extras.look == nil { rough.videoTrack[index].effect = nil }
            if extras.transition == nil {
                rough.videoTrack[index].transIn = nil
                rough.videoTrack[index].transOut = nil
            }
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

/// What a rough cut may carry beyond framing: an Effect preset and a
/// transition at every cut, both none unless the review sheet chose them,
/// and Express's Overlays tab choices (nil for the full wizard's plain cut).
nonisolated struct RoughCutExtras: Equatable, Hashable, Sendable {
    /// `EffectCatalog` preset id; nil is none.
    var look: String? = nil
    /// A `TransitionCatalog` name, `WizardPlanRules.randomTransitionChoice`, or nil for hard cuts.
    var transition: String? = nil
    /// The sheet's Overlays tab: Express's settings copy, started from the
    /// page's own. Nil keeps every overlay layer off.
    var overlays: RoughCutOverlays? = nil
}

/// The Overlays tab of the rough cut sheet: the settings the rows bind to
/// and the two page facts that decide which rows show.
nonisolated struct RoughCutOverlays: Equatable, Hashable, Sendable {
    var settings: MiniWizardSettings
    /// Podcast and interview footage: the Name tags rows.
    var showsNameTags = false
    /// A non-English transcript: the Native / English row once captions are on.
    var showsCaptionLanguage = false
}

/// One rendered rough cut, kept in the cache until the next one.
nonisolated struct RoughCut: Equatable, Sendable, Identifiable {
    /// The rendered file; nil until Play renders it (Preview opens the
    /// sheet with the cuts prepared but not rendered).
    var url: URL?
    var name: String
    var duration: Double
    /// The take it was cut from: its `previewClips` carry this id.
    var takeID: Int64? = nil
    var id: String { url?.path ?? "unrendered-\(takeID.map(String.init) ?? name)" }
    var isRendered: Bool { url != nil }

    /// The length an unrendered cut will have: the end of its last preview clip.
    static func plannedDuration(of clips: [WizardPreviewClip]) -> Double {
        clips.map { ($0.outputStart ?? 0) + ($0.outputDuration ?? $0.duration) }.max() ?? 0
    }
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
    /// The effect and transition the cuts were made with.
    var extras: RoughCutExtras = RoughCutExtras()
    /// The takes' footage (ids `take-<takeID>-<index>`), for the still the
    /// sheet draws over a cut once its settings have changed.
    var previewClips: [WizardPreviewClip] = []

    /// False while the sheet shows prepared cuts that Play has yet to render.
    var isRendered: Bool { cuts.allSatisfy(\.isRendered) }

    /// Failed takes are absent from the results; positions do not survive a rerun.
    func cut(forTake takeID: Int64) -> RoughCut? {
        cuts.first { $0.takeID == takeID }
    }
}

/// Everything a rough cut job was started with, kept on the store so the
/// review sheet can run it again with different framing, effect or
/// transition. The takes, page and other options stay as they were.
struct RoughCutRequest {
    var projectID: Int64
    var options: WizardOptions
    var oneReel: Bool
    var cameraFocus: Bool
    var gatherTakes: @Sendable (Database) async throws -> [WizardSelectionTake]
    var combine: @Sendable (Database, [WizardSelectionTake]) async throws -> WizardSelectionTake
    var namespace: String
}
