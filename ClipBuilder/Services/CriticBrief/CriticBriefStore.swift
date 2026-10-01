import CryptoKit
import Foundation

nonisolated struct CriticBriefStore: Sendable {
    let directory: URL

    init(profile: BrandProfile, root: URL = SettingsStore.cacheDirectory) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = profile.profileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "profile"
        directory = root.appendingPathComponent("critic-brief", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func key(pool: [CriticExemplars.Candidate], profile: BrandProfile) throws -> String {
        var parts = [String(CriticBrief.version), String(ReelTraits.version),
                     hash(profile.tasteRubric), hash(profile.houseStyle)]
        for row in pool.sorted(by: { $0.id < $1.id }) {
            let attributes = try FileManager.default.attributesOfItem(atPath: row.path)
            parts += [row.id, String((attributes[.size] as? NSNumber)?.int64Value ?? 0),
                      String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
                      // Evidence can change while membership stays the same (a favorite toggle).
                      String(row.favorite), String(row.percentile ?? -1), String(row.reference)]
        }
        return hash(String(decoding: try JSONEncoder().encode(parts), as: UTF8.self))
    }

    func load() -> CriticBrief? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("brief.json")),
              let brief = try? JSONDecoder().decode(CriticBrief.self, from: data),
              brief.exemplars.count >= 2 else { return nil }
        return brief
    }

    func save(_ brief: CriticBrief) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(brief).write(to: directory.appendingPathComponent("brief.json"), options: .atomic)
    }

    func frames(for brief: CriticBrief) throws -> [AIFrame] {
        try brief.exemplars.map { exemplar in
            AIFrame(jpeg: try Data(contentsOf: directory.appendingPathComponent(exemplar.sheetPath)),
                    label: "\(exemplar.label) (\(exemplar.why)) — 4 frames: 0.3s, 1.8s, mid, end")
        }
    }

    func state(pool: [CriticExemplars.Candidate], profile: BrandProfile) -> String {
        guard let brief = load() else { return "No brief: star 2 generated reels first" }
        guard let current = try? Self.key(pool: pool, profile: profile), current == brief.key,
              (try? frames(for: brief)) != nil else { return "Stale: favorites changed" }
        let date = brief.builtAt.formatted(.dateTime.month(.abbreviated).day())
        return "Built \(date) from \(brief.exemplars.count) reels"
    }

    /// Build immutable sheet generations, then atomically publish brief.json.
    /// An interrupted refresh cannot replace sheets belonging to the previous judge.
    @concurrent
    func build(pool: [CriticExemplars.Candidate], profile: BrandProfile, ai: AIService,
               emit: @escaping @Sendable (String) -> Void) async throws -> CriticBrief? {
        guard pool.count >= 2 else { return nil }
        let pool = Array(pool.prefix(6))
        let key = try Self.key(pool: pool, profile: profile)
        let generation = UUID().uuidString
        let sheets = directory.appendingPathComponent(generation, isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: sheets) } }
        var exemplars: [CriticBrief.Exemplar] = []
        var frames: [AIFrame] = []
        for (index, row) in pool.enumerated() {
            try Task.checkCancellation()
            let duration = row.duration > 0 ? row.duration : await FFmpeg.duration(of: URL(fileURLWithPath: row.path))
            let jpeg = try await ContactSheet.build(url: URL(fileURLWithPath: row.path), duration: duration)
            let path = "\(generation)/sheet-\(index).jpg"
            try jpeg.write(to: directory.appendingPathComponent(path), options: .atomic)
            let label = "REFERENCE \(["A", "B", "C", "D", "E", "F"][index])"
            exemplars.append(.init(id: row.id, label: label, why: row.why, duration: duration,
                                   traits: row.traits, sheetPath: path))
            frames.append(AIFrame(jpeg: jpeg, label: "\(label) (\(row.why)) — 0.3s, 1.8s, mid, end"))
            emit("Critic brief: \(index + 1)/\(pool.count) exemplars sheeted")
            emit("PROGRESS:\(Double(index + 1) / Double(pool.count))")
        }
        emit("Distilling…")
        let response = try await ai.call(prompt: Self.distillPrompt(exemplars: exemplars, profile: profile),
                                         task: .distill, frames: frames, timeout: 180, log: emit)
        try Task.checkCancellation()
        let rules = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rules.isEmpty else { throw AIError.unusableResponse("The critic brief was empty.") }
        let brief = CriticBrief(key: key, builtAt: .now, rules: rules, exemplars: exemplars,
                                provider: response.provider, model: response.model)
        try save(brief)
        published = true
        return brief
    }

    static func distillPrompt(exemplars: [CriticBrief.Exemplar], profile: BrandProfile) -> String {
        let rows = exemplars.map { exemplar in
            let traits = exemplar.traits.map { traits in
                let features = traits.features
                return features.keys.sorted().map { "\($0)=\(features[$0] ?? 0)" }.joined(separator: ", ")
            } ?? "traits unavailable"
            return "\(exemplar.summary) | \(traits)"
        }.joined(separator: "\n")
        return """
        Distill what this owner's good reels do from these labeled contact sheets and traits.
        These rules will grade OTHER reels. Every bullet must be checkable from sampled frames;
        do not invent audio evidence. Compare standards, do not prescribe copying content.
        Return plain text with these exact headers, each with 2–4 concrete checkable bullets:
        HOOK:
        DURATION & PACING:
        STRUCTURE:
        TEXT & OVERLAYS:
        MUSIC & AUDIO:
        Then add DO NOT REWARD: for traits this reference set shows the owner does not value.
        Describe what the owner's good reels do, not generic short-form advice.

        Exemplar | evidence | traits
        \(rows)

        Owner's taste:
        \(profile.tasteRubric)
        House style:
        \(profile.houseStyle)
        """
    }
}

extension CriticBriefStore {
    func decision() -> CriticAgreement.Decision? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("agreement.json")) else { return nil }
        return try? JSONDecoder().decode(CriticAgreement.Decision.self, from: data)
    }

    func enabledByDefault(_ brief: CriticBrief) -> Bool {
        guard let decision = decision() else { return false }
        return decision.briefKey == brief.key && decision.briefBuiltAt == brief.builtAt && decision.passed
    }

    func saveDecision(_ decision: CriticAgreement.Decision) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(decision).write(to: directory.appendingPathComponent("agreement.json"), options: .atomic)
    }
}
