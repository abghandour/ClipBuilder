import Foundation

/// Code-owned originals; the library always inserts a fresh editable copy.
nonisolated enum CaptionPresets {
    static var styles: [NamedCaptionStyle] {
        var clean = CaptionStyle()
        clean.strokeWidth = 1
        var boxed = clean
        boxed.weight = "bold"
        boxed.bgOn = true
        var karaoke = clean
        karaoke.weight = "bold"
        karaoke.highlight = "color"
        karaoke.animation = "pop"
        var hormozi = clean
        hormozi.wordsPerPage = 1
        hormozi.weight = "black"
        hormozi.uppercase = true
        hormozi.highlight = "scale"
        hormozi.emphasis = "color"
        var threeWord = clean
        threeWord.weight = "bold"
        threeWord.wordsPerPage = 3
        threeWord.highlight = "box"
        var lowerThird = boxed
        lowerThird.alignment = "leading"
        var interviewSerif = clean
        interviewSerif.weight = "bold"
        interviewSerif.wordsPerPage = 3
        interviewSerif.reveal = "word"
        interviewSerif.highlight = "color"
        interviewSerif.highlightColor = "#e5322d"
        interviewSerif.emphasis = "font"
        // Georgia ships with macOS; the renderer applies its real italic trait.
        interviewSerif.emphasisFont = "Georgia"
        interviewSerif.emphasisDecor = CaptionWordDecor(italic: true)
        interviewSerif.position = "middle"
        interviewSerif.shadow = true
        interviewSerif.bgOn = false
        interviewSerif.strokeWidth = 0
        var retro = clean
        retro.weight = "black"
        retro.uppercase = true
        retro.bgOn = false
        retro.strokeWidth = 0
        retro.color = "#ffd60a"
        retro.shadow = true
        retro.decor = TextShadowPresets.all.first { $0.name == "Retro 3D" }.map { TextShadowPresets.apply($0, to: nil) }
        return [NamedCaptionStyle(name: "Clean", style: clean),
                NamedCaptionStyle(name: "Boxed", style: boxed),
                NamedCaptionStyle(name: "Karaoke", style: karaoke),
                NamedCaptionStyle(name: "Hormozi", style: hormozi),
                NamedCaptionStyle(name: "Three-Word", style: threeWord),
                NamedCaptionStyle(name: "Lower Third", style: lowerThird),
                NamedCaptionStyle(name: "Interview Serif", style: interviewSerif),
                NamedCaptionStyle(name: "Retro 3D", style: retro)]
    }
}
