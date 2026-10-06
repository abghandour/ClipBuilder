import Foundation

/// Explicit JSON projection. Machine paths, local publishing choices, Drive
/// preferences and exemplar files never enter the shared profile document.
nonisolated enum TeamProfileDocument {
    static let keys: Set<String> = [
        "brand_name", "content_domain", "tag_schema", "socials", "hashtags", "captions",
        "caption_styles", "tag_style", "tag_styles", "accent_color", "tagline", "caption_languages",
        "default_pacing", "default_music_volume", "use_learned_editing_defaults", "learned_hook_style",
        "learned_layout_preference", "taste_rubric", "taste_categories", "house_style", "critic_brief_use"
    ]

    static func encode(_ profile: BrandProfile) throws -> String {
        let full = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(profile))
        var shared = full.filter { keys.contains($0.key) }
        if case .array(let categories) = shared["taste_categories"] {
            shared["taste_categories"] = .array(categories.map { category in
                guard case .object(var fields) = category else { return category }
                fields["exemplar_frames"] = .array([])
                return .object(fields)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(SyncMapping.portableJSON(.object(shared))), as: UTF8.self)
    }

    static func applying(_ json: String, to profile: BrandProfile) throws -> BrandProfile {
        let shared = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(json.utf8))
        var full = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(profile))
        for key in keys {
            full[key] = shared[key].map { SyncMapping.applyingPortableJSON($0, to: full[key]) }
        }
        var result = try JSONDecoder().decode(BrandProfile.self, from: JSONEncoder().encode(full))
        for index in result.tasteCategories.indices {
            result.tasteCategories[index].exemplarFrames = profile.tasteCategories.first {
                $0.key == result.tasteCategories[index].key
            }?.exemplarFrames ?? []
        }
        return result
    }

    /// Apply remote fields and replay only edits made since the cycle began.
    /// Recurse into objects so edits to separate pacing/style fields coexist.
    static func merging(_ json: String?, into profile: BrandProfile, baseline: String) throws -> BrandProfile {
        // A remote tombstone removes the document, not this Mac's profile.
        // Adopt the local copy so completion can clear the gate and re-seed it.
        guard let json else { return profile }
        let decoder = JSONDecoder()
        let remote = try decoder.decode(SyncJSON.self, from: Data(json.utf8))
        let base = try decoder.decode(SyncJSON.self, from: Data(baseline.utf8))
        let current = try decoder.decode(SyncJSON.self, from: Data(encode(profile).utf8))
        let merged = merge(remote: remote, current: current, baseline: base) ?? .object([:])
        return try applying(String(decoding: JSONEncoder().encode(merged), as: UTF8.self), to: profile)
    }

    private static func merge(remote: SyncJSON?, current: SyncJSON?, baseline: SyncJSON?) -> SyncJSON? {
        guard current != baseline else { return remote }
        if case .object(let current) = current, case .object(let baseline) = baseline {
            var result: [String: SyncJSON] = [:]
            if case .object(let fields) = remote { result = fields }
            for key in Set(current.keys).union(baseline.keys) where current[key] != baseline[key] {
                result[key] = merge(remote: result[key], current: current[key], baseline: baseline[key])
            }
            return .object(result)
        }
        return current
    }
}

extension Database {
    /// This durable gate remains closed across Stop, errors and relaunch. The
    /// store saves the merged document before acknowledging adoption below.
    func beginSyncProfileAdoption(fallback: String? = nil) throws {
        guard let baseline = try syncedProfileDocument() ?? fallback else { return }
        try connection.execute("INSERT OR IGNORE INTO sync_profile_adoption(id, baseline_json) VALUES (1, ?)", [.text(baseline)])
    }

    func syncProfileAdoption() throws -> (document: String?, baseline: String)? {
        guard let baseline = try connection.query("SELECT baseline_json FROM sync_profile_adoption WHERE id = 1").first?["baseline_json"]?.stringValue else { return nil }
        return (try syncedProfileDocument(), baseline)
    }

    /// Call only after the store's profile file was saved successfully.
    func completeSyncProfileAdoption(_ savedProfile: BrandProfile) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM sync_profile_adoption")
            try completeInitialSync()
            try saveSyncProfile(savedProfile)
        }
    }

    func saveSyncProfile(_ profile: BrandProfile) throws {
        guard let id = profile.profileID, let team = profile.teamID else { return }
        guard try syncScope() == SyncScope(teamID: team, profileID: id) else { throw SyncError.scopeMismatch }
        if try !connection.query("SELECT 1 FROM sync_profile_adoption").isEmpty { return }
        // An interrupted join may already have downloaded the shared document.
        // Do not replace it with the still-unadopted local UI snapshot on retry.
        if try initialSyncPending(),
           try !connection.query("SELECT 1 FROM sync_wire_rows WHERE \"table\" = 'profile_documents'").isEmpty {
            // A v26 interrupted join has no durable adoption baseline yet.
            // Its current local profile is the baseline, not the remote copy.
            try connection.execute("INSERT OR IGNORE INTO sync_profile_adoption(id, baseline_json) VALUES (1, ?)",
                                   [.text(TeamProfileDocument.encode(profile))])
            return
        }
        let current = try TeamProfileDocument.encode(profile)
        // Preserve fields added by a newer app inside the document as well as
        // at the top level of the wire row.
        var fields = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(current.utf8))
        if let previous = try syncedProfileDocument() {
            let saved = try JSONDecoder().decode(SyncMapping.WireRow.self, from: Data(previous.utf8))
            for (key, value) in saved where !TeamProfileDocument.keys.contains(key) { fields[key] = value }
        }
        let json = try SyncMapping.portableJSONString(.object(fields))
        try connection.execute("""
            INSERT INTO profile_documents(sync_id, document_json) VALUES (?, ?)
            ON CONFLICT(sync_id) DO UPDATE SET document_json = excluded.document_json
            WHERE document_json <> excluded.document_json
            """, [.text(id.uuidString.lowercased()), .text(json)])
    }

    func syncedProfileDocument() throws -> String? {
        try connection.query("SELECT document_json FROM profile_documents LIMIT 1").first?["document_json"]?.stringValue
    }
}
