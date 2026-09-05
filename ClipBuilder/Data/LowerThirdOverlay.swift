import Foundation

/// Built-in lower-third composition. It remains an ordinary overlay block,
/// so users can trim, move, or restyle it with the existing Builder tools.
nonisolated enum LowerThirdOverlay {
    static func composition(
        name: String, role: String, logoPath: String? = nil,
        rightAligned: Bool = false
    ) -> OverlayComposition {
        let x = rightAligned ? 0.73 : 0.27
        var nameLine = TextOverlayItem(text: name, startTime: 0, endTime: 4)
        nameLine.fontsize = 52
        nameLine.bold = true
        nameLine.fontfamily = "Archivo Black"
        nameLine.xFrac = x
        nameLine.yFrac = 0.78
        nameLine.wFrac = 0.42
        nameLine.hFrac = 0.07
        nameLine.boxOpacity = 0.82
        nameLine.bgcolor = "#101010"
        nameLine.accentColor = "#FFD400"
        nameLine.transIn = rightAligned ? "slide_right" : "slide_left"
        nameLine.transOut = rightAligned ? "slide_right" : "slide_left"

        var roleLine = TextOverlayItem(text: role, startTime: 0.1, endTime: 4)
        roleLine.fontsize = 27
        roleLine.xFrac = x
        roleLine.yFrac = 0.835
        roleLine.wFrac = 0.42
        roleLine.hFrac = 0.045
        roleLine.boxOpacity = 0.72
        roleLine.bgcolor = "#252525"
        roleLine.transIn = rightAligned ? "slide_right" : "slide_left"
        roleLine.transOut = rightAligned ? "slide_right" : "slide_left"

        var images: [ImageOverlayItem] = []
        if let logoPath, !logoPath.isEmpty {
            var logo = ImageOverlayItem(path: logoPath, startTime: 0, endTime: 4)
            logo.xFrac = rightAligned ? 0.46 : 0.54
            logo.yFrac = 0.81
            logo.wFrac = 0.08
            logo.transIn = nameLine.transIn
            logo.transOut = nameLine.transOut
            images.append(logo)
        }
        return OverlayComposition(texts: [nameLine, roleLine], images: images)
    }
}
