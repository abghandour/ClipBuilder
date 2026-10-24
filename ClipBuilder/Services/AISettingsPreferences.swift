import CoreFoundation
import Foundation

@MainActor enum AISettingsPreferences {
    static let snapshotKey = "wizard.aiRunOptions"
    static let sourceNameKey = "wizard.aiRunSourceName"

    static func clearWizardPaste(defaults: UserDefaults) {
        for key in [
            snapshotKey, sourceNameKey, "wizard.modelOverride", "wizard.selectedRunIDs",
            "wizard.limitToSelection", "wizard.sourcePeople", "wizard.favoritesOnly",
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
        "dubLanguage": "wizard.dubLanguage",
        "strikeStats": "wizard.strikeStats", "strikeUnits": "wizard.strikeUnits",
        "strikeSpeedCallouts": "wizard.strikeSpeedCallouts", "strikeGrapplingCard": "wizard.strikeGrapplingCard",
        "strikeRoundCard": "wizard.strikeRoundCard",
        "nameTags": "wizard.nameTags", "nameTagContent": "wizard.nameTagContent",
        "nameTagStyle": "wizard.nameTagStyle", "nameTagPosition": "wizard.nameTagPosition",
        "nameTagStyleID": "wizard.nameTagStyleID",
        "safe_area_only": "wizard.safeAreaOnly",
        "workflow": WizardDefaults.workflowKey,
        "musicTrack": "wizard.musicTrack", "overlayStyle": "wizard.overlayStyle",
        "overlayAnimation": "wizard.overlayAnimation", "overlayPlacement": "wizard.overlayPlacement",
        "pinnedOverlayTemplate": "wizard.pinnedOverlayTemplate", "framingCamera": "wizard.framingCamera",
        "highlightFraming": "wizard.highlightFraming", "interviewZoom": "wizard.interviewZoom", "interviewZoomMoves": "wizard.interviewZoomMoves",
        "interviewCuts": "wizard.interviewCuts", "interviewPunchIn": "wizard.interviewPunchIn", "useBRoll": "wizard.useBRoll",
        "brollInstructions": "wizard.brollInstructions",
        "podcastFraming": "wizard.podcastFraming", "critiqueLoop": "wizard.critiqueLoop",
        "critiqueTargetScore": "wizard.critiqueTargetScore", "critiqueMaxVersions": "wizard.critiqueMaxVersions",
        "favoritesOnly": "wizard.favoritesOnly",
        "modelOverride": "wizard.modelOverride", "stackLevel": SceneStacks.levelKey,
        "useFightResearch": "wizard.useFightResearch",
        "includeIntroBumper": "wizard.bumperIntro", "includeOutroBumper": "wizard.bumperOutro",
        "includeMiddleBumper": "wizard.bumperMiddle",
        "lookPreset": WizardExpressExtras.lookPresetKey, "transitionChoice": WizardExpressExtras.transitionChoiceKey,
        "lookIntensity": WizardExpressExtras.lookIntensityKey,
        "fixedOverlayEnabled": WizardExpressExtras.overlayEnabledKey,
        "fixedOverlayTemplate": WizardExpressExtras.overlayTemplateKey,
        "fixedOverlayStart": WizardExpressExtras.overlayStartKey,
        "fixedOverlayDuration": WizardExpressExtras.overlayDurationKey,
        "fixedOverlayTextsJoined": WizardExpressExtras.overlayTextsKey,
        "fixedOverlayPosition": WizardExpressExtras.overlayPositionKey,
        "watermarkOverlayTemplate": WizardExpressExtras.watermarkOverlayKey,
        "watermarkOpacity": WizardExpressExtras.watermarkOpacityKey,
        "introBumperLibraryPath": WizardExpressExtras.introBumperKey,
        "outroBumperLibraryPath": WizardExpressExtras.outroBumperKey,
        "outputMode": "wizard.outputMode",
    ]
    static let analysisKeys: [String: String] = [
        "instructions": "analysis.instructions", "sampleInterval": "analysis.sampleInterval",
        "smartSampling": "analysis.smartSampling",
        "includeTranscript": "analysis.includeTranscript",
        "autoZoomUnframed": "analysis.autoZoomUnframed", "detectPeople": "analysis.detectPeople",
        "language": "analysis.language",
        "provider": "analysis.provider", "model": "analysis.model",
    ]
    static func wizard(defaults: UserDefaults, profile: BrandProfile) -> [String: JSONSetting] {
        WizardDefaults.migrateLegacy(defaults: defaults)
        var options = WizardOptions()
        options.renderSettings = profile.defaultRenderSettings
        options.pacing = profile.defaultPacing
        options.dubLanguage = profile.editing?.footage.dubLanguage
        var result = JSONSetting.dictionary(options)
        if let saved = AISettingsJSON.decode(
            [String: JSONSetting].self, defaults.string(forKey: snapshotKey))
        {
            result.merge(WizardOptions.normalizeSettings(saved)) { _, new in new }
        }
        for (field, key) in wizardKeys {
            if let value = defaults.object(forKey: key) { result[field] = setting(value) }
        }
        if let selected = defaults.string(forKey: "wizard.safeAreaPlatforms") {
            let platforms = selected.split(separator: ",").map(String.init)
            result["safe_area_platforms"] = platforms.isEmpty ? .null : .array(platforms.map(JSONSetting.string))
        }
        let captionChoices = WizardCaptionChoices.load(profileName: profile.profileName, defaults: defaults)
        result["captionPosition"] = captionChoices.captionPosition.map(JSONSetting.string) ?? .null
        result["speakerCaptionPositions"] = captionChoices.speakerCaptionPositions.map(JSONSetting.dictionaryValue) ?? .null
        result["captionStyleID"] = captionChoices.captionStyleID.map(JSONSetting.string) ?? .null
        if CropRecipe.Kind(rawValue: result["highlightFraming"]?.string ?? "") == nil {
            result["highlightFraming"] = .null
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
        sourceName: String = "another run", profileName: String? = nil, defaults: UserDefaults,
        recordSnapshot: Bool = true
    ) {
        let result = kind == .wizard ? WizardOptions.normalizeSettings(result) : result
        let mapping = kind == .wizard ? wizardKeys : analysisKeys
        let allowed = scopes.reduce(into: Set<String>()) {
            $0.formUnion(AISettingsEnvelope.keys($1, kind: kind))
        }
        if kind == .wizard, let profileName, scopes.contains(.options) {
            var choices = WizardCaptionChoices.load(profileName: profileName, defaults: defaults)
            if let value = result["captionPosition"] { choices.captionPosition = value.string }
            if let value = result["speakerCaptionPositions"] { choices.speakerCaptionPositions = value.decodeValue() }
            if let value = result["captionStyleID"] { choices.captionStyleID = value.string }
            choices.save(profileName: profileName, defaults: defaults)
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
            if recordSnapshot {
                defaults.set(AISettingsJSON.encode(result), forKey: snapshotKey)
                defaults.set(sourceName, forKey: sourceNameKey)
            } else if scopes.contains(.options), let watermark = result["includeWatermark"]?.bool {
                // Without a snapshot the brand elements come from the override
                // key, so derive it from the three flags the dictionary carries.
                let headline = result["includeHeadline"]?.bool ?? watermark
                let outro = result["includeOutro"]?.bool ?? watermark
                let override: WizardBrandingOverride = !watermark ? .none : (headline && outro ? .standard : .minimal)
                defaults.set(override.rawValue, forKey: WizardDefaults.brandingOverrideKey)
            }
            if scopes.contains(.options) {
                if result["safe_area_platforms"] != nil {
                    defaults.set(list("safe_area_platforms"), forKey: "wizard.safeAreaPlatforms")
                }
                if result["workflow"]?.string == nil {
                    defaults.set(WizardWorkflow.automatic.rawValue, forKey: WizardDefaults.workflowKey)
                }
                // Pasted legacy split-feed settings need the same mapping even
                // after this installation has migrated its own preferences.
                if result["podcastFraming"]?.string == PodcastFramingMode.splitZoom.rawValue {
                    defaults.set(CropRecipe.Kind.grid.rawValue, forKey: "wizard.highlightFraming")
                    defaults.set(PodcastFramingMode.followSpeaker.rawValue, forKey: "wizard.podcastFraming")
                }
                defaults.set(true, forKey: WizardCameraFocus.migrationKey)
                let recipe = ReelRecipe.recipe(id: defaults.string(forKey: "wizard.formatPreset") ?? "custom") ?? .custom
                let outcome = WizardFormPlan.outcome(recipe: recipe, critiqueLoop: defaults.bool(forKey: "wizard.critiqueLoop"))
                defaults.set(outcome.rawValue, forKey: "wizard.outcome")
            }
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
