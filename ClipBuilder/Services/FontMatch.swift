import CoreText
import Foundation

/// Turns the typeface a vision model saw in a reference into a face this
/// Mac can render. The model names the real font ("Proxima Nova Bold") and
/// describes it (category, style words, weight); the matcher takes the
/// font itself when the library or the system has it, else a known
/// stand-in, else the best installed face of that class. Pure given a
/// catalog, so it is testable without fonts on the machine.
nonisolated enum FontMatch {
    /// What the model said about one text's typeface.
    struct Request: Sendable, Equatable {
        /// Best-guess family name, free-form ("Montserrat", "Bebas Neue Bold").
        var family: String?
        /// sans | serif | slab | mono | script | handwritten | display
        var category: String?
        /// geometric, grotesque, humanist, condensed, extended, rounded, high-contrast, blocky
        var styles: [String] = []
        /// 100–900 (400 regular, 700 bold, 900 black).
        var weight: Int?
        var italic = false
    }

    /// Family names the renderers can resolve: the profile's Fonts library
    /// (registered at launch) and the fonts installed on the Mac.
    struct Catalog: Sendable, Equatable {
        var library: [String]
        var installed: [String]

        init(library: [String] = [], installed: [String] = []) {
            self.library = library
            self.installed = installed
        }

        /// The library plus every family CoreText knows, hidden faces dropped.
        static func current(library: [String]) -> Catalog {
            let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            return Catalog(library: library, installed: names.filter { !$0.hasPrefix(".") })
        }

        /// The catalog's spelling of `name`, library first. Exact after
        /// folding only: "Roboto" must never stand for "Roboto Slab".
        func lookup(_ name: String) -> String? {
            let key = fold(name)
            guard !key.isEmpty else { return nil }
            for pool in [library, installed] {
                if let hit = pool.first(where: { fold($0) == key }) { return hit }
            }
            return nil
        }
    }

    struct Result: Sendable, Equatable {
        /// A family the renderers resolve, or a class keyword (sans, serif,
        /// mono) when nothing installed fits.
        var family: String
        var exact: Bool
        /// Why a stand-in was chosen; nil for an exact match.
        var note: String?
        /// Traits read from the name or the request ("Montserrat Bold
        /// Italic"), so a caller without separate trait fields keeps them.
        var weight: Int?
        var italic = false
    }

    // MARK: - Matching

    static func match(_ request: Request, in catalog: Catalog) -> Result {
        let guess = request.family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = guess.isEmpty || classKeywords.contains(fold(guess)) ? nil : guess
        var request = request
        if let named {
            // "Montserrat Black" carries its weight and width in the name.
            let words = named.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            if request.weight == nil, let weight = words.compactMap({ weightWords[$0] }).max() { request.weight = weight }
            if words.contains(where: { ["condensed", "compressed", "narrow"].contains($0) }),
               !request.styles.contains("condensed") { request.styles.append("condensed") }
            if words.contains(where: { ["italic", "oblique"].contains($0) }) { request.italic = true }
        }
        func result(_ family: String, exact: Bool, note: String? = nil) -> Result {
            Result(family: family, exact: exact, note: note, weight: request.weight, italic: request.italic)
        }
        if let named {
            // Longest leading run of words first, so "Roboto Condensed Bold"
            // tries "Roboto Condensed" (installed or a known stand-in)
            // before "Roboto".
            let words = named.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            for count in stride(from: words.count, through: 1, by: -1) {
                let base = words.prefix(count).joined(separator: " ")
                if let hit = catalog.lookup(base) { return result(hit, exact: true) }
                for substitute in substitutes[fold(base)] ?? [] {
                    if let hit = catalog.lookup(substitute) {
                        return result(hit, exact: false,
                                      note: "\(named) is not installed; using \(hit), the closest installed face. Add \(base) to the Fonts library for an exact match.")
                    }
                }
            }
        }
        let (candidates, description) = classCandidates(for: request)
        for candidate in candidates {
            if let hit = catalog.lookup(candidate) {
                let note = named.map { "\($0) is not installed and has no known stand-in; using \(hit), an installed \(description). Add \($0) to the Fonts library for an exact match." }
                    ?? "No typeface was named; using \(hit), an installed \(description)."
                return result(hit, exact: false, note: note)
            }
        }
        let keyword = classKeyword(for: request)
        let note = named.map { "\($0) is not installed and nothing similar is either; using the default \(keyword) face." }
        return result(keyword, exact: false, note: note)
    }

    /// regular | bold | black for the caption and tag vocabularies.
    static func weightName(_ weight: Int?) -> String? {
        guard let weight else { return nil }
        if weight >= 750 { return "black" }
        if weight >= 550 { return "bold" }
        return "regular"
    }

    // MARK: - Class fallback

    /// Installed faces to try, best first, for a described-but-unknown font,
    /// with a short description for the log.
    static func classCandidates(for request: Request) -> ([String], String) {
        let styles = Set(request.styles.map { fold($0) })
        let heavy = (request.weight ?? 400) >= 700
        let condensed = styles.contains("condensed") || styles.contains("compressed") || styles.contains("narrow")
        switch fold(request.category ?? "sans") {
        case "serif":
            if styles.contains("highcontrast") || styles.contains("didone") || styles.contains("modern") {
                return (["Didot", "Bodoni 72", "Big Caslon", "Georgia"], "high-contrast serif")
            }
            return (["Georgia", "Baskerville", "Hoefler Text", "Charter", "Times New Roman", "Palatino"], "serif")
        case "slab", "slabserif":
            return (["Rockwell", "Superclarendon", "American Typewriter", "Charter", "Georgia"], "slab serif")
        case "mono", "monospace", "monospaced":
            return (["Menlo", "PT Mono", "Courier New", "Monaco", "Andale Mono"], "monospaced face")
        case "script", "cursive", "calligraphic":
            return (["Snell Roundhand", "Brush Script MT", "SignPainter", "Apple Chancery", "Zapfino"], "script face")
        case "handwritten", "handwriting", "marker", "brush":
            return (["Marker Felt", "Chalkboard SE", "Bradley Hand", "Noteworthy", "Chalkduster"], "handwritten face")
        case "display", "decorative", "poster":
            if condensed { return (["Anton", "Bebas Neue", "Impact", "League Gothic", "Avenir Next Condensed"], "condensed display face") }
            if styles.contains("rounded") { return (["Arial Rounded MT Bold", "Montserrat", "Avenir Next"], "rounded display face") }
            return (["Archivo Black", "Anton", "Impact", "Arial Black", "Phosphate", "Copperplate"], "heavy display face")
        default:
            if condensed {
                return heavy
                    ? (["Bebas Neue", "Anton", "Impact", "Avenir Next Condensed", "DIN Condensed", "Arial Narrow", "PT Sans Narrow"], "condensed heavy sans")
                    : (["Avenir Next Condensed", "PT Sans Narrow", "Arial Narrow", "DIN Condensed", "Bebas Neue"], "condensed sans")
            }
            if styles.contains("rounded") { return (["Arial Rounded MT Bold", "Avenir Next", "Montserrat"], "rounded sans") }
            if styles.contains("geometric") { return (["Montserrat", "Avenir Next", "Futura", "Avenir", "Gill Sans"], "geometric sans") }
            if styles.contains("humanist") { return (["Gill Sans", "PT Sans", "Optima", "Lucida Grande", "Verdana"], "humanist sans") }
            if styles.contains("extended") || styles.contains("wide") { return (["Montserrat", "Avenir Next", "Verdana", "Arial Black"], "wide sans") }
            if styles.contains("blocky") || (request.weight ?? 400) >= 850 {
                return (["Archivo Black", "Montserrat", "Anton", "Arial Black", "Helvetica Neue"], "heavy sans")
            }
            if styles.contains("grotesque") || styles.contains("grotesk") || styles.contains("neogrotesque") {
                return (["Helvetica Neue", "Helvetica", "Arial", "Montserrat"], "grotesque sans")
            }
            return (["Helvetica Neue", "Montserrat", "Avenir Next", "Arial"], "sans")
        }
    }

    static func classKeyword(for request: Request) -> String {
        switch fold(request.category ?? "sans") {
        case "serif", "slab", "slabserif": "serif"
        case "mono", "monospace", "monospaced": "mono"
        default: "sans"
        }
    }

    // MARK: - Known stand-ins

    /// Popular social-video typefaces and the installed faces that read
    /// closest, best first. Keys are folded names without style words.
    static let substitutes: [String: [String]] = [
        // Geometric sans
        "montserrat": ["Avenir Next", "Futura", "Gill Sans"],
        "gotham": ["Montserrat", "Avenir Next", "Futura"],
        "proximanova": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "proximasoft": ["Montserrat", "Avenir Next"],
        "poppins": ["Montserrat", "Avenir Next", "Futura"],
        "raleway": ["Montserrat", "Avenir Next", "Gill Sans"],
        "futurapt": ["Futura", "Avenir Next", "Montserrat"],
        "futura": ["Avenir Next", "Montserrat"],
        "avenir": ["Avenir Next", "Montserrat"],
        "avenirnext": ["Avenir", "Montserrat"],
        "centurygothic": ["Futura", "Avenir Next", "Montserrat"],
        "outfit": ["Montserrat", "Avenir Next", "Futura"],
        "manrope": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "dmsans": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "lexend": ["Montserrat", "Avenir Next"],
        "urbanist": ["Montserrat", "Avenir Next"],
        "plusjakartasans": ["Montserrat", "Avenir Next"],
        "sora": ["Montserrat", "Avenir Next"],
        "questrial": ["Montserrat", "Avenir Next", "Futura"],
        "josefinsans": ["Futura", "Avenir Next", "Montserrat"],
        "kanit": ["Montserrat", "Avenir Next"],
        "prompt": ["Montserrat", "Avenir Next"],
        "nunito": ["Arial Rounded MT Bold", "Avenir Next", "Montserrat"],
        "nunitosans": ["Avenir Next", "Montserrat", "Helvetica Neue"],
        "quicksand": ["Arial Rounded MT Bold", "Avenir Next", "Montserrat"],
        "comfortaa": ["Arial Rounded MT Bold", "Avenir Next"],
        "fredoka": ["Arial Rounded MT Bold", "Montserrat"],
        "fredokaone": ["Arial Rounded MT Bold", "Montserrat"],
        "varelaround": ["Arial Rounded MT Bold", "Avenir Next"],
        "baloo": ["Arial Rounded MT Bold", "Montserrat"],
        // Grotesque / neo-grotesque
        "neuemontreal": ["Helvetica Neue", "Montserrat", "Arial"],
        "ppneuemontreal": ["Helvetica Neue", "Montserrat", "Arial"],
        "neuehaasgrotesk": ["Helvetica Neue", "Helvetica", "Arial"],
        "neuehaasgroteskdisplay": ["Helvetica Neue", "Helvetica", "Arial"],
        "suisseintl": ["Helvetica Neue", "Montserrat", "Arial"],
        "suisse": ["Helvetica Neue", "Montserrat", "Arial"],
        "generalsans": ["Montserrat", "Helvetica Neue", "Avenir Next"],
        "satoshi": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "clashdisplay": ["Montserrat", "Archivo Black", "Avenir Next"],
        "clashgrotesk": ["Montserrat", "Helvetica Neue"],
        "cabinetgrotesk": ["Montserrat", "Helvetica Neue", "Avenir Next"],
        "spacegrotesk": ["DIN Alternate", "Montserrat", "Helvetica Neue"],
        "bricolagegrotesque": ["Montserrat", "Helvetica Neue"],
        "syne": ["Montserrat", "Archivo Black", "Avenir Next"],
        "figtree": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "onest": ["Montserrat", "Helvetica Neue"],
        "geist": ["Helvetica Neue", "Montserrat", "Arial"],
        "instrumentsans": ["Helvetica Neue", "Montserrat", "Arial"],
        "archivo": ["Helvetica Neue", "Arial", "Montserrat"],
        "archivonarrow": ["Arial Narrow", "Avenir Next Condensed", "PT Sans Narrow"],
        "publicsans": ["Helvetica Neue", "PT Sans", "Arial"],
        "redhatdisplay": ["Montserrat", "Avenir Next", "Helvetica Neue"],
        "karla": ["Helvetica Neue", "PT Sans", "Arial"],
        "mulish": ["Avenir Next", "Montserrat", "Helvetica Neue"],
        "heebo": ["Helvetica Neue", "Arial", "Montserrat"],
        "cabin": ["Gill Sans", "PT Sans", "Helvetica Neue"],
        "overpass": ["Helvetica Neue", "PT Sans", "Arial"],
        "chivo": ["Helvetica Neue", "Arial", "Montserrat"],
        "helvetica": ["Helvetica Neue", "Arial"],
        "helveticaneue": ["Helvetica", "Arial"],
        "helveticanow": ["Helvetica Neue", "Helvetica", "Arial"],
        "arial": ["Helvetica Neue", "Helvetica"],
        "inter": ["Helvetica Neue", "Montserrat", "Arial"],
        "roboto": ["Helvetica Neue", "Arial", "Montserrat"],
        "opensans": ["Helvetica Neue", "PT Sans", "Arial"],
        "sfpro": ["Helvetica Neue", "Montserrat", "Arial"],
        "sfprodisplay": ["Helvetica Neue", "Montserrat", "Arial"],
        "sfprotext": ["Helvetica Neue", "Arial"],
        "sanfrancisco": ["Helvetica Neue", "Arial"],
        "segoeui": ["Helvetica Neue", "PT Sans", "Arial"],
        "lato": ["Avenir Next", "Helvetica Neue", "Montserrat"],
        "worksans": ["Helvetica Neue", "Montserrat", "Arial"],
        "rubik": ["Montserrat", "Helvetica Neue", "Arial Rounded MT Bold"],
        "ubuntu": ["PT Sans", "Helvetica Neue", "Montserrat"],
        "sourcesanspro": ["PT Sans", "Helvetica Neue", "Gill Sans"],
        "sourcesans3": ["PT Sans", "Helvetica Neue", "Gill Sans"],
        "ibmplexsans": ["Helvetica Neue", "PT Sans", "Arial"],
        "akzidenzgrotesk": ["Helvetica Neue", "Helvetica", "Arial"],
        "univers": ["Helvetica Neue", "Arial"],
        "franklingothic": ["Helvetica Neue", "Arial", "PT Sans"],
        "tradegothic": ["Helvetica Neue", "Avenir Next Condensed", "Arial Narrow"],
        "myriad": ["PT Sans", "Gill Sans", "Helvetica Neue"],
        "myriadpro": ["PT Sans", "Gill Sans", "Helvetica Neue"],
        "din": ["DIN Alternate", "DIN Condensed", "Helvetica Neue"],
        "dinpro": ["DIN Alternate", "DIN Condensed", "Helvetica Neue"],
        "barlow": ["DIN Alternate", "Helvetica Neue", "Avenir Next"],
        "barlowcondensed": ["DIN Condensed", "Avenir Next Condensed", "Bebas Neue"],
        "barlowsemicondensed": ["DIN Condensed", "Avenir Next Condensed"],
        "exo": ["Montserrat", "Avenir Next", "DIN Alternate"],
        "exo2": ["Montserrat", "Avenir Next", "DIN Alternate"],
        "titillium": ["DIN Alternate", "Montserrat", "Helvetica Neue"],
        "titilliumweb": ["DIN Alternate", "Montserrat", "Helvetica Neue"],
        // Condensed / impact-style
        "impact": ["Anton", "Bebas Neue", "Arial Black", "Avenir Next Condensed"],
        "haettenschweiler": ["Impact", "Anton", "Bebas Neue"],
        "bebasneue": ["Anton", "Impact", "Avenir Next Condensed", "DIN Condensed"],
        "bebas": ["Bebas Neue", "Anton", "Impact", "Avenir Next Condensed"],
        "oswald": ["Bebas Neue", "Anton", "Impact", "Avenir Next Condensed"],
        "anton": ["Impact", "Bebas Neue", "Avenir Next Condensed"],
        "leaguegothic": ["Bebas Neue", "Anton", "Impact", "Avenir Next Condensed"],
        "fjallaone": ["Bebas Neue", "Anton", "Avenir Next Condensed"],
        "teko": ["Bebas Neue", "Anton", "Avenir Next Condensed"],
        "antonio": ["Bebas Neue", "Anton", "Avenir Next Condensed"],
        "staatliches": ["Bebas Neue", "Anton", "Impact"],
        "sixcaps": ["Bebas Neue", "Anton", "Impact"],
        "pathwaygothicone": ["Bebas Neue", "Avenir Next Condensed", "Anton"],
        "bigshouldersdisplay": ["Bebas Neue", "Anton", "Avenir Next Condensed"],
        "druk": ["Anton", "Impact", "Bebas Neue", "Arial Black"],
        "drukwide": ["Archivo Black", "Arial Black", "Montserrat"],
        "knockout": ["Bebas Neue", "Anton", "Impact"],
        "tungsten": ["Bebas Neue", "Anton", "Impact"],
        "compacta": ["Impact", "Anton", "Bebas Neue"],
        "robotocondensed": ["Avenir Next Condensed", "Arial Narrow", "PT Sans Narrow"],
        "opensanscondensed": ["Avenir Next Condensed", "PT Sans Narrow", "Arial Narrow"],
        "ptsansnarrow": ["Avenir Next Condensed", "Arial Narrow"],
        // Heavy display / meme / caption fonts
        "theboldfont": ["Archivo Black", "Anton", "Arial Black", "Montserrat"],
        "thebold": ["Archivo Black", "Anton", "Arial Black", "Montserrat"],
        "komikaaxis": ["Archivo Black", "Marker Felt", "Arial Black"],
        "komika": ["Marker Felt", "Chalkboard SE", "Archivo Black"],
        "bangers": ["Marker Felt", "Archivo Black", "Impact"],
        "luckiestguy": ["Marker Felt", "Archivo Black", "Chalkboard SE"],
        "lilitaone": ["Archivo Black", "Arial Rounded MT Bold", "Marker Felt"],
        "titanone": ["Archivo Black", "Arial Rounded MT Bold", "Arial Black"],
        "bungee": ["Archivo Black", "Arial Black", "Impact"],
        "righteous": ["Montserrat", "Archivo Black", "Avenir Next"],
        "shrikhand": ["Archivo Black", "Marker Felt", "Cooper Black"],
        "cooperblack": ["Archivo Black", "Arial Rounded MT Bold", "Superclarendon"],
        "archivoblack": ["Arial Black", "Anton", "Montserrat", "Helvetica Neue"],
        "arialblack": ["Archivo Black", "Helvetica Neue", "Anton"],
        "alfaslabone": ["Superclarendon", "Rockwell", "Archivo Black"],
        "russoone": ["Montserrat", "Archivo Black", "Avenir Next"],
        "blackopsone": ["Impact", "Archivo Black", "Anton"],
        "chewy": ["Marker Felt", "Chalkboard SE", "Noteworthy"],
        "permanentmarker": ["Marker Felt", "Chalkduster", "Bradley Hand"],
        "caveat": ["Bradley Hand", "Noteworthy", "Marker Felt"],
        "pacifico": ["Brush Script MT", "Snell Roundhand", "SignPainter"],
        "lobster": ["Brush Script MT", "SignPainter", "Snell Roundhand"],
        "dancingscript": ["Snell Roundhand", "Apple Chancery", "Brush Script MT"],
        "greatvibes": ["Snell Roundhand", "Apple Chancery", "Zapfino"],
        "satisfy": ["Brush Script MT", "Snell Roundhand", "SignPainter"],
        "orbitron": ["DIN Alternate", "Montserrat", "Avenir Next"],
        "audiowide": ["DIN Alternate", "Montserrat"],
        "monoton": ["Phosphate", "Copperplate", "Impact"],
        "pressstart2p": ["Menlo", "Monaco", "Courier New"],
        "vt323": ["Menlo", "Monaco", "Courier New"],
        "comicsans": ["Comic Sans MS", "Chalkboard SE", "Marker Felt"],
        "comicneue": ["Comic Sans MS", "Chalkboard SE", "Marker Felt"],
        // Serif
        "instrumentserif": ["Didot", "Bodoni 72", "Georgia"],
        "editorialnew": ["Didot", "Bodoni 72", "Hoefler Text"],
        "ppeditorialnew": ["Didot", "Bodoni 72", "Hoefler Text"],
        "fraunces": ["Didot", "Georgia", "Baskerville"],
        "dmserifdisplay": ["Didot", "Bodoni 72", "Georgia"],
        "dmseriftext": ["Georgia", "Didot", "Baskerville"],
        "sourceserifpro": ["Georgia", "Charter", "Times New Roman"],
        "sourceserif4": ["Georgia", "Charter", "Times New Roman"],
        "crimsontext": ["Hoefler Text", "Georgia", "Baskerville"],
        "crimsonpro": ["Hoefler Text", "Georgia", "Baskerville"],
        "spectral": ["Georgia", "Charter", "Baskerville"],
        "librecaslon": ["Big Caslon", "Hoefler Text", "Baskerville"],
        "librecaslontext": ["Big Caslon", "Hoefler Text", "Baskerville"],
        "playfairdisplay": ["Didot", "Bodoni 72", "Georgia"],
        "playfair": ["Didot", "Bodoni 72", "Georgia"],
        "bodoni": ["Bodoni 72", "Didot", "Georgia"],
        "didot": ["Bodoni 72", "Big Caslon", "Georgia"],
        "abrilfatface": ["Didot", "Bodoni 72", "Superclarendon"],
        "cinzel": ["Copperplate", "Hoefler Text", "Baskerville"],
        "merriweather": ["Georgia", "Charter", "Baskerville"],
        "lora": ["Georgia", "Charter", "Baskerville"],
        "ptserif": ["Georgia", "Charter", "Times New Roman"],
        "garamond": ["Hoefler Text", "Baskerville", "Georgia"],
        "ebgaramond": ["Hoefler Text", "Baskerville", "Georgia"],
        "cormorant": ["Hoefler Text", "Didot", "Baskerville"],
        "cormorantgaramond": ["Hoefler Text", "Didot", "Baskerville"],
        "librebaskerville": ["Baskerville", "Georgia"],
        "times": ["Times New Roman", "Georgia"],
        "timesnewroman": ["Times", "Georgia"],
        "georgia": ["Charter", "Times New Roman", "Baskerville"],
        "caslon": ["Big Caslon", "Hoefler Text", "Baskerville"],
        "minion": ["Hoefler Text", "Georgia", "Baskerville"],
        "minionpro": ["Hoefler Text", "Georgia", "Baskerville"],
        "robotoslab": ["Rockwell", "Superclarendon", "American Typewriter"],
        "rockwell": ["Superclarendon", "American Typewriter", "Georgia"],
        "zillaslab": ["Rockwell", "Superclarendon", "American Typewriter"],
        "arvo": ["Rockwell", "Superclarendon", "American Typewriter"],
        "bitter": ["Rockwell", "Charter", "Georgia"],
        // Mono
        "courier": ["Courier New", "Menlo"],
        "couriernew": ["Courier", "Menlo"],
        "sourcecodepro": ["Menlo", "PT Mono", "Monaco"],
        "firacode": ["Menlo", "PT Mono", "Monaco"],
        "firamono": ["Menlo", "PT Mono", "Monaco"],
        "jetbrainsmono": ["Menlo", "PT Mono", "Monaco"],
        "robotomono": ["Menlo", "PT Mono", "Courier New"],
        "spacemono": ["PT Mono", "Menlo", "Courier New"],
        "ibmplexmono": ["Menlo", "PT Mono", "Courier New"],
        "consolas": ["Menlo", "Monaco", "Courier New"],
        "sfmono": ["Menlo", "Monaco"],
    ]

    // MARK: - Helpers

    static let classKeywords: Set<String> = ["sans", "sansserif", "serif", "mono", "monospace", "unknown", "none", "default", "system"]

    static let weightWords: [String: Int] = [
        "thin": 100, "hairline": 100, "extralight": 200, "ultralight": 200, "light": 300, "book": 400,
        "regular": 400, "normal": 400, "medium": 500, "semibold": 600, "demibold": 600, "demi": 600,
        "bold": 700, "extrabold": 800, "ultrabold": 800, "heavy": 800, "black": 900, "ultra": 900, "fat": 900,
    ]

    static func fold(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
