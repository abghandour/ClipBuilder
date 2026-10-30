import Foundation
import Testing
@testable import Clip_Builder

struct TextLookExtractionTests {
    // MARK: Frame sampling

    @Test func samplingIsDenseAtBothEndsAndBounded() {
        let times = TextLookExtraction.sampleTimestamps(duration: 12)
        #expect(times.count <= TextLookExtraction.maxSampledFrames)
        #expect(times.first == 0)
        #expect(times == times.sorted())
        #expect(Set(times).count == times.count)
        #expect(times.allSatisfy { $0 >= 0 && $0 <= 12 })
        // Entrance burst: several frames inside the first 1.5 s.
        #expect(times.filter { $0 < 1.5 }.count >= 4)
        // Exit burst: several frames inside the last 1.5 s.
        #expect(times.filter { $0 > 10.5 }.count >= 3)
    }

    @Test func samplingSurvivesTinyAndInvalidDurations() {
        #expect(TextLookExtraction.sampleTimestamps(duration: 0) == [0])
        #expect(TextLookExtraction.sampleTimestamps(duration: .nan) == [0])
        let short = TextLookExtraction.sampleTimestamps(duration: 0.4)
        #expect(!short.isEmpty && short.allSatisfy { $0 >= 0 && $0 <= 0.4 })
        #expect(short == short.sorted() && Set(short).count == short.count)
    }

    // MARK: Prompt

    @Test func promptOnlyAsksForRequestedTargetsAndVideoTiming() {
        let still = TextLookExtraction.prompt(targets: [.overlay], isVideo: false, duration: 0, fontFamilies: ["Archivo Black"])
        #expect(still.contains("\"overlays\""))
        #expect(!still.contains("\"captions\""))
        #expect(!still.contains("\"name_tag\""))
        #expect(!still.contains("\"enter\""))
        #expect(still.contains("Archivo Black"))

        let video = TextLookExtraction.prompt(targets: [.captions, .nameTag], isVideo: true, duration: 8.2, fontFamilies: [])
        #expect(!video.contains("\"overlays\""))
        #expect(video.contains("\"captions\""))
        #expect(video.contains("\"name_tag\""))
        #expect(video.contains("8.2 s"))
        #expect(video.contains("slide_left"))
    }

    // MARK: Parsing

    @Test func parsesOverlaysWithTimingAndEffects() {
        let response = """
        {"overlays": [
          {"kind": "text", "text": "FIGHT NIGHT", "x": 0.5, "y": 0.2, "w": 0.8, "h": 0.1, "fontcolor": "#FFD60A", "bold": true,
           "bgcolor": null, "box_opacity": 0, "dynamic": true, "start": 0.4, "end": 3.1, "enter": "slide in from left", "exit": "dissolve", "at": 1.5},
          {"kind": "image", "x": 0.9, "y": 0.1, "w": 0.15, "h": 0.1, "description": "UFC logo", "start": 0, "end": null, "enter": "pop in", "at": 2},
          {"kind": "text", "text": "   "}
        ]}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.overlay], fonts: .init())
        #expect(parsed.overlays.count == 2)
        let title = parsed.overlays[0]
        #expect(title.kind == .text && title.text == "FIGHT NIGHT" && title.dynamic && title.bold)
        #expect(title.fontcolor == "#ffd60a" && title.bgcolor == nil)
        #expect(title.start == 0.4 && title.end == 3.1 && title.at == 1.5)
        #expect(title.enter == "slide_right" && title.exit == "fade")
        let logo = parsed.overlays[1]
        #expect(logo.kind == .image && logo.description == "UFC logo")
        #expect(logo.end == nil && logo.enter == "pop" && logo.exit == nil)
        #expect(parsed.caption == nil && parsed.tag == nil)
    }

    @Test func overlayTimingFromVideoKeepsWindowsAndUnboundedTails() {
        var element = TextLookExtraction.OverlayElement(kind: .text, text: "Hi")
        #expect(OverlayTemplateFiles.timing(for: element, isVideo: false, duration: 10) == .init(start: 0, end: 3, unbounded: true))
        element.start = 0.5
        element.end = 4
        #expect(OverlayTemplateFiles.timing(for: element, isVideo: true, duration: 10) == .init(start: 0.5, end: 4, unbounded: false))
        element.end = 9.9   // leaves with the clip but enters late: bounded to the clip
        #expect(OverlayTemplateFiles.timing(for: element, isVideo: true, duration: 10) == .init(start: 0.5, end: 10, unbounded: false))
        element.start = 0
        element.end = nil   // on screen from the start and stays: unbounded
        #expect(OverlayTemplateFiles.timing(for: element, isVideo: true, duration: 10) == .init(start: 0, end: 10, unbounded: true))
        element.start = 30   // beyond the clip: clamped
        let clamped = OverlayTemplateFiles.timing(for: element, isVideo: true, duration: 10)
        #expect(clamped.start == 10 && clamped.end > clamped.start && !clamped.unbounded)
    }

    @Test func parsesCaptionStyleOntoRendererVocabulary() {
        let response = """
        {"captions": {"present": true, "font_family": "archivo black", "font_class": "sans", "color": "#FFFFFF", "font_category": "sans", "font_style": "blocky", "font_weight": 900,
          "italic": false, "uppercase": true, "size": 64, "position": "middle", "alignment": "center", "words_per_page": 3,
          "bg_on": false, "bg_color": "#000000", "stroke_width": 2, "shadow": true, "letter_spacing_em": 0.05,
          "highlight": "box", "highlight_color": "#34C759", "emphasis": "scale", "animation": "bounce", "reveal": "word",
          "reveal_motion": true, "emoji": false, "unsupported": "typewriter cursor"}}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.captions], fonts: .init(library: ["Archivo Black", "Inter"]))
        let style = try! #require(parsed.caption)
        #expect(style.font == "Archivo Black")
        #expect(style.resolvedWeight == "black" && style.resolvedUppercase)
        #expect(style.position == "middle" && style.alignment == "center")
        #expect(style.resolvedWordsPerPage == 3)
        #expect(style.resolvedStrokeWidth == 2 && style.resolvedShadow && style.resolvedLetterSpacing == 3.2)   // 0.05 em × 64
        #expect(style.resolvedHighlight == "box" && style.resolvedHighlightColor == "#34c759")
        #expect(style.resolvedEmphasis == "scale")
        #expect(style.resolvedAnimation == "pop")   // bounce → pop
        #expect(style.resolvedReveal == "word" && style.resolvedRevealMotion)
        #expect(style.resolvedSize(for: .text) == 64)
        #expect(parsed.notes.contains { $0.contains("typewriter") })
    }

    @Test func captionsAbsentOrUnrequestedAreNil() {
        let absent = TextLookExtraction.parse(#"{"captions": {"present": false}}"#, targets: [.captions], fonts: .init())
        #expect(absent.caption == nil)
        let huge = TextLookExtraction.parse(#"{"captions": {"words_per_page": 1e100, "size": -1e300, "bg_radius": 1e308}}"#, targets: [.captions], fonts: .init())
        #expect(huge.caption?.resolvedWordsPerPage == 8)
        #expect(huge.caption?.resolvedSize(for: .text) == 24)
        let unrequested = TextLookExtraction.parse(#"{"captions": {"present": true}}"#, targets: [.overlay], fonts: .init())
        #expect(unrequested.caption == nil)
        #expect(TextLookExtraction.parse("not json", targets: [.overlay], fonts: .init()) == .init())
    }

    @Test func parsesNameTagStyle() {
        let response = """
        {"name_tag": {"present": true,
          "name": {"font_family": "Inter", "color": "#ffffff", "bold": true, "uppercase": true},
          "description": {"present": true, "font_family": "Unknown Face", "font_class": "serif", "color": "#cccccc", "bold": false, "scale": 0.6},
          "alignment": "center", "bg_on": true, "bg_color": "#112233", "bg_opacity": 0.9, "bg_radius": 12}}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.nameTag], fonts: .init(library: ["Inter"]))
        let style = try! #require(parsed.tag)
        #expect(style.name.font == "Inter" && style.name.uppercase && style.name.bold)
        #expect(style.name.field == "Name")
        // An unknown family keeps the default face rather than a bare class.
        #expect(style.description.font == "Archivo Black" && style.description.scale == 0.6 && style.description.color == "#cccccc")
        #expect(style.alignment == "center" && style.bgOn && style.bgColor == "#112233")
        #expect(style.bgOpacity == 0.9 && style.cornerRadius == 12)
    }

    @Test func nameTagWithoutSecondLineKeepsDefaultAndNotes() {
        let response = "{\"name_tag\": {\"name\": {\"color\": \"#fff\"}, \"description\": {\"present\": false}}}"
        let parsed = TextLookExtraction.parse(response, targets: [.nameTag], fonts: .init())
        // No single-line mode exists: keep the default role line and say so.
        #expect(parsed.tag?.description == TagStyle().description)
        #expect(parsed.notes.contains { $0.contains("second line") })
        #expect(parsed.tag?.name.color == "#fff")
    }

    // MARK: Vocabularies

    @Test func transitionsNormalizeOntoOverlayChoices() {
        #expect(TextLookExtraction.transition("Slide-Up") == "slide_up")
        #expect(TextLookExtraction.transition("from bottom") == "slide_up")
        #expect(TextLookExtraction.transition("zoom in") == "pop")
        #expect(TextLookExtraction.transition("none") == "cut")
        #expect(TextLookExtraction.transition("slide in from left") == "slide_right")
        #expect(TextLookExtraction.transition("slides up from below") == "slide_up")
        #expect(TextLookExtraction.transition("flies in to the left") == "slide_left")
        #expect(TextLookExtraction.transition("fades out") == "fade")
        #expect(TextLookExtraction.transition("appears instantly") == "cut")
        #expect(TextLookExtraction.transition("wobble") == nil)
        #expect(TextLookExtraction.transition(nil) == nil)
        for choice in TextOverlayItem.transitionChoices {
            #expect(TextLookExtraction.transition(choice) == choice)
        }
    }

    @Test func fontFieldsBecomeAMatchRequest() {
        let request = try! #require(TextLookExtraction.fontRequest([
            "font_family": " Proxima Nova ", "font_category": "Sans", "font_style": "geometric, rounded",
            "font_weight": 800, "italic": true,
        ]))
        #expect(request.family == "Proxima Nova" && request.category == "sans")
        #expect(request.styles == ["geometric", "rounded"] && request.weight == 800 && request.italic)
        #expect(TextLookExtraction.fontRequest(["color": "#fff"]) == nil)
        // Legacy keys still count.
        #expect(TextLookExtraction.fontWeight(["weight": "black"]) == 900)
        #expect(TextLookExtraction.fontWeight(["bold": true]) == 700)
        #expect(TextLookExtraction.fontRequest(["font_class": "serif"])?.category == "serif")
    }

    @Test func captionFontFallsBackToInstalledStandIn() {
        let fonts = FontMatch.Catalog(library: ["Next Sphere"], installed: ["Avenir Next", "Helvetica Neue", "Impact"])
        let response = #"{"captions": {"font_family": "Montserrat Bold", "font_category": "sans", "font_style": "geometric", "font_weight": 700}}"#
        let parsed = TextLookExtraction.parse(response, targets: [.captions], fonts: fonts)
        #expect(parsed.caption?.font == "Avenir Next")
        #expect(parsed.caption?.resolvedWeight == "bold")
        #expect(parsed.notes.contains { $0.hasPrefix("Caption font: Montserrat Bold is not installed") })
        // The library font is never forced onto text set in something else.
        #expect(parsed.caption?.font != "Next Sphere")
    }

    @Test func traitsNamedInTheFamilyReachEveryTarget() {
        let fonts = FontMatch.Catalog(installed: ["Montserrat"])
        let response = """
        {"captions": {"font_family": "Montserrat Bold Italic"},
         "name_tag": {"name": {"font_family": "Montserrat Black"}, "description": {"font_family": "Montserrat Light Italic"}},
         "overlays": [{"kind": "text", "text": "x", "font_family": "Montserrat ExtraBold Italic"}]}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.captions, .nameTag, .overlay], fonts: fonts)
        #expect(parsed.caption?.font == "Montserrat" && parsed.caption?.resolvedWeight == "bold" && parsed.caption?.text?.italic == true)
        #expect(parsed.tag?.name.bold == true && parsed.tag?.name.italic == false)
        #expect(parsed.tag?.description.bold == false && parsed.tag?.description.italic == true)
        #expect(parsed.overlays[0].bold && parsed.overlays[0].italic && parsed.overlays[0].fontFamily == "Montserrat")
        #expect(parsed.notes.isEmpty)
    }

    @Test func emphasisAndHighlightWearTheirOwnFace() {
        let fonts = FontMatch.Catalog(installed: ["Montserrat", "Didot", "Helvetica Neue"])
        let response = """
        {"captions": {"font_family": "Neue Montreal", "font_category": "sans", "font_style": "grotesque", "font_weight": 700, "size": 60,
          "highlight": "color", "highlight_color": "#e8260f", "highlight_look": null,
          "emphasis": "none",
          "emphasis_look": {"font_family": "Instrument Serif", "font_category": "serif", "font_style": "high-contrast", "font_weight": 400, "italic": true, "size_scale": 1.3}}}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.captions], fonts: fonts)
        let style = try! #require(parsed.caption)
        #expect(style.font == "Helvetica Neue")
        #expect(style.highlightFont == nil && style.highlightDecor == nil)
        // A described emphasis face turns emphasis on even when the model left it "none".
        #expect(style.resolvedEmphasis == "font" && style.resolvedEmphasisFont == "Didot")
        #expect(style.emphasisDecor?.italic == true && style.emphasisDecor?.size == 78 && style.emphasisDecor?.weight == "regular")
        #expect(parsed.notes.contains { $0.contains("Neue Montreal is not installed") && $0.contains("emphasised words: Instrument Serif is not installed") })
        // Nothing usable in a look leaves the state alone.
        let empty = TextLookExtraction.parse(#"{"captions": {"emphasis": "scale", "emphasis_look": {"italic": null}}}"#, targets: [.captions], fonts: fonts)
        #expect(empty.caption?.emphasisDecor == nil && empty.caption?.resolvedEmphasis == "scale")
    }

    @Test func overlayTextsCarryTheirMatchedFamily() {
        let fonts = FontMatch.Catalog(installed: ["Bebas Neue", "Helvetica Neue"])
        let response = """
        {"overlays": [{"kind": "text", "text": "ROUND 1", "font_family": "Oswald", "font_weight": 700},
                      {"kind": "text", "text": "plain"}]}
        """
        let parsed = TextLookExtraction.parse(response, targets: [.overlay], fonts: fonts)
        #expect(parsed.overlays[0].fontFamily == "Bebas Neue" && parsed.overlays[0].bold)
        #expect(parsed.overlays[1].fontFamily == nil && !parsed.overlays[1].bold)
        #expect(parsed.notes.count == 1 && parsed.notes[0].hasPrefix("Overlay “ROUND 1”: Oswald is not installed"))
    }

    @Test func colorsAcceptHexAndWordsOnly() {
        #expect(TextLookExtraction.color("#FFD60A") == "#ffd60a")
        #expect(TextLookExtraction.color("#fff") == "#fff")
        #expect(TextLookExtraction.color("white") == "white")
        #expect(TextLookExtraction.color("null") == nil)
        #expect(TextLookExtraction.color("#12345") == nil)
        #expect(TextLookExtraction.color("rgb(1,2,3)") == nil)
        #expect(TextLookExtraction.color(nil) == nil)
    }
}
