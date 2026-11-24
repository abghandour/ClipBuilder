import Foundation

/// Code-owned originals; the library always inserts a fresh editable copy.
nonisolated enum CaptionPresets {
    enum Family: String, Codable, CaseIterable, Identifiable, Sendable {
        case wordByWord = "Word-by-word"
        case highlights = "Highlights"
        case boldStacks = "Bold stacks"
        case creator = "Creator"
        var id: String { rawValue }
    }

    /// Older saved copies did not carry a family. Recognize their original names.
    static func family(for preset: NamedCaptionStyle) -> Family? {
        preset.family ?? originals.first { $0.name == preset.name }?.family
    }

    /// Cache the code-owned values; callers still receive fresh editable copies.
    private static let originals = makeStyles()

    static var styles: [NamedCaptionStyle] {
        originals.map { NamedCaptionStyle(name: $0.name, style: $0.style, family: $0.family) }
    }

    /// The look a new profile starts with.
    static var profileDefault: CaptionStyle { pgPreferred }

    private struct Definition {
        var name: String
        var family: Family
        var make: @Sendable () -> CaptionStyle
    }

    // Keep each style construction in its own function. CaptionStyle contains
    // several large decor values; building every preset in one stack frame overflows
    // Swift's small cooperative-thread stack in Debug.
    private static func makeStyles() -> [NamedCaptionStyle] {
        let definitions: [Definition] = [
            Definition(name: "Clean", family: .wordByWord, make: { clean }),
            Definition(name: "Boxed", family: .boldStacks, make: { boxed }),
            Definition(name: "Karaoke", family: .creator, make: { karaoke }),
            Definition(name: "Hormozi", family: .creator, make: { hormozi }),
            Definition(name: "Three-Word", family: .highlights, make: { threeWord }),
            Definition(name: "Lower Third", family: .boldStacks, make: { lowerThird }),
            Definition(name: "Interview Serif", family: .wordByWord, make: { interviewSerif }),
            Definition(name: "Retro 3D", family: .boldStacks, make: { retro }),
            Definition(name: "Cove", family: .wordByWord, make: { cove }),
            Definition(name: "Energy", family: .wordByWord, make: { energy }),
            Definition(name: "M81", family: .highlights, make: { m81 }),
            Definition(name: "Arion Pink", family: .highlights, make: { arionPink }),
            Definition(name: "Quintessence", family: .boldStacks, make: { quintessence }),
            Definition(name: "Bellatrix", family: .wordByWord, make: { bellatrix }),
            Definition(name: "Prism", family: .highlights, make: { prism }),
            Definition(name: "Freshly", family: .boldStacks, make: { freshly }),
            Definition(name: "Thuban", family: .wordByWord, make: { thuban }),
            Definition(name: "Mars", family: .highlights, make: { mars }),
            Definition(name: "Runway", family: .boldStacks, make: { runway }),
            Definition(name: "Grace", family: .wordByWord, make: { grace }),
            Definition(name: "Copernicus", family: .highlights, make: { copernicus }),
            Definition(name: "Aldebaran", family: .boldStacks, make: { aldebaran }),
            Definition(name: "Nova", family: .wordByWord, make: { nova }),
            Definition(name: "Alcyone Blue", family: .highlights, make: { alcyoneBlue }),
            Definition(name: "Travel", family: .boldStacks, make: { travel }),
            Definition(name: "Andromeda", family: .wordByWord, make: { andromeda }),
            Definition(name: "Cassiopeia", family: .highlights, make: { cassiopeia }),
            Definition(name: "Citadelle", family: .boldStacks, make: { citadelle }),
            Definition(name: "Beast", family: .creator, make: { beast }),
            Definition(name: "Iman", family: .creator, make: { iman }),
            Definition(name: "Ali", family: .creator, make: { ali }),
            Definition(name: "PG Preferred", family: .creator, make: { pgPreferred }),
        ]
        return definitions.map { NamedCaptionStyle(name: $0.name, style: $0.make(), family: $0.family) }
    }

    private static var clean: CaptionStyle {
        var style = CaptionStyle()
        style.strokeWidth = 1
        // Explicitly separate emphasis from highlight and the first speaker's white.
        // Do not change CaptionStyle's fallback: saved profiles retain their appearance.
        style.emphasisColor = "#ff9f0a"
        return style
    }

    private static var boxed: CaptionStyle {
        var style = clean
        style.weight = "bold"
        style.bgOn = true
        return style
    }

    private static var karaoke: CaptionStyle {
        var style = clean
        style.weight = "bold"
        style.highlight = "color"
        style.animation = "pop"
        return style
    }

    private static var hormozi: CaptionStyle {
        var style = clean
        style.wordsPerPage = 1
        style.weight = "black"
        style.uppercase = true
        style.highlight = "scale"
        style.emphasis = "color"
        return style
    }

    private static var threeWord: CaptionStyle {
        var style = clean
        style.weight = "bold"
        style.wordsPerPage = 3
        style.highlight = "box"
        return style
    }

    private static var lowerThird: CaptionStyle {
        var style = boxed
        style.alignment = "leading"
        return style
    }

    private static var interviewSerif: CaptionStyle {
        var style = clean
        style.weight = "bold"
        style.wordsPerPage = 3
        style.reveal = "word"
        style.highlight = "color"
        style.highlightColor = "#e5322d"
        style.emphasis = "font"
        // Georgia ships with macOS; the renderer applies its real italic trait.
        style.emphasisFont = "Georgia"
        style.emphasisDecor = CaptionWordDecor(italic: true)
        style.position = "middle"
        style.shadow = true
        style.bgOn = false
        style.strokeWidth = 0
        return style
    }

    private static var retro: CaptionStyle {
        var style = clean
        style.weight = "black"
        style.uppercase = true
        style.bgOn = false
        style.strokeWidth = 0
        style.color = "#ffd60a"
        style.shadow = true
        style.decor = TextShadowPresets.all.first { $0.name == "Retro 3D" }.map { TextShadowPresets.apply($0, to: nil) }
        return style
    }

    private static var cove: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.reveal = "word"
        style.highlight = "color"
        style.highlightColor = "#40c8b0"
        style.shadow = true
        style.decor = shadow("Soft drop")
        return style
    }

    private static var energy: CaptionStyle {
        var style = hormozi
        style.highlightColor = "#40c8b0"
        style.emphasisColor = "#ffd60a"
        style.animation = "pop"
        style.position = "middle"
        return style
    }

    private static var m81: CaptionStyle {
        var style = clean
        style.wordsPerPage = 4
        style.weight = "bold"
        style.highlight = "box"
        style.highlightColor = "#242834"
        style.highlightDecor = CaptionWordDecor(bgRadius: 10)
        style.strokeWidth = 0
        return style
    }

    private static var arionPink: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.highlight = "color"
        style.highlightColor = "#ff5fa2"
        style.emphasis = "color"
        style.animation = "fade"
        return style
    }

    private static var quintessence: CaptionStyle {
        var style = clean
        style.wordsPerPage = 2
        style.weight = "black"
        style.uppercase = true
        style.animation = "slide-up"
        style.text = CaptionWordDecor(size: 96)
        style.decor = shadow("Hard offset")
        style.decor?.maxWidthFrac = 0.2
        return style
    }

    private static var bellatrix: CaptionStyle {
        var style = clean
        style.wordsPerPage = 2
        style.reveal = "word"
        style.highlight = "scale"
        style.decor = shadow("Glow")
        return style
    }

    private static var prism: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.highlight = "color"
        style.highlightColors = ["#40c8b0", "#ff5fa2", "#8f7aff"]
        return style
    }

    private static var freshly: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.bgOn = true
        style.bgColor = "#16733d"
        style.bgRadius = 12
        return style
    }

    private static var thuban: CaptionStyle {
        var style = clean
        style.wordsPerPage = 1
        style.weight = "black"
        style.uppercase = true
        style.animation = "bounce"
        return style
    }

    private static var mars: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.highlight = "box"
        style.highlightColor = "#d52e36"
        style.uppercase = true
        style.animation = "pop"
        return style
    }

    private static var runway: CaptionStyle {
        var style = clean
        style.wordsPerPage = 4
        style.font = "serif"
        style.weight = "bold"
        style.position = "middle"
        style.letterSpacing = 0.05
        return style
    }

    private static var grace: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.font = "Georgia"
        style.reveal = "word"
        style.emphasis = "font"
        style.emphasisFont = "Georgia"
        style.emphasisDecor = CaptionWordDecor(italic: true)
        style.strokeWidth = 0
        return style
    }

    private static var copernicus: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.font = "mono"
        style.color = "#f2f2f2"
        style.highlight = "color"
        style.highlightColor = style.color
        style.highlightDecor = CaptionWordDecor(underline: true)
        return style
    }

    private static var aldebaran: CaptionStyle {
        var style = clean
        style.wordsPerPage = 2
        style.weight = "black"
        style.bgOn = true
        style.bgColor = "#c65b12"
        style.uppercase = true
        style.decor = shadow("Hard offset")
        return style
    }

    private static var nova: CaptionStyle {
        var style = clean
        style.wordsPerPage = 1
        style.weight = "black"
        style.highlight = "scale"
        style.emoji = true
        return style
    }

    private static var alcyoneBlue: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.highlight = "color"
        style.highlightColor = "#4da3ff"
        style.decor = TextDecor(strokeOn: true, strokeWidth: 1, strokeColor: "#164c91")
        return style
    }

    private static var travel: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.weight = "bold"
        style.bgOn = true
        style.bgColor = "#ffffff"
        style.color = "#20242a"
        style.decor = TextDecor(bgOpacity: 1)
        return style
    }

    private static var andromeda: CaptionStyle {
        var style = clean
        style.wordsPerPage = 2
        style.reveal = "word"
        style.highlight = "color"
        style.highlightColor = "#ba82ff"
        style.decor = shadow("Glow")
        style.decor?.shadowColor = "#ba82ff"
        return style
    }

    private static var cassiopeia: CaptionStyle {
        var style = clean
        style.wordsPerPage = 4
        style.weight = "bold"
        style.highlight = "box"
        style.highlightColor = "#ffd60a"
        return style
    }

    private static var citadelle: CaptionStyle {
        var style = clean
        style.wordsPerPage = 2
        style.weight = "black"
        style.uppercase = true
        style.strokeWidth = 2
        style.position = "top"
        return style
    }

    private static var beast: CaptionStyle {
        var style = clean
        style.wordsPerPage = 1
        style.weight = "black"
        style.uppercase = true
        style.highlight = "color"
        style.highlightColors = ["#ffd60a", "#56df80", "#ff5fa2", "#62b8ff"]
        style.animation = "pop"
        style.emoji = true
        return style
    }

    private static var iman: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        // The stock light face supplies the weight without adding a new renderer mode.
        style.font = "HelveticaNeue-Light"
        style.color = "#f2f2f2"
        style.strokeWidth = 0
        style.decor = TextDecor(casing: "lower")
        style.highlight = "color"
        style.highlightColor = style.color
        style.highlightFont = "sans"
        style.highlightDecor = CaptionWordDecor(weight: "bold")
        return style
    }

    private static var ali: CaptionStyle {
        var style = clean
        style.wordsPerPage = 3
        style.font = "Arial Rounded MT Bold"
        style.weight = "bold"
        style.highlight = "color"
        style.highlightColor = "#67d5df"
        style.animation = "fade"
        return style
    }

    private static func shadow(_ name: String) -> TextDecor? {
        TextShadowPresets.all.first { $0.name == name }.map { TextShadowPresets.apply($0, to: nil) }
    }

    private static var pgPreferred: CaptionStyle {
        var style = clean
        // Closest measured stock macOS face; no external font dependency.
        style.font = "HelveticaNeue-Medium"
        style.color = "#fcfcfc"
        style.text = CaptionWordDecor(decor: TextDecor(size: 1.25), size: 120)
        style.strokeWidth = 0
        style.letterSpacing = -6.7
        style.highlight = "color"
        style.highlightColor = "#de1600"
        style.emphasis = "color"
        style.emphasisColor = "#fcfcfc"
        style.emphasisFont = "HelveticaNeue-Medium"
        // Joint word-edge fit across the reference pages. Tracking and space
        // advance are independent: tightening spaces does not tighten glyphs.
        // Keep the complete emphasis line inside the measured 940px band.
        // The reference's enlarged word turns white with no glow when its
        // word ends, then a white glow grows over about eight frames and stays.
        style.emphasisDecor = CaptionWordDecor(
            decor: TextDecor(size: 1.92375, shadowOn: true, shadowColor: "#ffffff", shadowOpacity: 0.5, shadowX: 0, shadowY: 0,
                             shadowBlur: 0.14, shadowStyle: "glow", shadowStrength: 1, maxWidthFrac: 0.87),
            size: 120, letterSpacing: -6.48, fitLineMinimumScale: 0.6, highlightHold: false,
            glowIn: CaptionWordDecor.defaultGlowIn)
        // Emphasis 2: the reference's italic serif word ("belt?"), white, on
        // an ordinary two-line page. Bodoni 72 is the closest stock macOS face.
        style.emphasis2 = "color"
        style.emphasis2Color = "#fcfcfc"
        style.emphasis2Font = "Bodoni 72"
        style.emphasis2Decor = CaptionWordDecor(decor: TextDecor(size: 2.0), italic: true, size: 120,
                                                letterSpacing: -3, highlightHold: false,
                                                takesHighlightColor: false)
        style.colorSpace = "srgb"
        style.reveal = "word"
        style.revealLayout = "fixed"
        style.highlightHold = true
        style.animation = "soft-fade"
        style.revealMotion = true
        style.animationMinimumWordDuration = 0.2
        style.lineBreaks = "clause"
        style.lineSpacing = 136
        style.wordSpacing = 19.15
        style.position = "custom:0.50325,0.5531"
        style.decor = TextDecor(shadowOn: true, shadowColor: "#000000", shadowOpacity: 0.35,
                               shadowX: 0, shadowY: -0.02, shadowBlur: 0.04, shadowStyle: "soft",
                               maxWidthFrac: 0.86)
        return style
    }
}
