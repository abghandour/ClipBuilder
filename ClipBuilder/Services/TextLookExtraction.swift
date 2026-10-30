import Foundation

/// Text Look Wizard: the prompt, the video frame-sampling schedule and the
/// response parser behind "Create from File…" in the Text Looks studio. A
/// reference image or video goes in; overlay elements, a caption style and a
/// name tag style come out, mapped onto the vocabularies the renderers
/// already understand. No database, no network: everything here is pure so
/// it can be tested without the app.
nonisolated enum TextLookExtraction {
    /// What the user asked the wizard to import.
    enum Target: String, CaseIterable, Sendable, Identifiable {
        case overlay, captions, nameTag
        var id: String { rawValue }

        var label: String {
            switch self {
            case .overlay: "Overlay template"
            case .captions: "Caption style"
            case .nameTag: "Name tag style"
            }
        }

        var detail: String {
            switch self {
            case .overlay: "Titles, labels, logos and badges as a reusable overlay template."
            case .captions: "The spoken-word captions as a new caption style."
            case .nameTag: "The name plate (name and role) as a new name tag style."
            }
        }
    }

    /// One overlay element the model found. Sendable so parsing can run off
    /// the main actor and the result cross back for cropping and saving.
    struct OverlayElement: Sendable, Equatable {
        enum Kind: String, Sendable { case text, image }
        var kind: Kind
        var text = ""
        var description = ""
        var x = 0.5
        var y = 0.5
        var w = 0.3
        var h = 0.1
        var fontcolor = "white"
        /// Matched family for the text renderer; nil keeps the default face.
        var fontFamily: String?
        var bold = false
        var italic = false
        var underline: Bool?
        var strikethrough: Bool?
        var bgcolor: String?
        var boxOpacity: Double?
        var dynamic = false
        /// Video timing in seconds; nil start = 0, nil end = until the end.
        var start: Double?
        var end: Double?
        var enter: String?
        var exit: String?
        /// A time at which the element is fully visible (crop source for marks).
        var at: Double?
    }

    struct Parsed: Sendable, Equatable {
        var overlays: [OverlayElement] = []
        var caption: CaptionStyle?
        var tag: TagStyle?
        /// Effects the model saw that the app cannot reproduce; logged, never invented.
        var notes: [String] = []
    }

    // MARK: - Frame sampling

    static let maxSampledFrames = 16

    /// Dense over the first 1.5 s (entrances) and the last 1.2 s (exits),
    /// evenly spaced across the body. Sorted, de-duplicated, inside the clip.
    static func sampleTimestamps(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [0] }
        let end = max(0, duration - 0.05)
        var times: [Double] = [0, 0.12, 0.3, 0.55, 0.9, 1.4]
        let bodyCount = 6
        for index in 1...bodyCount {
            times.append(1.4 + (end - 1.4 - 1.2) * Double(index) / Double(bodyCount + 1))
        }
        times += [end - 1.2, end - 0.7, end - 0.3, end]
        var seen = Set<Int>()
        let kept = times
            .map { min(end, max(0, $0)) }
            .sorted()
            .filter { seen.insert(Int(($0 * 20).rounded())).inserted }
        if kept.count <= maxSampledFrames { return kept }
        let stride = Double(kept.count - 1) / Double(maxSampledFrames - 1)
        return (0..<maxSampledFrames).map { kept[Int((Double($0) * stride).rounded())] }
    }

    // MARK: - Prompt

    static func prompt(targets: Set<Target>, isVideo: Bool, duration: Double, fontFamilies: [String]) -> String {
        var lines: [String] = []
        if isVideo {
            lines.append("""
            You are extracting the TEXT DESIGN from a short social video (\(String(format: "%.1f", duration)) s) so it can be recreated inside a video editor. You see the whole clip (or stills sampled densely at the start and the end, evenly in the middle). Study how text ENTERS and LEAVES, when each element is on screen, and how spoken-word captions appear.
            """)
        } else {
            lines.append("You are extracting the TEXT DESIGN from one frame of a social video so it can be recreated inside a video editor.")
        }
        lines.append("Only overlay elements matter: titles, captions, name plates, logos, badges, watermarks, stickers. DISCARD the footage itself (people, background, scenery).")
        lines.append("Return ONE JSON object with these keys (omit a key when it was not requested):")

        if targets.contains(.overlay) {
            lines.append("""
            "overlays": [
              {"kind": "text", "text": "<exact text>", "x": <0-1 center x>, "y": <0-1 center y>, "w": <0-1 width>, "h": <0-1 height>, "fontcolor": "#hex", "font_family": "<typeface>", "font_category": "<category>", "font_style": "<style words>", "font_weight": <100-900>, "italic": true|false, "bgcolor": "#hex or null", "box_opacity": <0-1, 0 when no plate>, "dynamic": true|false\(isVideo ? ", \"start\": <seconds>, \"end\": <seconds or null when it stays to the end>, \"enter\": \"<effect>\", \"exit\": \"<effect>\", \"at\": <a second where it is fully visible>" : "")},
              {"kind": "image", "x": ..., "y": ..., "w": ..., "h": ..., "description": "<what it is, e.g. 'UFC logo'>"\(isVideo ? ", \"start\": ..., \"end\": ..., \"enter\": ..., \"exit\": ..., \"at\": <a second where it is fully visible>" : "")}
            ]
            Overlay rules: coordinates are fractions of the full frame with x/y at the element's CENTER. "text" is anything that is essentially styled text; "image" is a graphical mark that plain text cannot recreate (tight box). "dynamic" is true for the main caption-style line a future video would replace with its own words, false for names, labels and branding. Do NOT list spoken-word subtitles here\(targets.contains(.captions) ? "; they belong to \"captions\"" : ""). 2-8 elements typical.
            """)
        }
        if targets.contains(.captions) {
            lines.append("""
            "captions": {"present": true|false, "font_family": "<typeface>", "font_category": "<category>", "font_style": "<style words>", "font_weight": <100-900>, "italic": true|false, "letter_spacing_em": <-0.1..0.3>, "color": "#hex", "uppercase": true|false, "size": <24-120, the font size in pixels on a frame scaled to 1080 px wide; a capital letter stands about 0.7 × the font size, so measure the capital height as a fraction of the frame width, × 1080, ÷ 0.7>, "position": "bottom|middle|top", "alignment": "leading|center|trailing", "words_per_page": <1-8>, "bg_on": true|false, "bg_color": "#hex", "bg_radius": <0-60 px>, "stroke_width": <0-6>, "shadow": true|false, "highlight": "none|color|box|scale", "highlight_color": "#hex", "highlight_look": {"font_family": "<typeface>", "font_category": "<category>", "font_style": "<style words>", "font_weight": <100-900>, "italic": true|false, "size_scale": <0.6-1.6 relative to the regular words>} or null, "emphasis": "none|color|scale|both|font", "emphasis_color": "#hex", "emphasis_look": {same keys as highlight_look} or null, "animation": "none|pop|slide-up|fade", "reveal": "none|word", "reveal_motion": true|false, "emoji": true|false, "unsupported": "<effects you saw that none of the options express, or empty>"}
            Caption rules: captions are the subtitles of the spoken words, usually a few words per page near the bottom or middle. "highlight" is how the word being spoken is marked (a different color, a colored box behind it, or a bigger size). "emphasis" is how key words are marked; "font" when they switch to a different typeface (an italic serif dropped into a bold sans line, a script word, ...). "highlight_look" / "emphasis_look" describe the face of the lit or emphasised words ONLY when it differs from the regular words (different typeface, italic, or size); null otherwise. "reveal":"word" when words appear one at a time; "reveal_motion" when each word also pops or slides in. "animation" is how each caption page enters.
            """)
        }
        if targets.contains(.nameTag) {
            lines.append("""
            "name_tag": {"present": true|false, "name": {"font_family": "<typeface>", "font_category": "<category>", "font_style": "<style words>", "font_weight": <100-900>, "color": "#hex", "italic": true|false, "uppercase": true|false, "underline": true|false}, "description": {"present": true|false, "font_family": "<typeface>", "font_category": "<category>", "font_style": "<style words>", "font_weight": <100-900>, "color": "#hex", "italic": true|false, "uppercase": true|false, "scale": <0.4-1.0 relative to the name line>}, "alignment": "leading|center|trailing", "bg_on": true|false, "bg_color": "#hex", "bg_opacity": <0-1>, "bg_radius": <0-80 px>}
            Name tag rules: the name plate identifying who is on screen; "description" is the smaller second line (role, team, record). Do not invent one when there is none ("present": false).
            """)
        }
        lines.append("""
        Typography rules, for every "font_family": name the REAL typeface as a type designer would identify it (Montserrat, Bebas Neue, Impact, Proxima Nova, Helvetica Neue, Playfair Display, The Bold Font, Komika Axis, ...). Commit to your most likely guess even when unsure; never answer "sans", "unknown" or a generic class as the family. Then describe the letterforms so a stand-in can be chosen when that font is missing: "font_category" is one of sans, serif, slab, mono, script, handwritten, display; "font_style" is a comma-separated pick from geometric, grotesque, humanist, condensed, extended, rounded, high-contrast, blocky (empty when none applies); "font_weight" is the stroke weight 100-900 (300 light, 400 regular, 700 bold, 900 black); "italic" is true only when the letters slant; "letter_spacing_em" is the tracking as a fraction of the font size (0 normal, 0.05 slightly open, 0.15 wide, -0.03 tight). Look at the actual letter shapes: single-storey vs double-storey a and g, round or squarish O, stroke contrast, width of the M, terminals.
        """)
        if isVideo {
            lines.append("""
            Effects vocabulary for "enter" and "exit": \(TextOverlayItem.transitionChoices.joined(separator: ", ")). Choose the closest one: a text that grows in is "pop", a text that moves in from a side is the slide toward its resting place (slide_left = arrives moving left), a text that appears abruptly is "cut". When several elements share one entrance, say so by giving them the same "start".
            """)
        }
        if !fontFamilies.isEmpty {
            lines.append("Custom fonts the editor has besides the standard macOS fonts: \(fontFamilies.prefix(60).joined(separator: ", ")). Name one of them ONLY when the text really is set in that typeface; otherwise name the typeface you see.")
        }
        lines.append("Return ONLY the JSON object.")
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Parsing

    static func parse(_ response: String, targets: Set<Target>, fonts: FontMatch.Catalog) -> Parsed {
        var parsed = Parsed()
        guard let object = AIResponseParser.jsonObject(from: response) else { return parsed }
        if targets.contains(.overlay), let raw = object["overlays"] as? [[String: Any]] {
            var fontNotes = Set<String>()
            parsed.overlays = raw.compactMap { element in
                guard var parsedElement = overlayElement(element) else { return nil }
                if parsedElement.kind == .text, let request = fontRequest(element) {
                    let match = FontMatch.match(request, in: fonts)
                    parsedElement.fontFamily = FontMatch.classKeywords.contains(match.family) ? nil : match.family
                    // "Montserrat Bold Italic" with no separate trait fields.
                    if element["bold"] == nil, fontWeight(element) == nil, let weight = match.weight { parsedElement.bold = weight >= 600 }
                    if element["italic"] == nil, match.italic { parsedElement.italic = true }
                    if let note = match.note, fontNotes.insert(note).inserted {
                        parsed.notes.append("Overlay “\(parsedElement.text.prefix(24))”: \(note)")
                    }
                }
                return parsedElement
            }
        }
        if targets.contains(.captions), let raw = object["captions"] as? [String: Any], present(raw) {
            let (style, note) = captionStyle(raw, fonts: fonts)
            parsed.caption = style
            if let note { parsed.notes.append("Caption font: \(note)") }
            if let unsupported = raw["unsupported"] as? String,
               !unsupported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed.notes.append("Caption effects not reproduced: \(unsupported)")
            }
        }
        if targets.contains(.nameTag), let raw = object["name_tag"] as? [String: Any], present(raw) {
            let (style, notes) = tagStyle(raw, fonts: fonts)
            parsed.tag = style
            parsed.notes += notes.map { "Name tag font: \($0)" }
            if let description = raw["description"] as? [String: Any], !present(description) {
                parsed.notes.append("The reference name plate has no second line; name tags always carry one, so the style keeps the default Role line.")
            }
        }
        return parsed
    }

    private static func present(_ raw: [String: Any]) -> Bool {
        (raw["present"] as? Bool) ?? true
    }

    /// The typeface fields of one text, nil when the model said nothing
    /// about its font. Legacy keys ("font_class", "weight", "bold") count.
    static func fontRequest(_ raw: [String: Any]) -> FontMatch.Request? {
        var request = FontMatch.Request()
        request.family = (raw["font_family"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        request.category = (raw["font_category"] as? String ?? raw["font_class"] as? String)?
            .lowercased().trimmingCharacters(in: .whitespaces)
        if let styles = raw["font_style"] as? String {
            request.styles = styles.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else if let styles = raw["font_style"] as? [String] {
            request.styles = styles.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        }
        request.weight = fontWeight(raw)
        request.italic = raw["italic"] as? Bool ?? false
        let empty = (request.family ?? "").isEmpty && request.category == nil && request.styles.isEmpty && request.weight == nil
        return empty ? nil : request
    }

    /// 100–900 from "font_weight", a legacy "weight" word, or a "bold" flag.
    static func fontWeight(_ raw: [String: Any]) -> Int? {
        if let weight = number(raw["font_weight"] ?? raw["weight"]) { return Int(min(900, max(100, weight)).rounded()) }
        if let word = (raw["weight"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
           let weight = FontMatch.weightWords[word.filter { $0 != " " && $0 != "-" }] { return weight }
        if let bold = raw["bold"] as? Bool { return bold ? 700 : 400 }
        return nil
    }

    static func overlayElement(_ raw: [String: Any]) -> OverlayElement? {
        let kind: OverlayElement.Kind = (raw["kind"] as? String) == "image" ? .image : .text
        var element = OverlayElement(kind: kind)
        element.x = number(raw["x"]) ?? 0.5
        element.y = number(raw["y"]) ?? 0.5
        element.w = min(1, max(0.02, number(raw["w"]) ?? 0.3))
        element.h = min(1, max(0.02, number(raw["h"]) ?? 0.1))
        element.start = number(raw["start"]).map { max(0, $0) }
        element.end = number(raw["end"])
        if let start = element.start, let end = element.end, end <= start { element.end = nil }
        element.enter = transition(raw["enter"] as? String)
        element.exit = transition(raw["exit"] as? String)
        element.at = number(raw["at"]).map { max(0, $0) }
        switch kind {
        case .image:
            element.description = (raw["description"] as? String ?? "overlay mark")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .text:
            element.text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !element.text.isEmpty else { return nil }
            element.fontcolor = color(raw["fontcolor"]) ?? "white"
            element.bold = raw["bold"] as? Bool ?? ((fontWeight(raw) ?? 400) >= 600)
            element.italic = raw["italic"] as? Bool ?? false
            element.underline = raw["underline"] as? Bool
            element.strikethrough = raw["strikethrough"] as? Bool
            if let bg = color(raw["bgcolor"]) {
                element.bgcolor = bg
                element.boxOpacity = number(raw["box_opacity"]) ?? 0.6
            }
            element.dynamic = raw["dynamic"] as? Bool ?? false
        }
        return element
    }

    /// Normalize a free-form effect name onto `TextOverlayItem.transitionChoices`.
    /// "from <side>" names where the element comes from; a bare direction
    /// names where it moves to (slide_left = arrives moving left).
    static func transition(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if TextOverlayItem.transitionChoices.contains(value) { return value }
        let words = value.split(whereSeparator: { $0 == "_" }).map(String.init)
        let fromSide: [String: String] = ["left": "slide_right", "right": "slide_left",
                                          "bottom": "slide_up", "below": "slide_up", "under": "slide_up",
                                          "top": "slide_down", "above": "slide_down"]
        let toward: [String: String] = ["left": "slide_left", "right": "slide_right",
                                        "up": "slide_up", "upward": "slide_up", "upwards": "slide_up",
                                        "down": "slide_down", "downward": "slide_down", "downwards": "slide_down"]
        if let index = words.firstIndex(of: "from"), let side = words.dropFirst(index + 1).first(where: { fromSide[$0] != nil }) {
            return fromSide[side]
        }
        if words.contains(where: { ["slide", "slides", "sliding", "move", "moves", "swipe", "fly", "flies", "wipe", "push"].contains($0) }),
           let direction = words.first(where: { toward[$0] != nil }) {
            return toward[direction]
        }
        if let direction = words.first(where: { toward[$0] != nil }), words.count <= 2 { return toward[direction] }
        if words.contains(where: { ["fade", "fades", "dissolve", "dissolves", "crossfade"].contains($0) }) { return "fade" }
        if words.contains(where: { ["pop", "pops", "zoom", "zooms", "scale", "scales", "bounce", "bounces", "grow", "grows", "spring", "springs", "shrink", "shrinks"].contains($0) }) { return "pop" }
        if words.contains(where: { ["none", "hard", "instant", "instantly", "cut", "appear", "appears", "disappear", "disappears", "abrupt", "abruptly", "snap", "snaps"].contains($0) }) { return "cut" }
        return nil
    }

    /// The caption style plus the font note when a stand-in was chosen.
    static func captionStyle(_ raw: [String: Any], fonts: FontMatch.Catalog) -> (CaptionStyle, String?) {
        var style = CaptionStyle()
        var fontNote: String?
        var match: FontMatch.Result?
        if let request = fontRequest(raw) {
            match = FontMatch.match(request, in: fonts)
            style.font = match!.family
            fontNote = match!.note
        }
        style.color = color(raw["color"]) ?? "#ffffff"
        style.weight = FontMatch.weightName(fontWeight(raw) ?? match?.weight)
        style.uppercase = raw["uppercase"] as? Bool
        style.position = pick(raw["position"], from: ["bottom", "middle", "top"]) ?? "bottom"
        style.alignment = pick(raw["alignment"], from: ["leading", "center", "trailing"])
        style.wordsPerPage = number(raw["words_per_page"]).map { Int(min(8, max(1, $0)).rounded()) }
        style.bgOn = raw["bg_on"] as? Bool ?? false
        if let bg = color(raw["bg_color"]) { style.bgColor = bg }
        style.bgRadius = number(raw["bg_radius"]).map { min(60, max(0, $0)) }
        style.strokeWidth = number(raw["stroke_width"]).map { min(6, max(0, $0)) }
        style.shadow = raw["shadow"] as? Bool
        let size = number(raw["size"]).map { min(120, max(24, $0)) }
        if let em = number(raw["letter_spacing_em"]) {
            // Tracking in em × the caption size gives the renderer's pixels at 1080p.
            style.letterSpacing = min(6, max(-2, (em * (size ?? 49) * 10).rounded() / 10))
        } else {
            style.letterSpacing = number(raw["letter_spacing"]).map { min(6, max(-2, $0)) }
        }
        style.highlight = pick(raw["highlight"], from: ["none", "color", "box", "scale"])
        style.highlightColor = color(raw["highlight_color"])
        style.emphasis = pick(raw["emphasis"], from: ["none", "color", "scale", "both", "font"])
        style.emphasisColor = color(raw["emphasis_color"])
        // A lit or emphasised word may wear its own face: family, italic,
        // weight and an absolute size (points at 1080) in its state decor.
        var stateNotes: [String] = []
        if let look = raw["highlight_look"] as? [String: Any],
           let (family, decor, note) = stateLook(look, regularSize: size ?? 49, fonts: fonts) {
            style.highlightFont = family
            style.highlightDecor = decor
            if let note { stateNotes.append("highlighted words: \(note)") }
            if style.resolvedHighlight == "none" { style.highlight = "color" }
        }
        if let look = raw["emphasis_look"] as? [String: Any],
           let (family, decor, note) = stateLook(look, regularSize: size ?? 49, fonts: fonts) {
            style.emphasisFont = family
            style.emphasisDecor = decor
            if let note { stateNotes.append("emphasised words: \(note)") }
            if style.resolvedEmphasis == "none" { style.emphasis = "font" }
        }
        if !stateNotes.isEmpty {
            fontNote = ([fontNote].compactMap { $0 } + stateNotes).joined(separator: " ")
        }
        style.animation = pick(raw["animation"], from: ["none", "pop", "slide-up", "fade"])
            ?? captionAnimation(raw["animation"] as? String)
        style.reveal = pick(raw["reveal"], from: ["none", "word"])
        style.revealMotion = raw["reveal_motion"] as? Bool
        style.emoji = raw["emoji"] as? Bool
        var text = CaptionWordDecor()
        text.italic = raw["italic"] as? Bool ?? (match?.italic == true ? true : nil)
        text.size = size
        if text != CaptionWordDecor() { style.text = text }
        return (style, fontNote)
    }

    /// The face of a highlight or emphasis state: a family for the style's
    /// per-state font field (nil keeps the regular family), the state decor,
    /// and the stand-in note. nil when the look says nothing usable.
    static func stateLook(_ raw: [String: Any], regularSize: Double,
                          fonts: FontMatch.Catalog) -> (String?, CaptionWordDecor, String?)? {
        var decor = CaptionWordDecor()
        var family: String?
        var note: String?
        var weight = fontWeight(raw)
        var italic = raw["italic"] as? Bool
        if let request = fontRequest(raw) {
            let match = FontMatch.match(request, in: fonts)
            family = match.family
            note = match.note
            if weight == nil { weight = match.weight }
            if italic == nil, match.italic { italic = true }
        }
        decor.italic = italic
        decor.weight = FontMatch.weightName(weight)
        if let scale = number(raw["size_scale"]) {
            decor.size = min(120, max(24, (regularSize * min(1.6, max(0.6, scale))).rounded()))
        }
        guard family != nil || decor != CaptionWordDecor() else { return nil }
        return (family, decor, note)
    }

    /// Map a free-form caption entrance onto pop / slide-up / fade.
    static func captionAnimation(_ raw: String?) -> String? {
        guard let mapped = transition(raw) else { return nil }
        switch mapped {
        case "pop": return "pop"
        case "slide_up", "slide_down", "slide_left", "slide_right": return "slide-up"
        case "fade": return "fade"
        default: return "none"
        }
    }

    /// The tag style plus one font note per stand-in chosen.
    static func tagStyle(_ raw: [String: Any], fonts: FontMatch.Catalog) -> (TagStyle, [String]) {
        var style = TagStyle()
        var notes: [String] = []
        if let name = raw["name"] as? [String: Any] {
            style.name = tagLine(name, base: style.name, fonts: fonts, notes: &notes)
        }
        if let description = raw["description"] as? [String: Any], present(description) {
            style.description = tagLine(description, base: style.description, fonts: fonts, notes: &notes)
        }
        style.alignment = pick(raw["alignment"], from: ["leading", "center", "trailing"]) ?? "leading"
        style.bgOn = raw["bg_on"] as? Bool ?? true
        if let bg = color(raw["bg_color"]) { style.bgColor = bg }
        if let opacity = number(raw["bg_opacity"]) { style.bgOpacity = min(1, max(0, opacity)) }
        if let radius = number(raw["bg_radius"]) { style.cornerRadius = min(80, max(0, radius)) }
        return (style, notes)
    }

    private static func tagLine(_ raw: [String: Any], base: TagLineStyle, fonts: FontMatch.Catalog,
                                notes: inout [String]) -> TagLineStyle {
        var line = base
        var match: FontMatch.Result?
        if let request = fontRequest(raw) {
            match = FontMatch.match(request, in: fonts)
            // The tag renderer takes a family name or nil (system); a bare
            // class keyword keeps the default face.
            if let family = match?.family, !FontMatch.classKeywords.contains(family) { line.font = family }
            if let note = match?.note, !notes.contains(note) { notes.append(note) }
        }
        if let color = color(raw["color"]) { line.color = color }
        if let bold = raw["bold"] as? Bool { line.bold = bold } else if let weight = fontWeight(raw) ?? match?.weight { line.bold = weight >= 600 }
        if let italic = raw["italic"] as? Bool { line.italic = italic } else if match?.italic == true { line.italic = true }
        if let uppercase = raw["uppercase"] as? Bool { line.uppercase = uppercase }
        if let underline = raw["underline"] as? Bool { line.underline = underline }
        if let scale = number(raw["scale"]) { line.scale = min(1, max(0.4, scale)) }
        return line
    }

    // MARK: - Value helpers

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return nil
    }

    static func pick(_ value: Any?, from choices: [String]) -> String? {
        guard let string = (value as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
              choices.contains(string) else { return nil }
        return string
    }

    /// Accept "#rgb", "#rrggbb", "#rrggbbaa" or a CSS color word; reject junk.
    static func color(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty,
              string.lowercased() != "null", string.lowercased() != "none" else { return nil }
        if string.hasPrefix("#") {
            let hex = string.dropFirst()
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            return string.lowercased()
        }
        return string.allSatisfy(\.isLetter) ? string.lowercased() : nil
    }
}
