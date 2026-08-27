import Foundation

/// Profile starter: turns a short brand interview (audience, tone,
/// inspirations, hard nos) into a founding taste rubric, house style, and
/// starter video-type categories — the cold-start seed that studying real
/// reels later refines.
nonisolated enum ProfileStarter {

    struct Result: Sendable {
        var rubric: String
        var houseStyle: String
        var categories: [TasteCategory]
    }

    static func prompt(domain: String, brand: String,
                       audience: String, tone: String,
                       inspiration: String, avoid: String) -> String {
        func answer(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(not specified)" : trimmed
        }
        return """
        You are setting up the editorial brain of a short-form social video brand ("\(brand)", domain: \(domain)). From the owner's answers below, write its founding style documents. They steer an AI that tags raw footage and plans reels, so make every line operational — something a machine can apply to footage — not marketing fluff.

        ## THE OWNER'S ANSWERS
        - Who the content is for: \(answer(audience))
        - Tone and personality: \(answer(tone))
        - Accounts/creators they admire and why: \(answer(inspiration))
        - What they never want posted: \(answer(avoid))

        Return ONLY a JSON object:
        {
          "taste_rubric": "<5-8 lines describing what a KEEPER MOMENT looks like in raw footage for this brand — visual, concrete, checkable per scene>",
          "house_style": "<5 short sections covering: pacing & cuts, hooks, text overlays, captions, what to always/never do — each 1-2 lines>",
          "categories": [{"key": "<kebab-case>", "label": "<short name>", "rubric": "<2-3 lines: what the best moments of this video type look like>"}]
        }
        Give 2–4 categories matching the video types this domain naturally produces. Honor the "never post" answer as hard rules inside both documents.
        """
    }

    static func parse(_ response: String) -> Result? {
        guard let object = AIResponseParser.jsonObject(from: response),
              let rubric = (object["taste_rubric"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !rubric.isEmpty,
              let houseStyle = (object["house_style"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !houseStyle.isEmpty
        else { return nil }
        let categories = (object["categories"] as? [[String: Any]] ?? []).compactMap { entry -> TasteCategory? in
            guard let key = (entry["key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty,
                  let label = (entry["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
            return TasteCategory(key: key, label: label,
                                 rubric: (entry["rubric"] as? String)?
                                     .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return Result(rubric: rubric, houseStyle: houseStyle, categories: categories)
    }
}
