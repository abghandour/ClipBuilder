import CoreFoundation
import Foundation

@MainActor enum AISettingsPreferences {
    static let snapshotKey = "wizard.aiRunOptions"
    static let sourceNameKey = "wizard.aiRunSourceName"

    static func clearWizardPaste(defaults: UserDefaults) {
        for key in [
            snapshotKey, sourceNameKey, "wizard.modelOverride", "wizard.selectedRunIDs",
            "wizard.limitToSelection", "wizard.sourcePeople", "wizard.curatedOnly",
            "wizard.sourcesRestricted", "wizard.sourceSceneSelection", "wizard.sourceSceneIDs",
            "wizard.sourceVideoPaths", SceneStacks.levelKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
    static let wizardKeys: [String: String] = [
        "aiInstructions": "wizard.aiInstructions", "formatPreset": "wizard.formatPreset",
        "tastePreset": "wizard.tastePreset",
        "captionLanguage": "wizard.captionLanguage",
        "reviewProposedCuts": "wizard.reviewProposedCuts",
        "podcastFraming": "wizard.podcastFraming", "critiqueLoop": "wizard.critiqueLoop",
        "curatedOnly": "wizard.curatedOnly",
        "modelOverride": "wizard.modelOverride", "stackLevel": SceneStacks.levelKey,
    ]
    static let analysisKeys: [String: String] = [
        "instructions": "analysis.instructions", "sampleInterval": "analysis.sampleInterval",
        "includeTranscript": "analysis.includeTranscript",
        "autoZoomUnframed": "analysis.autoZoomUnframed", "detectPeople": "analysis.detectPeople",
        "language": "analysis.language",
        "provider": "analysis.provider", "model": "analysis.model",
    ]
    static func wizard(defaults: UserDefaults, profile: BrandProfile) -> [String: JSONSetting] {
        var options = WizardOptions()
        options.renderSettings = profile.defaultRenderSettings
        options.pacing = profile.defaultPacing
        var result = JSONSetting.dictionary(options)
        if let saved = AISettingsJSON.decode(
            [String: JSONSetting].self, defaults.string(forKey: snapshotKey))
        {
            result.merge(saved) { _, new in new }
        }
        for (field, key) in wizardKeys {
            if let value = defaults.object(forKey: key) { result[field] = setting(value) }
        }
        if result["allowedTransitions"] == nil {
            result["allowedTransitions"] =
                WizardDefaults.allowedTransitions(defaults: defaults).map {
                    .array($0.map(JSONSetting.string))
                } ?? .null
        }
        let layout =
            WizardLayoutMode(rawValue: defaults.string(forKey: WizardDefaults.layoutModeKey) ?? "")
            ?? .automatic
        result["screenCropLayouts"] = .array(
            WizardDefaults.screenCropLayouts(for: layout, defaults: defaults).map(
                JSONSetting.string))
        let branding = WizardDefaults.brandingOverride(defaults: defaults).resolved(
            defaults: defaults)
        for (key, enabled) in [
            ("includeWatermark", branding.includeWatermark),
            ("includeHeadline", branding.includeHeadline), ("includeOutro", branding.includeOutro),
        ] {
            if defaults.string(forKey: snapshotKey) == nil { result[key] = .bool(enabled) }
        }
        let duration = WizardDefaults.durationModeKey
        if let mode = defaults.string(forKey: duration) {
            let choice = WizardDurationMode(rawValue: mode) ?? .automatic
            result["targetDurationSeconds"] =
                (choice.duration
                ?? (choice == .custom
                    ? defaults.integer(forKey: WizardDefaults.customDurationKey) : nil))
                .map { .number(Double($0)) } ?? .null
        }
        let audio = WizardDefaults.audioMode(defaults: defaults)
        result["useMusic"] = .bool(audio.useMusic)
        result["muteSource"] = .bool(audio.muteSource)
        result["selectedRunIDs"] = .array(
            (defaults.string(forKey: "wizard.selectedRunIDs") ?? "").split(separator: ",")
                .compactMap {
                    Double($0).map(JSONSetting.number)
                })
        result["sourcePeople"] = .array(
            (defaults.string(forKey: "wizard.sourcePeople") ?? "").split(separator: ",").map {
                .string(String($0))
            })
        return result
    }
    static func analysis(defaults: UserDefaults) -> [String: JSONSetting] {
        var result = JSONSetting.dictionary(AnalysisRunSettings())
        for (field, key) in analysisKeys {
            if let value = defaults.object(forKey: key) { result[field] = setting(value) }
        }
        result["breakdownTags"] = .array(
            (defaults.string(forKey: "analysis.breakdownTags") ?? "").split(separator: ",").map {
                .string(String($0))
            })
        return result
    }
    private static func setting(_ value: Any) -> JSONSetting {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            return CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue) : .number(value.doubleValue)
        }
        return .null
    }
    static func write(
        _ result: [String: JSONSetting], kind: AISettingsEnvelope.Kind,
        scopes: Set<AISettingsScope> = Set(AISettingsScope.allCases),
        sourceName: String = "another run", defaults: UserDefaults
    ) {
        let mapping = kind == .wizard ? wizardKeys : analysisKeys
        let allowed = scopes.reduce(into: Set<String>()) {
            $0.formUnion(AISettingsEnvelope.keys($1, kind: kind))
        }
        for (field, key) in mapping where allowed.contains(field) {
            guard let value = result[field] else { continue }
            switch value {
            case .null: defaults.removeObject(forKey: key)
            case .bool(let v): defaults.set(v, forKey: key)
            case .number(let v): defaults.set(v, forKey: key)
            case .string(let v): defaults.set(v, forKey: key)
            default: break
            }
        }
        func list(_ key: String) -> String {
            guard case .array(let values) = result[key] else { return "" }
            return values.compactMap { $0.string ?? $0.number.map { String(Int64($0)) } }.joined(
                separator: ",")
        }
        if kind == .analysis {
            guard scopes.contains(.options) else { return }
            defaults.set(list("breakdownTags"), forKey: "analysis.breakdownTags")
            defaults.set(!list("breakdownTags").isEmpty, forKey: "analysis.autoBreakdown")
        } else {
            defaults.set(AISettingsJSON.encode(result), forKey: snapshotKey)
            defaults.set(sourceName, forKey: sourceNameKey)
            if scopes.contains(.sources) {
                defaults.set(list("selectedRunIDs"), forKey: "wizard.selectedRunIDs")
                defaults.set(!list("selectedRunIDs").isEmpty, forKey: "wizard.limitToSelection")
                defaults.set(list("sourcePeople"), forKey: "wizard.sourcePeople")
            }
            guard scopes.contains(.options) else { return }
            if let seconds = result["targetDurationSeconds"]?.number {
                defaults.set("custom", forKey: WizardDefaults.durationModeKey)
                defaults.set(Int(seconds), forKey: WizardDefaults.customDurationKey)
            } else {
                defaults.set("automatic", forKey: WizardDefaults.durationModeKey)
            }
            let useMusic = result["useMusic"] == .bool(true)
            let mute = result["muteSource"] == .bool(true)
            defaults.set(
                useMusic ? (mute ? "music" : "mix") : "original",
                forKey: WizardDefaults.audioModeKey)
            let captions = result["addCaptions"] == .bool(true)
            let headlines = result["enableTextOverlays"] == .bool(true)
            defaults.set(
                captions ? (headlines ? "both" : "captions") : (headlines ? "headlines" : "none"),
                forKey: WizardDefaults.textModeKey)
            defaults.set(list("screenCropLayouts"), forKey: WizardDefaults.selectedLayoutsKey)
            defaults.set(
                list("screenCropLayouts").isEmpty ? "singleScene" : "selected",
                forKey: WizardDefaults.layoutModeKey)
        }
    }
}
