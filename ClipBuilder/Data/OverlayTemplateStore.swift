import Foundation

/// An overlay design: any number of text and image items, each with its own
/// look, position, and timing window relative to the composition's start.
nonisolated struct OverlayComposition: Codable, Sendable, Equatable {
    var texts: [TextOverlayItem] = []
    var images: [ImageOverlayItem] = []
    /// Set when the Overlay Wizard extracted this design from a reference
    /// frame — the model that did it; nil for hand-built templates.
    var provenance: AIProvenance? = nil

    var isEmpty: Bool { texts.isEmpty && images.isEmpty }

    /// Play length: the latest bounded item end. Unbounded items adopt this
    /// (or the clip window, when the Wizard applies the template) — with a
    /// 3s floor so an all-unbounded composition still has a length.
    var duration: Double {
        let bounded = (texts.filter { !$0.unbounded } .map(\.endTime)
            + images.filter { !$0.unbounded }.map(\.endTime)).max() ?? 0
        let hasUnbounded = texts.contains(where: \.unbounded) || images.contains(where: \.unbounded)
        return hasUnbounded ? max(bounded, 3) : bounded
    }

    init(texts: [TextOverlayItem] = [], images: [ImageOverlayItem] = []) {
        self.texts = texts
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        texts = try container.decodeIfPresent([TextOverlayItem].self, forKey: .texts) ?? []
        images = try container.decodeIfPresent([ImageOverlayItem].self, forKey: .images) ?? []
        provenance = try container.decodeIfPresent(AIProvenance.self, forKey: .provenance)
    }

    enum CodingKeys: String, CodingKey { case texts, images, provenance }
}

/// One saved overlay design. Identity is the file name (like brand
/// profiles): `~/Documents/ClipBuilder/assets/overlays/<name>.json` holds an
/// OverlayComposition, so templates are Finder-visible and shared across
/// profiles like the other asset libraries.
nonisolated struct OverlayTemplate: Identifiable, Equatable, Sendable {
    var name: String
    var composition: OverlayComposition

    var id: String { name }
}

/// Loads, saves, and enumerates overlay templates. The Builder inserts them
/// at the playhead; the AI Wizard offers them to the model alongside the
/// built-in WizardTextStyle palette.
nonisolated enum OverlayTemplateStore {
    static var directory: URL {
        ProfileStore.profilesDirectory.appendingPathComponent("assets/overlays", isDirectory: true)
    }

    static func templateURL(name: String) -> URL {
        directory.appendingPathComponent(ProfileStore.sanitize(name) + ".json")
    }

    static func list() -> [OverlayTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let composition = loadComposition(at: url) else { return nil }
                return OverlayTemplate(name: url.deletingPathExtension().lastPathComponent,
                                       composition: composition)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Current format is {"texts": [...], "images": [...]}; files from before
    /// compositions hold a single bare TextOverlayItem and migrate on read.
    private static func loadComposition(at url: URL) -> OverlayComposition? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["texts"] != nil || object["images"] != nil {
            return try? JSONDecoder().decode(OverlayComposition.self, from: data)
        }
        guard var item = try? JSONDecoder().decode(TextOverlayItem.self, from: data) else { return nil }
        // A legacy template's one text was the AI-replaceable headline.
        item.isDynamic = true
        return OverlayComposition(texts: [item])
    }

    /// Case-insensitive lookup used when resolving a wizard plan's style name.
    static func composition(named name: String?) -> OverlayComposition? {
        guard let name, !name.isEmpty else { return nil }
        return list().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.composition
    }

    static func save(_ template: OverlayTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template.composition).write(to: templateURL(name: template.name), options: .atomic)
    }

    /// Returns the final (sanitized) name.
    static func rename(_ name: String, to newName: String) throws -> String {
        let sanitized = ProfileStore.sanitize(newName)
        let current = ProfileStore.sanitize(name)
        guard sanitized != current else { return name }
        let source = templateURL(name: name)
        let destination = templateURL(name: sanitized)
        if sanitized.caseInsensitiveCompare(current) == .orderedSame {
            // Case-only rename: a direct move fails on case-insensitive
            // volumes because the destination "already exists".
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).tmp")
            try FileManager.default.moveItem(at: source, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return sanitized
    }

    static func delete(name: String) throws {
        try FileManager.default.trashItem(at: templateURL(name: name), resultingItemURL: nil)
    }

    /// "Name", "Name 2", "Name 3", … whichever is free.
    static func uniqueName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "Template" : trimmed
        guard FileManager.default.fileExists(atPath: templateURL(name: candidate).path) else {
            return candidate
        }
        var counter = 2
        while FileManager.default.fileExists(atPath: templateURL(name: "\(candidate) \(counter)").path) {
            counter += 1
        }
        return "\(candidate) \(counter)"
    }
}
