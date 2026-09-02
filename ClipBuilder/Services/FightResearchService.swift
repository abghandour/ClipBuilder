import Foundation

/// Fight research: identify a video's fight, crawl the profile's configured
/// web sources for fan reactions with PLAIN HTTP (Reddit's public RSS feeds,
/// Google News RSS, site search + page fetches — no logins, no model web tools),
/// and have a model distill the crawled corpus into an editable story that
/// is saved as video metadata. The model only GUIDES retrieval (it writes
/// the search queries) and summarizes; all fetching is standard code.
actor FightResearchService {
    private let ai: AIService

    init(ai: AIService) {
        self.ai = ai
    }

    /// The fight being researched — guessed by the app, confirmed/edited by
    /// the user before any crawling.
    nonisolated struct Identity: Sendable, Equatable {
        /// "Jan Blachowicz vs Carlos Ulberg"
        var fighters: String = ""
        /// "UFC 330" — empty when unknown.
        var event: String = ""
        /// Free-form date ("March 2026") — empty when unknown.
        var date: String = ""

        var label: String {
            var parts = [fighters]
            if !event.isEmpty { parts.append(event) }
            if !date.isEmpty { parts.append(date) }
            return parts.filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }

    /// Best-effort identity guess from what analysis already knows: named
    /// people detected in the video, the extracted outcome, and the filename.
    nonisolated static func guessIdentity(video: VideoRecord, people: [PersonRecord],
                                          videoPersonKeys: [String],
                                          outcomes: [FightOutcome]) -> Identity {
        var identity = Identity()
        let namesByKey = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0) })
        let outcome = outcomes.first { $0.videoID == video.id }
        // Prefer the outcome's winner/loser (the actual fight pairing) over
        // the full detected cast, which includes coaches and refs.
        var fighters = [outcome?.winnerKey, outcome?.loserKey]
            .compactMap { $0.flatMap { namesByKey[$0] } }
            .filter { !$0.name.isEmpty }
            .map(\.name)
        if fighters.count < 2 {
            fighters = videoPersonKeys
                .compactMap { namesByKey[$0] }
                .filter { !$0.name.isEmpty }
                .prefix(2)
                .map(\.name)
        }
        identity.fighters = fighters.joined(separator: " vs ")
        identity.event = outcome?.event ?? ""
        if identity.fighters.isEmpty {
            // Filenames like "Blanchowics x ulberg ScreenRecording…" often
            // carry the pairing — offer the stem for the user to clean up.
            let stem = (video.filename as NSString).deletingPathExtension
            identity.fighters = stem
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: " x ", with: " vs ")
        }
        return identity
    }

    // MARK: - Run

    /// Full pass: model plans the queries → code crawls → model summarizes →
    /// result saved on the video. Throws with actionable messages.
    func run(video: VideoRecord, identity: Identity, profile: BrandProfile,
             database: Database, modelOverride: String? = nil,
             emit: @escaping @Sendable (String) -> Void) async throws -> FightResearchRecord {
        let fighters = identity.fighters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fighters.isEmpty else {
            throw AIError.notConfigured("No fighters to search for — fill in the fight identity first")
        }
        let sources = Self.enabledSources(profile: profile)
        guard sources.reddit || sources.news || sources.sherdog
                || !sources.subreddits.isEmpty || !sources.extraQueries.isEmpty else {
            throw AIError.notConfigured(
                "No research sources enabled — pick some in Settings → Profile → Fight Research Sources")
        }

        emit("Planning search queries for \(identity.label)…")
        let plan = await planQueries(identity: identity, profile: profile,
                                     modelOverride: modelOverride, emit: emit)

        emit("Crawling the web (plain HTTP — no login-walled sources)…")
        let corpus = await crawl(identity: identity, plan: plan, sources: sources, emit: emit)
        guard !corpus.isEmpty else {
            throw AIError.emptyResponse(
                "The crawl found nothing about \(fighters) — check the fighters' spelling, add an event name, or add sources in Settings → Profile")
        }
        let fetched = corpus.map(\.source)
        emit("Fetched \(corpus.count) source(s): \(Set(fetched).sorted().joined(separator: ", "))")

        emit("Summarizing fan reactions into a story…")
        let summary = try await summarize(identity: identity, corpus: corpus,
                                          profile: profile, modelOverride: modelOverride,
                                          emit: emit)
        let summaryJSON = summary.value
        let attribution = summary.provenance
        let sourcesJSON = String(data: (try? JSONSerialization.data(withJSONObject: fetched)) ?? Data("[]".utf8),
                                 encoding: .utf8) ?? "[]"
        try await database.upsertFightResearch(videoID: video.id,
                                               fightLabel: fighters,
                                               event: identity.event,
                                               fightDate: identity.date,
                                               summaryJSON: summaryJSON,
                                               sourcesJSON: sourcesJSON,
                                               provider: attribution.provider,
                                               model: attribution.model)
        emit("Fight research saved ✓")
        guard let record = try await database.fetchFightResearch()
            .first(where: { $0.videoID == video.id }) else {
            throw AIError.emptyResponse("The saved research could not be read back")
        }
        return record
    }

    // MARK: - Query planning (model-guided retrieval)

    private struct QueryPlan {
        var queries: [String]
        var subreddits: [String]
    }

    private func planQueries(identity: Identity, profile: BrandProfile,
                             modelOverride: String?,
                             emit: @escaping @Sendable (String) -> Void) async -> QueryPlan {
        let fallback = QueryPlan(
            queries: [identity.fighters,
                      [identity.fighters, identity.event].filter { !$0.isEmpty }.joined(separator: " "),
                      "\(identity.fighters) reaction"].filter { !$0.isEmpty },
            subreddits: ["MMA", "ufc"])
        let prompt = """
        A crawler is about to search the public web for FAN REACTIONS to this \(profile.effectiveDomain) fight:
        - Fighters: \(identity.fighters)
        \(identity.event.isEmpty ? "" : "- Event: \(identity.event)\n")\(identity.date.isEmpty ? "" : "- Date: \(identity.date)\n")
        Write the search plan. Return a JSON object with EXACTLY this structure:
        {
          "queries": ["<up to 4 short search queries fans' reaction threads would match. The detected fighter spellings may be WRONG (OCR'd from broadcast graphics) — correct them to the fighters' real, widely used names first (e.g. 'Blanchowics' → 'Blachowicz'), and include nicknames where fans use them>"],
          "subreddits": ["<up to 4 subreddit names (no r/ prefix) where this fight would be discussed>"]
        }
        Return ONLY the JSON object.
        """
        do {
            let response = try await ai.call(prompt: prompt, task: "fight_research",
                                             model: modelOverride, timeout: 120, log: emit)
            guard let object = AIResponseParser.jsonObject(from: response.text) else { return fallback }
            let queries = (object["queries"] as? [String] ?? []).prefix(4)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let subreddits = (object["subreddits"] as? [String] ?? []).prefix(4)
                .map { $0.replacingOccurrences(of: "r/", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !queries.isEmpty else { return fallback }
            return QueryPlan(queries: Array(queries),
                             subreddits: subreddits.isEmpty ? fallback.subreddits : Array(subreddits))
        } catch {
            emit("Query planning failed (\(error)) — using default queries")
            return fallback
        }
    }

    // MARK: - Crawling (standard code)

    private struct SourceConfig {
        var reddit: Bool
        var news: Bool
        var sherdog: Bool
        /// Extra subreddits from the profile's freeform sources ("r/ufc").
        var subreddits: [String]
        /// Extra domains/URLs to search via DuckDuckGo or fetch directly.
        var extraQueries: [String]
    }

    private nonisolated static func enabledSources(profile: BrandProfile) -> SourceConfig {
        var config = SourceConfig(reddit: profile.buzzSources.contains("reddit"),
                                  news: profile.buzzSources.contains("news"),
                                  sherdog: profile.buzzSources.contains("sherdog"),
                                  subreddits: [], extraQueries: [])
        for raw in profile.buzzExtraSources.split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if entry.lowercased().hasPrefix("r/") {
                config.subreddits.append(String(entry.dropFirst(2)))
            } else {
                config.extraQueries.append(entry)
            }
        }
        return config
    }

    private struct CorpusEntry {
        var source: String     // "r/MMA", "forums.sherdog.com", "mmamania.com"
        var text: String
    }

    /// Bounded crawl across the enabled sources. Every fetch failure logs
    /// and moves on — a partial corpus beats none.
    private func crawl(identity: Identity, plan: QueryPlan, sources: SourceConfig,
                       emit: @escaping @Sendable (String) -> Void) async -> [CorpusEntry] {
        var corpus: [CorpusEntry] = []
        var totalChars = 0
        let charBudget = 28_000

        func append(_ entry: CorpusEntry) {
            guard totalChars < charBudget else { return }
            let capped = String(entry.text.prefix(charBudget - totalChars))
            corpus.append(CorpusEntry(source: entry.source, text: capped))
            totalChars += capped.count
        }

        if sources.reddit || !sources.subreddits.isEmpty {
            let subreddits = (sources.reddit ? plan.subreddits : []) + sources.subreddits
            for entry in await crawlReddit(queries: plan.queries,
                                           subreddits: Array(Set(subreddits)).sorted(),
                                           emit: emit) {
                append(entry)
            }
        }
        if sources.news {
            for entry in await Self.crawlNews(queries: plan.queries, emit: emit) {
                append(entry)
            }
        }
        if sources.sherdog {
            for entry in await Self.crawlViaSearch(site: "forums.sherdog.com",
                                                   queries: plan.queries, emit: emit) {
                append(entry)
            }
        }
        for extra in sources.extraQueries {
            if extra.contains("://"), let url = URL(string: extra) {
                if let text = await Self.fetchPageText(url) {
                    append(CorpusEntry(source: url.host ?? extra, text: text))
                }
            } else {
                for entry in await Self.crawlViaSearch(site: extra, queries: plan.queries,
                                                       emit: emit) {
                    append(entry)
                }
            }
        }
        return corpus
    }

    // Reddit blocks its old public JSON API outright (403) but serves the
    // same search + comment data over RSS — strictly rate limited, so the
    // requests are paced and back off once on 429.
    private var lastRedditHit: Date?

    private func redditFetch(_ url: URL,
                             emit: @escaping @Sendable (String) -> Void) async -> String? {
        if let lastRedditHit {
            let wait = 6 - Date().timeIntervalSince(lastRedditHit)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        if Task.isCancelled { return nil }
        lastRedditHit = Date()
        var (status, body) = await Self.fetch(url)
        if status == 429 {
            emit("Reddit rate limit hit — waiting 30s and retrying once…")
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return nil }
            lastRedditHit = Date()
            (status, body) = await Self.fetch(url)
        }
        guard status == 200, let body else {
            emit("Reddit request failed (HTTP \(status)) — \(url.path)")
            return nil
        }
        return body
    }

    /// Reddit via RSS: search feeds surface the threads, each thread's .rss
    /// feed carries its top comments.
    private func crawlReddit(queries: [String], subreddits: [String],
                             emit: @escaping @Sendable (String) -> Void) async -> [CorpusEntry] {
        // Up to 3 search feeds: the two best subreddits with the primary
        // query, plus the secondary query on the first subreddit.
        var searches: [(subreddit: String, query: String)] = []
        for subreddit in subreddits.prefix(2) {
            if let query = queries.first { searches.append((subreddit, query)) }
        }
        if queries.count > 1, let subreddit = subreddits.first {
            searches.append((subreddit, queries[1]))
        }
        var threads: [(title: String, link: String)] = []
        var seen = Set<String>()
        for search in searches {
            guard let encoded = search.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.reddit.com/r/\(search.subreddit)/search.rss?q=\(encoded)&restrict_sr=on&sort=relevance&t=all")
            else { continue }
            guard let body = await redditFetch(url, emit: emit) else { continue }
            let found = Self.atomEntries(in: body)
            emit("r/\(search.subreddit) “\(search.query)”: \(found.count) thread(s)")
            for entry in found where seen.insert(entry.link).inserted {
                threads.append(entry)
            }
        }
        var entries: [CorpusEntry] = []
        for thread in threads.prefix(4) {
            guard let url = URL(string: "\(thread.link).rss?limit=40&sort=top") else { continue }
            guard let body = await redditFetch(url, emit: emit) else { continue }
            let contents = Self.atomContents(in: body)
            guard !contents.isEmpty else { continue }
            var text = "THREAD: \(thread.title)\n"
            // The first content block is the post body; the rest are comments.
            for comment in contents.dropFirst().prefix(30) {
                let line = comment.prefix(400)
                if !line.isEmpty { text += "- \(line)\n" }
            }
            let subreddit = thread.link.split(separator: "/").dropFirst(3).first.map(String.init) ?? "reddit"
            entries.append(CorpusEntry(source: "r/\(subreddit)", text: text))
        }
        emit(entries.isEmpty ? "Reddit: no matching threads found"
                             : "Reddit: \(entries.count) thread(s) with comments")
        return entries
    }

    /// <entry> title + comments-permalink pairs out of a Reddit Atom feed.
    private static func atomEntries(in atom: String) -> [(title: String, link: String)] {
        guard let entryRegex = try? NSRegularExpression(pattern: "<entry>(.*?)</entry>",
                                                        options: [.dotMatchesLineSeparators]),
              let titleRegex = try? NSRegularExpression(pattern: "<title>(.*?)</title>",
                                                        options: [.dotMatchesLineSeparators]),
              let linkRegex = try? NSRegularExpression(
                  pattern: "<link href=\"([^\"]*?/comments/[^\"]*?)\"") else { return [] }
        let range = NSRange(atom.startIndex..., in: atom)
        return entryRegex.matches(in: atom, range: range).compactMap { match in
            guard let entryRange = Range(match.range(at: 1), in: atom) else { return nil }
            let entry = String(atom[entryRange])
            let entryNSRange = NSRange(entry.startIndex..., in: entry)
            guard let linkMatch = linkRegex.firstMatch(in: entry, range: entryNSRange),
                  let linkRange = Range(linkMatch.range(at: 1), in: entry) else { return nil }
            var link = String(entry[linkRange]).replacingOccurrences(of: "&amp;", with: "&")
            while link.hasSuffix("/") { link.removeLast() }
            var title = ""
            if let titleMatch = titleRegex.firstMatch(in: entry, range: entryNSRange),
               let titleRange = Range(titleMatch.range(at: 1), in: entry) {
                title = decodeEntities(String(entry[titleRange]))
            }
            return (title, link)
        }
    }

    /// Plain text of every <content> block in a Reddit Atom feed (the HTML
    /// inside is entity-escaped, often twice).
    private static func atomContents(in atom: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<content[^>]*>(.*?)</content>",
                                                   options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(atom.startIndex..., in: atom)
        return regex.matches(in: atom, range: range).compactMap { match in
            guard let contentRange = Range(match.range(at: 1), in: atom) else { return nil }
            let unescaped = decodeEntities(decodeEntities(String(atom[contentRange])))
            let text = strippedHTML(unescaped)
            return text.isEmpty ? nil : text
        }
    }

    /// News coverage via Google News RSS — reliably reachable without auth;
    /// headlines and descriptions summarize how media framed the fight.
    private static func crawlNews(queries: [String],
                                  emit: @escaping @Sendable (String) -> Void) async -> [CorpusEntry] {
        guard let query = queries.first,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=en-US&gl=US&ceid=US:en")
        else { return [] }
        let (status, body) = await fetch(url)
        guard status == 200, let body else {
            emit("News search failed (HTTP \(status))")
            return []
        }
        guard let itemRegex = try? NSRegularExpression(pattern: "<item>(.*?)</item>",
                                                       options: [.dotMatchesLineSeparators]),
              let titleRegex = try? NSRegularExpression(pattern: "<title>(.*?)</title>",
                                                        options: [.dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        let titles = itemRegex.matches(in: body, range: range).compactMap { match -> String? in
            guard let itemRange = Range(match.range(at: 1), in: body) else { return nil }
            let item = String(body[itemRange])
            let itemNSRange = NSRange(item.startIndex..., in: item)
            guard let titleMatch = titleRegex.firstMatch(in: item, range: itemNSRange),
                  let titleRange = Range(titleMatch.range(at: 1), in: item) else { return nil }
            return decodeEntities(String(item[titleRange])
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: ""))
        }
        guard !titles.isEmpty else {
            emit("News: no coverage found for “\(query)”")
            return []
        }
        emit("News: \(titles.count) headline(s)")
        let text = "NEWS HEADLINES about the fight:\n"
            + titles.prefix(15).map { "- \($0)" }.joined(separator: "\n")
        return [CorpusEntry(source: "news", text: text)]
    }

    /// Site-scoped DuckDuckGo HTML search (no API key) → fetch and strip the
    /// top result pages. Used for Sherdog forums and freeform extra domains.
    private static func crawlViaSearch(site: String, queries: [String],
                                       emit: @escaping @Sendable (String) -> Void) async -> [CorpusEntry] {
        var links: [URL] = []
        var seen = Set<String>()
        var challenged = false
        for query in queries.prefix(2) {
            let q = "site:\(site) \(query)"
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { continue }
            let (status, html) = await fetch(url)
            guard status == 200, let html else {
                // DDG answers bot-suspect networks with a 202 challenge page.
                challenged = challenged || status == 202 || status == 403
                continue
            }
            let found = searchResultLinks(in: html)
            challenged = challenged || found.isEmpty && html.count < 20_000
            for link in found.prefix(3) where seen.insert(link.absoluteString).inserted {
                links.append(link)
            }
        }
        var entries: [CorpusEntry] = []
        for link in links.prefix(3) {
            if let text = await fetchPageText(link) {
                entries.append(CorpusEntry(source: site, text: text))
            }
        }
        if entries.isEmpty {
            emit(challenged
                 ? "\(site): the search engine is bot-walling this network — skipped (Reddit and News still crawl)"
                 : "\(site): nothing found")
        } else {
            emit("\(site): \(entries.count) page(s)")
        }
        return entries
    }

    /// Result hrefs out of DuckDuckGo's HTML page, unwrapping its
    /// /l/?uddg= redirect links.
    private static func searchResultLinks(in html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"class="result__a"[^>]*href="([^"]+)""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html) else { return nil }
            var href = String(html[hrefRange])
                .replacingOccurrences(of: "&amp;", with: "&")
            if href.hasPrefix("//") { href = "https:" + href }
            // Redirect wrapper: //duckduckgo.com/l/?uddg=<encoded-target>
            if href.contains("uddg="),
               let components = URLComponents(string: href),
               let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                return URL(string: target)
            }
            return URL(string: href)
        }
    }

    private static func fetchPageText(_ url: URL) async -> String? {
        let (status, html) = await fetch(url)
        guard status == 200, let html else { return nil }
        let text = strippedHTML(html)
        return text.count > 200 ? String(text.prefix(6000)) : nil
    }

    /// One plain GET with a browser-like UA (several sources bot-wall
    /// obviously non-browser agents). 0 = transport failure.
    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Browser-like request headers — sites (Reddit especially) reject bare
    /// clients even with a browser UA; the full set makes the request look
    /// like a real navigation.
    private static let browserHeaders: [(String, String)] = [
        ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"),
        ("Accept-Language", "en-US,en;q=0.9"),
        ("Sec-Fetch-Dest", "document"),
        ("Sec-Fetch-Mode", "navigate"),
        ("Sec-Fetch-Site", "none"),
        ("Sec-Fetch-User", "?1"),
        ("Upgrade-Insecure-Requests", "1"),
    ]

    /// One plain GET. Routed through the system `curl` binary rather than
    /// URLSession: Apple's TLS/HTTP2 handshake is fingerprinted and blocked
    /// by Reddit and the search engines, while curl's handshake is accepted.
    /// Falls back to URLSession when curl can't be located. 0 = failure.
    private static func fetch(_ url: URL) async -> (status: Int, body: String?) {
        if let curl = ProcessRunner.locate("curl") {
            // -w appends the numeric status after the body, split on a marker
            // that won't appear in HTML/RSS payloads.
            let marker = "\n@@CB_HTTP_STATUS@@"
            var arguments = ["--silent", "--location", "--compressed",
                             "--max-time", "25", "--max-redirs", "5",
                             "--user-agent", browserUA]
            for (name, value) in browserHeaders { arguments += ["-H", "\(name): \(value)"] }
            arguments += ["--write-out", marker + "%{http_code}", url.absoluteString]
            if let result = try? await ProcessRunner.run(executable: curl, arguments: arguments,
                                                         timeout: 30) {
                let output = result.stdoutText
                if let range = output.range(of: marker, options: .backwards) {
                    let status = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    let body = String(output[..<range.lowerBound])
                    return (status, body.isEmpty ? nil : body)
                }
                // No status marker: curl failed before the response (exit != 0).
                return (0, nil)
            }
            return (0, nil)
        }
        // Fallback: URLSession (may be fingerprint-blocked).
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        for (name, value) in browserHeaders { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (0, nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return (status, String(data: data, encoding: .utf8))
    }

    /// The common HTML entities, applied twice by callers when the payload
    /// is escaped HTML inside XML.
    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
                                    ("&#32;", " "), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// Crude but dependency-free HTML → text: drop scripts/styles/tags,
    /// decode the common entities, collapse whitespace.
    private static func strippedHTML(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "nav", "header", "footer"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&#x27;": "'", "&nbsp;": " "]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Summarization

    private func summarize(identity: Identity, corpus: [CorpusEntry], profile: BrandProfile,
                           modelOverride: String?,
                           emit: @escaping @Sendable (String) -> Void) async throws -> AIOutcome<String> {
        let excerpts = corpus.map { "=== SOURCE: \($0.source) ===\n\($0.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        You are a combat-sports researcher for the \(profile.effectiveDomain) channel \(profile.brandName). Below are fan reactions CRAWLED FROM THE WEB about this fight:
        - Fighters: \(identity.fighters)
        \(identity.event.isEmpty ? "" : "- Event: \(identity.event)\n")\(identity.date.isEmpty ? "" : "- Date: \(identity.date)\n")
        Distill them into a compelling STORY for a highlight reel — the narrative fans are already telling, so the edit joins the conversation.

        RULES:
        - Base EVERYTHING on the crawled excerpts below. Do not add facts or reactions from your own knowledge. If the excerpts cover a different fight than the one named, say so in "sentiment" and summarize what IS there.
        - Paraphrase fan reactions — never reproduce comments verbatim, never include usernames.
        - Keep every string concise.

        Return a JSON object with EXACTLY this structure:
        {
          "fight": "<who vs who, event if known>",
          "sentiment": "<overall fan mood in 1-2 sentences>",
          "talking_points": [
            {"moment": "<the moment fans discuss>", "why_fans_care": "<one sentence>", "sample_reactions": ["<short paraphrased fan take>", ...]}
          ],
          "controversy": "<scoring debate / robbery claim / drama, or null>",
          "story": {
            "angle": "<the single most compelling narrative for the reel>",
            "arc": "<how the reel should unfold: setup → escalation → payoff, phrased around the fan narrative>",
            "hook_line": "<2-6 word ALL-CAPS hook echoing the buzz>",
            "overlay_lines": ["<2-6 word ALL-CAPS overlay candidates riffing on fan sentiment>", ...]
          }
        }
        Return ONLY the JSON object, no markdown fences.

        ## CRAWLED EXCERPTS
        \(excerpts)
        """
        let response = try await ai.call(prompt: prompt, task: "fight_research",
                                         model: modelOverride, timeout: 300, log: emit)
        guard let data = AIResponseParser.jsonData(from: response.text),
              let json = String(data: data, encoding: .utf8),
              AIResponseParser.jsonObject(from: json) != nil else {
            throw AIError.unusableResponse("The summarizer did not return usable story JSON")
        }
        return AIOutcome(value: json, provenance: response.provenance)
    }
}
