import Foundation
import Testing
@testable import Clip_Builder

@Suite("Settings Codable")
struct SettingsCodableTests {
    @Test("Settings preserve unknown AI task keys without catalog entries")
    func unknownAITaskKeysRoundTrip() throws {
        let key = "retired_task"
        #expect(AITask(rawValue: key) == nil)
        #expect(!AICatalog.tasks.contains(key))
        #expect(AICatalog.taskLabels[key] == nil)
        #expect(AICatalog.taskDefaults[key] == nil)
        #expect(AICatalog.recommendedChains[key] == nil)

        let data = Data(#"{"ai":{"tasks":{"retired_task":"codex","wizard":"claude"},"task_models":{"retired_task":"saved-model"}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.ai.tasks[key] == "codex")
        #expect(settings.ai.taskModels[key] == "saved-model")
        #expect(settings.ai.tasks["wizard"] == "claude")
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.ai.tasks == settings.ai.tasks)
        #expect(roundTrip.ai.taskModels == settings.ai.taskModels)

        let configured = AIRoutingResolver.choice(task: key, local: roundTrip.ai, team: nil)
        #expect(configured.provider == "codex" && configured.model == "saved-model")
        let fallback = AICatalog.topRecommended(task: key)
        #expect(fallback.provider == "claude")
        #expect(fallback.model == AICatalog.provider("claude")?.defaultModel)
    }

    @Test("Analysis settings decode legacy JSON and round-trip optional pipeline versions")
    func analysisPipelineCompatibility() throws {
        let legacy = Data(#"{"instructions":"","sampleInterval":0,"includeTranscript":false,"language":"","detectPeople":true,"autoZoomUnframed":false,"breakdownTags":[],"notes":[],"sourcePeople":[],"sourceProfile":"","modelPrompts":{}}"#.utf8)
        let settings = try JSONDecoder().decode(AnalysisRunSettings.self, from: legacy)
        #expect(settings.pipeline == nil)
        for pipeline in [AnalysisPipeline.visualPass, AnalysisPipeline.podcastPass] {
            var stamped = settings
            stamped.pipeline = pipeline
            let data = try JSONEncoder().encode(stamped)
            #expect(try JSONDecoder().decode(AnalysisRunSettings.self, from: data) == stamped)
            // A run's provenance must not be applied to another run as a user option.
            let envelope = AISettingsEnvelope(kind: .analysis, sourceName: "Run", scopes: [.options],
                                              settings: JSONSetting.dictionary(stamped))
            #expect(envelope.settings["pipeline"] == nil)
        }
    }

    @Test("Profiles decode optional AI routing with snake case keys and tolerate future fields")
    func profileAIRoutingCompatibility() throws {
        let legacy = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Legacy"}"#.utf8))
        #expect(legacy.aiRouting == nil)
        let legacyFields = try JSONDecoder().decode(SyncMapping.WireRow.self, from: JSONEncoder().encode(legacy))
        #expect(legacyFields["ai_routing"] == nil)
        let json = #"{"ai_routing":{"tasks":{"wizard":"codex"},"task_models":{"wizard":"chosen-model"},"future_policy":true}}"#
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data(json.utf8))
        let routing = try #require(profile.aiRouting)
        #expect(routing.tasks == ["wizard": "codex"])
        #expect(routing.taskModels == ["wizard": "chosen-model"])
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(BrandProfile.self, from: data).aiRouting == routing)
        let fields = try JSONDecoder().decode(SyncMapping.WireRow.self, from: data)
        #expect(fields["aiRouting"] == nil)
        guard case .object(let nested) = fields["ai_routing"] else {
            Issue.record("Missing AI routing object")
            return
        }
        #expect(Set(nested.keys) == ["tasks", "task_models"])
        let empty = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"ai_routing":{}}"#.utf8))
        #expect(empty.aiRouting == ProfileAIRouting())
        let partial = try JSONDecoder().decode(ProfileAIRouting.self, from: Data(#"{"tasks":{"wizard":"claude"}}"#.utf8))
        #expect(partial.taskModels.isEmpty)
        let null = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"ai_routing":null}"#.utf8))
        #expect(null.aiRouting == nil)
    }

    @Test("Profiles decode with and without optional editing defaults")
    func profileEditingCompatibility() throws {
        let legacy = try JSONDecoder().decode(BrandProfile.self, from: Data(#"{"profile_name":"Legacy"}"#.utf8))
        #expect(legacy.editing == nil)
        let json = #"{"editing":{"podcast":{"dead_air_seconds":2.75,"future_threshold":42},"footage":{"language":"pt-BR","future_mode":true},"future_section":{}}}"#
        let profile = try JSONDecoder().decode(BrandProfile.self, from: Data(json.utf8))
        let editing = try #require(profile.editing)
        #expect(editing.podcast.deadAirSeconds == 2.75)
        #expect(editing.podcast.highlightMaxSeconds == 30)
        #expect(editing.footage.language == "pt-BR")
        #expect(editing.footage.analysisMode == "visual")
        #expect(editing.transitions == TransitionSettings())
        #expect(try JSONDecoder().decode(BrandProfile.self, from: JSONEncoder().encode(profile)).editing == editing)
        #expect(try JSONDecoder().decode(ProfileEditingDefaults.self, from: Data("{}".utf8)) == ProfileEditingDefaults())
    }

    @Test("Editing defaults round trip with snake case keys and exclude the Mac's review preference")
    func editingDefaultsRoundTrip() throws {
        var settings = AppSettings()
        settings.transitions.xfadeDuration = 0.65
        settings.transitions.sfxEnabled = false
        settings.transitions.beatSnap = false
        settings.podcast.deadAirSeconds = 2.5
        settings.podcast.fillerRunSeconds = 3.5
        settings.podcast.highlightThreshold = 8.5
        settings.podcast.highlightMaxSeconds = 45
        settings.podcast.speakerHoldSeconds = 2.25
        settings.podcast.cleanupCutPolicy = .review
        settings.podcast.autoTranslateLanguage = "pt-BR"
        settings.podcast.reviewCutsByDefault = false
        settings.analysisMode = "speech"
        settings.transcribeLanguage = "en-US"
        settings.transcribeHint = "Jiu-jitsu"
        let editing = ProfileEditingDefaults(seedingFrom: settings)
        let data = try JSONEncoder().encode(editing)
        #expect(try JSONDecoder().decode(ProfileEditingDefaults.self, from: data) == editing)
        let fields = try JSONDecoder().decode(SyncMapping.WireRow.self, from: data)
        #expect(Set(fields.keys) == ["transitions", "podcast", "footage"])
        guard case .object(let podcast) = fields["podcast"],
              case .object(let footage) = fields["footage"],
              case .object(let transitions) = fields["transitions"] else {
            Issue.record("Missing editing sections")
            return
        }
        #expect(Set(podcast.keys) == ["dead_air_seconds", "filler_run_seconds", "highlight_threshold",
                                      "highlight_max_seconds", "speaker_hold_seconds", "cleanup_cut_policy", "auto_translate_language"])
        #expect(Set(footage.keys) == ["analysis_mode", "language", "vocabulary_hint"])
        #expect(Set(transitions.keys) == ["xfade_duration", "sfx_enabled", "beat_snap"])
        let serviceSettings = editing.podcast.settings(reviewCutsByDefault: false)
        #expect(!serviceSettings.reviewCutsByDefault)
        #expect(PodcastEditingPolicy(serviceSettings) == editing.podcast)
        // The legacy app file must retain all moved keys for older builds.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(ProfileEditingDefaults(seedingFrom: legacy) == editing)
    }

    @Test("Podcast editing policy clamps decoded and assigned highlight lengths")
    func editingHighlightClamp() throws {
        let low = try JSONDecoder().decode(PodcastEditingPolicy.self, from: Data(#"{"highlight_max_seconds":0}"#.utf8))
        var high = try JSONDecoder().decode(PodcastEditingPolicy.self, from: Data(#"{"highlight_max_seconds":900}"#.utf8))
        #expect(low.highlightMaxSeconds == 5)
        #expect(high.highlightMaxSeconds == 120)
        high.highlightMaxSeconds = .infinity
        #expect(high.highlightMaxSeconds == 30)
        high.highlightMaxSeconds = 1
        #expect(high.highlightMaxSeconds == 5)
    }

    @Test("AppStore falls back without seeding and profile edits keep local preferences intact")
    @MainActor
    func editingDefaultsFallback() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var settings = AppSettings()
        settings.transcribeLanguage = "pt-BR"
        settings.podcast.deadAirSeconds = 3
        settings.podcast.reviewCutsByDefault = false
        settings.transitions.xfadeDuration = 0.75
        let profile = BrandProfile(name: "Editing fallback")
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai))
        #expect(store.editingDefaults == ProfileEditingDefaults(seedingFrom: settings))
        #expect(store.activeProfile.editing == nil)
        #expect(ProfileStore.load(name: profile.profileName) == nil)
        store.editingBinding(\.podcast.deadAirSeconds).wrappedValue = 4
        #expect(store.activeProfile.editing?.podcast.deadAirSeconds == 4)
        #expect(store.editingDefaults.footage.language == "pt-BR")
        #expect(store.editingDefaults.transitions.xfadeDuration == 0.75)
        #expect(store.settings.podcast.deadAirSeconds == 3)
        #expect(!store.podcastEditingSettings.reviewCutsByDefault)
        #expect(ProfileStore.load(name: profile.profileName)?.editing == store.activeProfile.editing)
        store.activeProfile = BrandProfile(name: "Another profile")
        #expect(store.activeProfile.editing == nil)
        #expect(store.editingDefaults.podcast.deadAirSeconds == 3)
        store.saveActiveProfile()
        #expect(store.activeProfile.editing == ProfileEditingDefaults(seedingFrom: settings))
    }

    @Test("older settings JSON receives current defaults")
    func olderShapeDefaults() throws {
        let data = Data(#"{"analysis_mode":"speech","transcribe_provider":"whisper","ai":{"tasks":{"wizard":"claude"}}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.analysisMode == "speech")
        #expect(settings.transcribeProvider == "apple")
        #expect(settings.theme == "default")
        #expect(settings.instagram.fetchLimit == 12)
        #expect(settings.transitions.xfadeDuration == 0.35)
        #expect(settings.ai.tasks["wizard"] == "claude")
        #expect(settings.ai.taskModels.isEmpty)

        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.analysisMode == settings.analysisMode)
        #expect(roundTrip.instagram.fetchLimit == settings.instagram.fetchLimit)
        #expect(roundTrip.transitions.xfadeDuration == settings.transitions.xfadeDuration)
    }

    @Test("transition duration is clamped when decoded")
    func transitionClamp() throws {
        let low = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"xfade_duration":0}"#.utf8))
        let high = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"xfade_duration":9}"#.utf8))
        #expect(low.xfadeDuration == 0.1)
        #expect(high.xfadeDuration == 1)
    }

    @Test("Existing Instagram settings default to Facebook without token dates")
    func legacyInstagram() throws {
        let json = #"{"instagram":{"connected_username":"peacegrappler","connected_ig_user_id":"ig-123","fetch_limit":24}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).instagram
        #expect(settings.connectedUsername == "peacegrappler")
        #expect(settings.connectedIGUserID == "ig-123")
        #expect(settings.fetchLimit == 24)
        #expect(settings.connections.isEmpty)
        #expect(!settings.isGraphConnected)
        #expect(settings.tokenFlavor == "facebook")
        #expect(settings.tokenExpiresAt == nil)
        #expect(settings.tokenRefreshedAt == nil)
    }

    @Test("Two Instagram connections round trip without legacy single-account keys")
    func instagramTokenMetadata() throws {
        var settings = InstagramSettings()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        settings.connections = [
            InstagramConnection(username: "peacegrappler", igUserID: "ig-123", tokenFlavor: "facebook"),
            InstagramConnection(username: "podcast", igUserID: "ig-456", tokenFlavor: "instagram",
                                tokenExpiresAt: instant.addingTimeInterval(60 * 86400), tokenRefreshedAt: instant),
        ]
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["connections"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(Set(rows[1].keys) == ["username", "ig_user_id", "token_flavor", "token_expires_at", "token_refreshed_at"])
        for key in ["connected_username", "connected_ig_user_id", "token_flavor", "token_expires_at", "token_refreshed_at"] {
            #expect(object[key] == nil)
        }
        let decoded = try JSONDecoder().decode(InstagramSettings.self, from: data)
        #expect(decoded.connections == settings.connections)
        #expect(decoded.isGraphConnected)
        #expect(decoded.connection(for: "PODCAST") == settings.connections[1])
        #expect(decoded.connection(for: "unconnected") == nil)
    }
}

extension SettingsCodableTests {
    @Test func captionPresentationChoicesAreOptionalAndBelongToStepTwo() throws {
        let old = try JSONDecoder().decode(WizardOptions.self, from: Data("{}".utf8))
        #expect(old.captionPosition == nil && old.captionStyleID == nil)
        for position in [nil, "bottom", "middle", "top"] as [String?] {
            var options = WizardOptions()
            options.captionPosition = position
            options.captionStyleID = UUID().uuidString
            let decoded = try JSONDecoder().decode(WizardOptions.self, from: JSONEncoder().encode(options))
            #expect(decoded.captionPosition == position && decoded.captionStyleID == options.captionStyleID)
            let step = try JSONDecoder().decode(WizardStep2Options.self, from: JSONEncoder().encode(options.step2))
            let merged = WizardOptions.merge(step1: options.step1, step2: step)
            #expect(merged.captionPositionOverride == position && merged.captionStyleID == options.captionStyleID)
            let cleared = WizardOptions.merge(step1: options.step1, step2: WizardStep2Options(), base: options)
            #expect(cleared.captionPosition == nil && cleared.captionStyleID == nil)
            let first = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options.step1)) as? [String: Any])
            #expect(first["captionPosition"] == nil && first["captionStyleID"] == nil)
        }
        #expect(AISettingsEnvelope.keys(.options, kind: .wizard).isSuperset(of: ["captionPosition", "captionStyleID"]))
    }
}
