import Foundation
import Testing
@testable import Clip_Builder

struct FontMatchTests {
    let mac = FontMatch.Catalog(
        library: ["Next Sphere"],
        installed: ["Anton", "Arial", "Arial Black", "Avenir Next", "Avenir Next Condensed", "Bebas Neue", "Didot",
                    "Georgia", "Helvetica Neue", "Impact", "Marker Felt", "Menlo", "Montserrat", "Snell Roundhand",
                    "Times New Roman", "Archivo Black"])

    @Test func exactFamilyWinsAndStyleWordsAreIgnored() {
        #expect(FontMatch.match(.init(family: "montserrat"), in: mac) == .init(family: "Montserrat", exact: true))
        #expect(FontMatch.match(.init(family: "Montserrat Black Italic"), in: mac).family == "Montserrat")
        // Exact only: a short name reaches the longer family through the stand-in table, never by prefix.
        let bebas = FontMatch.match(.init(family: "Bebas"), in: mac)
        #expect(bebas.family == "Bebas Neue" && !bebas.exact)
        #expect(FontMatch.match(.init(family: "NEXT SPHERE"), in: mac).family == "Next Sphere")
    }

    @Test func knownFontsGetTheirStandIn() {
        let proxima = FontMatch.match(.init(family: "Proxima Nova Bold"), in: mac)
        #expect(proxima.family == "Montserrat" && !proxima.exact)
        #expect(proxima.note?.contains("Add Proxima Nova to the Fonts library") == true)
        #expect(FontMatch.match(.init(family: "Oswald"), in: mac).family == "Bebas Neue")
        #expect(FontMatch.match(.init(family: "The Bold Font"), in: mac).family == "Archivo Black")
        #expect(FontMatch.match(.init(family: "Playfair Display"), in: mac).family == "Didot")
        #expect(FontMatch.match(.init(family: "Pacifico"), in: mac).family == "Snell Roundhand")
        #expect(FontMatch.match(.init(family: "Roboto"), in: mac).family == "Helvetica Neue")
        // The first stand-in that is installed wins, not the first listed.
        let gotham = FontMatch.match(.init(family: "Gotham"), in: FontMatch.Catalog(installed: ["Futura", "Avenir Next"]))
        #expect(gotham.family == "Avenir Next")
    }

    @Test func relatedFamiliesNeverStandInByPrefix() {
        let catalog = FontMatch.Catalog(installed: ["Roboto", "Rockwell", "Avenir Next Condensed", "Helvetica Neue", "Roboto Mono"])
        #expect(FontMatch.match(.init(family: "Roboto Slab"), in: catalog).family == "Rockwell")
        #expect(FontMatch.match(.init(family: "Roboto Condensed Bold"), in: catalog).family == "Avenir Next Condensed")
        #expect(FontMatch.match(.init(family: "Roboto Mono Regular"), in: catalog) == .init(family: "Roboto Mono", exact: true, weight: 400))
        #expect(FontMatch.match(.init(family: "Roboto Black"), in: catalog) == .init(family: "Roboto", exact: true, weight: 900))
        #expect(FontMatch.match(.init(family: "Robot"), in: catalog).family != "Roboto")
    }

    @Test func traitsInTheNameComeBackInTheResult() {
        let match = FontMatch.match(.init(family: "Montserrat Bold Italic"), in: mac)
        #expect(match == .init(family: "Montserrat", exact: true, weight: 700, italic: true))
        let explicit = FontMatch.match(.init(family: "Montserrat Bold", weight: 300), in: mac)
        #expect(explicit.weight == 300)
    }

    @Test func unknownFontsFallBackByDescription() {
        let condensed = FontMatch.match(.init(family: "Some Condensed Face", category: "sans", styles: ["condensed"], weight: 800), in: mac)
        #expect(condensed.family == "Bebas Neue" && !condensed.exact)
        #expect(condensed.note?.contains("condensed heavy sans") == true)
        #expect(FontMatch.match(.init(family: "Mystery", category: "serif", styles: ["high-contrast"]), in: mac).family == "Didot")
        #expect(FontMatch.match(.init(family: "Mystery", category: "mono"), in: mac).family == "Menlo")
        #expect(FontMatch.match(.init(family: "Mystery", category: "handwritten"), in: mac).family == "Marker Felt")
        #expect(FontMatch.match(.init(family: "Mystery", category: "display"), in: mac).family == "Archivo Black")
        #expect(FontMatch.match(.init(family: "Mystery", category: "sans", styles: ["geometric"]), in: mac).family == "Montserrat")
        #expect(FontMatch.match(.init(family: nil, category: "sans"), in: mac).family == "Helvetica Neue")
        // The name alone carries width and weight.
        #expect(FontMatch.match(.init(family: "Whatever Condensed Black"), in: mac).family == "Bebas Neue")
    }

    @Test func bareClassesAndEmptyCatalogsDegradeToKeywords() {
        #expect(FontMatch.match(.init(family: "sans"), in: .init()).family == "sans")
        #expect(FontMatch.match(.init(family: "Georgia", category: "serif"), in: .init()) .family == "serif")
        #expect(FontMatch.match(.init(family: nil, category: "monospace"), in: .init()).family == "mono")
        #expect(FontMatch.match(.init(family: nil, category: "script"), in: .init()).family == "sans")
    }

    @Test func weightNamesFollowTheRendererBuckets() {
        #expect(FontMatch.weightName(nil) == nil)
        #expect(FontMatch.weightName(300) == "regular")
        #expect(FontMatch.weightName(600) == "bold")
        #expect(FontMatch.weightName(800) == "black")
    }

    @Test func liveCatalogListsInstalledFamilies() {
        let catalog = FontMatch.Catalog.current(library: ["Custom"])
        #expect(catalog.library == ["Custom"])
        #expect(catalog.installed.contains("Helvetica Neue"))
        #expect(!catalog.installed.contains { $0.hasPrefix(".") })
    }
}
