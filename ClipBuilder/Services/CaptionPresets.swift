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
        return [NamedCaptionStyle(name: "Clean", style: clean),
                NamedCaptionStyle(name: "Boxed", style: boxed),
                NamedCaptionStyle(name: "Karaoke", style: karaoke),
                NamedCaptionStyle(name: "Hormozi", style: hormozi),
                NamedCaptionStyle(name: "Three-Word", style: threeWord),
                NamedCaptionStyle(name: "Lower Third", style: lowerThird),
                NamedCaptionStyle(name: "Interview Serif", style: interviewSerif)]
    }
}
