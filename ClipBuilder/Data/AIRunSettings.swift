import Foundation

/// Informational context only; user-authored instructions remain in their own fields.
nonisolated struct AIPromptPreview: Codable, Sendable, Equatable {
    let role: String
    let preview: String
    let characterCount: Int
    var truncated: Bool { characterCount > preview.count }

    init(role: String, prompt: String) {
        self.role = role
        preview = String(prompt.prefix(2_000))
        characterCount = prompt.count
    }

    enum CodingKeys: String, CodingKey { case role, preview, characterCount }
    init(from decoder: Decoder) throws {
        // Read snapshots produced by the first version without retaining full prompts.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            role = "AI"
            preview = String(legacy.prefix(2_000))
            characterCount = legacy.count
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            role = try values.decode(String.self, forKey: .role)
            let text = try values.decode(String.self, forKey: .preview)
            preview = String(text.prefix(2_000))
            characterCount = max(text.count, try values.decode(Int.self, forKey: .characterCount))
        }
    }
}

nonisolated struct AnalysisRunSettings: Codable, Sendable, Equatable {
    var instructions = ""
    var sampleInterval = 0.0
    var includeTranscript = false
    var language = ""
    var detectPeople = true
    var autoZoomUnframed = false
    var breakdownTags: [String] = []
    var trimRange: [Double]?
    var notes: [AnalysisRunNote] = []
    var provider: String?
    var model: String?
    var videoPath: String?
    var sourcePeople: [String] = []
    var sourceProfile = ""
    var modelPrompts: [String: AIPromptPreview] = [:]
}

nonisolated struct WizardRunSettings: Codable, Sendable {
    var options: WizardOptions
    var stackLevel = "standard"
    var sourceProfile = ""
    var sourceVideoPaths: [String] = []
    var sourceSceneIDs: [Int64] = []
    var modelPrompts: [String: AIPromptPreview] = [:]
    var builderDocumentJSON: String?
}

nonisolated struct AIRole: Codable, Sendable, Hashable {
    var role: String
    var provenance: AIProvenance
}

nonisolated enum AISettingsJSON {
    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

nonisolated enum AISettingsScope: String, Codable, CaseIterable, Sendable {
    case models, prompts, options, sources
    var label: String {
        switch self {
        case .models: "Models"
        case .prompts: "Prompts & instructions"
        case .options: "Options"
        case .sources: "Sources"
        }
    }
}

/// Only selected keys cross the pasteboard boundary; no credentials or account data.
nonisolated struct AISettingsEnvelope: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case analysis, wizard }
    var version = 1
    var kind: Kind
    var sourceName: String
    var copiedAt = Date()
    var scopes: Set<AISettingsScope>
    var settings: [String: JSONSetting]

    static func keys(_ scope: AISettingsScope, kind: Kind) -> Set<String> {
        if kind == .analysis {
            switch scope {
            case .models: return ["provider", "model"]
            case .prompts: return ["instructions", "notes"]
            case .sources: return ["videoPath", "sourcePeople", "sourceProfile"]
            case .options:
                return [
                    "sampleInterval", "includeTranscript", "language", "detectPeople",
                    "autoZoomUnframed",
                    "breakdownTags", "trimRange", "videoPath",
                ]
            }
        }
        switch scope {
        case .models: return ["modelOverride"]
        case .prompts:
            return [
                "aiInstructions", "tastePreset", "templateJSON", "templateLabel",
                "pinnedOverlayTemplate", "pinnedOverlayText",
            ]
        case .sources:
            return [
                "sourceSceneSelection", "sourcesRestricted", "selectedRunIDs", "sourcePeople",
                "curatedOnly", "stackLevel", "sourceProfile", "sourceVideoPaths", "sourceSceneIDs",
            ]
        case .options:
            return [
                "renderSettings", "pacing", "captionLanguage", "reviewProposedCuts", "muteSource",
                "addCaptions", "enableTextOverlays", "useMusic", "useFightResearch",
                "targetDurationSeconds", "framingCamera", "podcastFraming", "screenCropLayouts",
                "allowedTransitions", "formatPreset", "critiqueLoop", "includeWatermark",
                "includeHeadline",
                "includeOutro",
            ]
        }
    }

    init(
        kind: Kind, sourceName: String, scopes: Set<AISettingsScope>,
        settings: [String: JSONSetting]
    ) {
        self.kind = kind
        self.sourceName = sourceName
        self.scopes = scopes
        let allowed = scopes.reduce(into: Set<String>()) { $0.formUnion(Self.keys($1, kind: kind)) }
        self.settings = settings.filter { allowed.contains($0.key) }
        // Include explicit nulls so a copied "automatic" choice clears an override.
        for key in allowed where self.settings[key] == nil { self.settings[key] = .null }
    }

    func applying(
        to current: [String: JSONSetting], profile: String, videoPaths: Set<String>,
        runIDs: Set<Int64>, people: Set<String>, sceneIDs: Set<Int64>, sameVideo: String? = nil
    )
        -> (settings: [String: JSONSetting], skipped: [String])
    {
        var result = current
        var skipped: [String] = []
        let allowed = scopes.reduce(into: Set<String>()) { $0.formUnion(Self.keys($1, kind: kind)) }
        for (key, value) in settings where allowed.contains(key) { result[key] = value }
        if kind == .analysis, scopes.contains(.options), settings["videoPath"]?.string != sameVideo
        {
            result["trimRange"] = current["trimRange"]
            if settings["trimRange"] != .null { skipped.append("Trim range (different video)") }
        }
        if scopes.contains(.sources) {
            if kind == .wizard {
                let selected = ["selectedRunIDs", "sourceSceneIDs", "sourceVideoPaths"].contains {
                    key in
                    if case .array(let values) = settings[key] { return !values.isEmpty }
                    return false
                }
                result["sourcesRestricted"] = .bool(selected)
            }
            let sameProfile = settings["sourceProfile"]?.string == profile
            if kind == .wizard, case .array(let scenes) = settings["sourceSceneIDs"] {
                result["sourceSceneSelection"] = .bool(sameProfile && !scenes.isEmpty)
            }
            for (key, valid) in [
                ("selectedRunIDs", Set(runIDs.map(String.init))),
                ("sourceSceneIDs", Set(sceneIDs.map(String.init))),
                ("sourcePeople", people), ("sourceVideoPaths", videoPaths),
            ] {
                guard case .array(let values) = settings[key] else { continue }
                result[key] = .array(
                    values.filter { value in
                        let identity = value.string ?? value.number.map { String(Int64($0)) } ?? ""
                        let exists =
                            (sameProfile || key == "sourceVideoPaths") && valid.contains(identity)
                        if !exists { skipped.append("\(key): \(identity)") }
                        return exists
                    })
            }
        }
        if kind == .analysis { result["videoPath"] = current["videoPath"] }
        result["sourceProfile"] = current["sourceProfile"]
        return (result, skipped)
    }
}

nonisolated enum JSONSetting: Codable, Sendable, Equatable {
    case null
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONSetting])
    case object([String: JSONSetting])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONSetting].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONSetting].self))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    static func dictionary<T: Encodable>(_ value: T) -> [String: JSONSetting] {
        AISettingsJSON.decode([String: JSONSetting].self, AISettingsJSON.encode(value)) ?? [:]
    }
}

extension WizardRunSettings {
    var flattened: [String: JSONSetting] {
        var result = JSONSetting.dictionary(options)
        if let builderDocumentJSON { result["builderDocumentJSON"] = .string(builderDocumentJSON) }
        result["modelPrompts"] = .object(
            modelPrompts.mapValues { .object(JSONSetting.dictionary($0)) })
        result["stackLevel"] = .string(stackLevel)
        result["sourceProfile"] = .string(sourceProfile)
        result["sourceVideoPaths"] = .array(sourceVideoPaths.map(JSONSetting.string))
        result["sourceSceneIDs"] = .array(sourceSceneIDs.map { .number(Double($0)) })
        return result
    }
}

extension VideoRecord {
    nonisolated var transcriptionProvenance: AIProvenance? {
        AIProvenance(
            provider: speechAnalyzerProvider, model: speechAnalyzerModel, task: "transcription",
            sqliteDate: speechAnalyzedAt)
    }
}

nonisolated extension WizardOptions {
    func includesCopiedSource(_ scene: SceneRecord) -> Bool {
        if sourceSceneSelection { return sourceSceneIDs.contains(scene.id) }
        if !sourceVideoPaths.isEmpty { return sourceVideoPaths.contains(scene.videoPath) }
        return scene.runID.map(selectedRunIDs.contains) == true
    }
}
