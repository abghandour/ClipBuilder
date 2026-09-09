import Foundation

nonisolated enum LearnedDocumentBuilder {
    struct Build: Sendable {
        var document: LearnedPreferences
        /// Private staging input, NEVER encoded or displayed as published content.
        var frames: [String: Data]
    }

    @concurrent static func build(profile: BrandProfile, database: Database, benchmarks: AccountBenchmarks? = nil,
                      now: Date = Date(), readFrame: @Sendable (String) throws -> Data = {
                          try Data(contentsOf: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
                      }) async throws -> Build {
        let evidence = try await database.learnedEvidence()
        let measured: AccountBenchmarks?
        if let benchmarks { measured = benchmarks }
        else { measured = try await database.learnedBenchmarks() }
        let lessons = try await database.fetchLessons()
        let people = try await database.fetchPeople()
        let research = try await database.fetchFightResearch()
        return try build(profile: profile, lessons: lessons,
                         people: people, research: research,
                         queryPlans: evidence.research, reviews: evidence.reviews, studies: evidence.studies,
                         benchmarks: measured, now: now, readFrame: readFrame)
    }

    static func build(profile: BrandProfile, lessons: [WizardLesson] = [], people: [PersonRecord] = [],
                      research: [FightResearchRecord] = [], queryPlans: [String] = [], reviews: Int = 0,
                      studies: Int = 0, benchmarks: AccountBenchmarks? = nil, now: Date = Date(),
                      readFrame: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }) throws -> Build {
        let contributor = LearnedPreferences.contributor(profile: profile)
        var sections: [LearnedPreferences.Section] = []
        var frames: [String: Data] = [:]
        func item(_ field: String, _ text: String, id: String? = nil, pinned: Bool = false,
                  evidence: String = "", date: Date? = nil, paths: [String] = [],
                  numbers: [String: Double] = [:]) -> LearnedPreferences.Item {
            let names = paths.compactMap { path -> String? in
                guard let data = try? readFrame(path), data.starts(with: [0xff, 0xd8, 0xff]) else { return nil }
                let name = "learned/\(contributor)/frames/\(LearnedPreferences.stableID(data.base64EncodedString())).jpg"
                frames[name] = data
                return name
            }
            let sectionKey: String
            switch field {
            case "category", "rubric": sectionKey = "taste"
            case "lesson": sectionKey = "lessons"
            case "tag", "hashtag": sectionKey = "vocabulary"
            case "person": sectionKey = "people"
            case "queryPlan": sectionKey = "research"
            default: sectionKey = "style"
            }
            let editedAt = profile.learnedSharing.updatedAt[sectionKey] ?? .distantPast
            let updatedAt = field == "lesson" ? date ?? .distantPast : max(date ?? .distantPast, editedAt)
            return .init(id: id ?? LearnedPreferences.stableID(field + ":" + text), field: field,
                         text: text, pinned: pinned, evidence: evidence, updatedAt: updatedAt,
                         frames: names, numbers: numbers)
        }
        func section(_ kind: LearnedPreferences.Kind, _ items: [LearnedPreferences.Item], evidence: String) {
            let date = profile.learnedSharing.updatedAt[kind.rawValue]
                ?? items.map(\.updatedAt).max() ?? .distantPast
            sections.append(.init(kind: kind, enabled: profile.learnedSharing.enabled[kind.rawValue] ?? kind.defaultEnabled,
                                  updatedAt: date, evidence: evidence, items: items))
        }
        let provenance = profile.houseStyleProvenance
        var style: [LearnedPreferences.Item] = []
        for (field, text) in [("houseStyle", profile.houseStyle), ("hookStyle", profile.learnedHookStyle),
                              ("layout", profile.learnedLayoutPreference)] where !text.isEmpty {
            style.append(item(field, text, id: field, evidence: provenance?.shortLabel ?? "Profile", date: provenance?.at))
        }
        if profile.defaultPacing != EditPacing() {
            style.append(item("pacing", profile.defaultPacing.cadence.rawValue + ", " + profile.defaultPacing.curve.rawValue, id: "pacing"))
        }
        style += profile.captionLanguages.map { item("captionLanguage", $0) }
        section(.style, style, evidence: "Profile style; \(studies) studies")
        var taste: [LearnedPreferences.Item] = []
        if !profile.tasteRubric.isEmpty {
            taste.append(item("rubric", profile.tasteRubric, id: "rubric", date: profile.tasteRubricProvenance?.at,
                              paths: profile.tasteExemplarFrames))
        }
        taste += profile.tasteCategories.map {
            item("category", $0.label + ": " + $0.rubric, id: $0.key, paths: $0.exemplarFrames,
                 numbers: ["studies": Double($0.studiedCount)])
        }
        section(.taste, taste, evidence: "\(studies) exemplar studies")
        section(.lessons, lessons.compactMap { lesson in
            let id = lesson.learnedID.isEmpty ? LearnedPreferences.stableID(lesson.text) : lesson.learnedID
            guard !profile.learnedSharing.dismissedLessons.contains(id) else { return nil }
            return item("lesson", lesson.text, id: id, pinned: lesson.pinned, evidence: lesson.evidence,
                        date: AIProvenance.parseDate(lesson.updatedAt ?? lesson.createdAt) ?? .distantPast)
        }, evidence: "\(reviews) reviews; \(lessons.count) distilled lessons")
        let tags = profile.tagSchema.keys.sorted().flatMap { key in
            (profile.tagSchema[key] ?? []).map { item("tag", key + ": " + $0, id: LearnedPreferences.stableID("tag:" + key.lowercased() + ":" + $0.lowercased())) }
        }
        section(.vocabulary, tags + profile.hashtags.map { item("hashtag", $0, id: LearnedPreferences.stableID("hashtag:" + $0.lowercased()), pinned: true) }, evidence: "Profile vocabulary")
        var measured: [LearnedPreferences.Item] = []
        if let b = benchmarks {
            var numbers = ["savesPer1k": b.savesPer1k, "sharesPer1k": b.sharesPer1k,
                           "commentsPer1k": b.commentsPer1k, "reels": Double(b.reelCount)]
            for (key, value) in [("durationMin", b.durationSweetSpotMin), ("durationMax", b.durationSweetSpotMax),
                                 ("durationMedian", b.durationTopMedian), ("cutsPerMinute", b.cutsPerMinuteTop)] {
                if let value { numbers[key] = Double(value) }
            }
            measured.append(item("summary", "", id: "summary", date: b.computedAt, numbers: numbers))
            measured += b.bestPostingSlots.map { item("slot", "", id: $0.id, date: b.computedAt,
                numbers: ["weekday": Double($0.weekday), "hour": Double($0.hour), "posts": Double($0.posts)]) }
            measured += b.topHashtags.map { item("hashtagLift", $0.tag, id: $0.id, date: b.computedAt,
                                                numbers: ["lift": $0.lift, "posts": Double($0.posts)]) }
            measured += b.topTraits.map { item("topTrait", $0, date: b.computedAt) }
            measured += b.bottomTraits.map { item("bottomTrait", $0, date: b.computedAt) }
        }
        section(.benchmarks, measured, evidence: "\(benchmarks?.reelCount ?? 0) reels with insights")
        section(.people, people.map { item("person", $0.name + ": " + $0.descriptor) }, evidence: "\(people.count) registered people")
        let savedPlans = research.compactMap { record -> LearnedPreferences.Item? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(record.summaryJSON.utf8)) as? [String: Any],
                  let plan = object["query_plan"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: plan) else { return nil }
            return item("queryPlan", researchText(String(decoding: data, as: UTF8.self)), date: record.researchedAt)
        }
        section(.research, research.map { item("summary", researchText($0.summaryJSON), date: $0.researchedAt) }
            + savedPlans + queryPlans.map { item("queryPlan", researchText($0)) }, evidence: "\(research.count) research summaries; \(queryPlans.count + savedPlans.count) saved plans")
        let secrets = profile.socials.values.flatMap { [$0.cookies, $0.handle, $0.url] }
            + [profile.sourceFolder, profile.outputFolder, profile.logoPath, benchmarks?.username ?? ""]
        let document = try LearnedRedaction.apply(.init(contributor: contributor, sections: sections), secrets: secrets)
        let referenced = Set(document.frameNames)
        return Build(document: document, frames: frames.filter { referenced.contains($0.key) })
    }

    /// Only approved narrative keys survive; source objects and arbitrary JSON never travel.
    static func researchText(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return "" }
        let keys = ["angle", "arc", "hook_line", "overlay_lines", "talking_points", "sentiment", "controversy",
                    "summary", "queries", "subreddits", "optimal_duration", "pacing_cuts_per_minute"]
        var parts: [String] = []
        for key in keys {
            if let value = object[key] as? String { parts.append(key + ": " + value) }
            if let values = object[key] as? [String] { parts.append(key + ": " + values.joined(separator: "; ")) }
        }
        if let story = object["story"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: story) {
            parts.append(researchText(String(decoding: data, as: UTF8.self)))
        }
        return parts.joined(separator: "\n")
    }
}
