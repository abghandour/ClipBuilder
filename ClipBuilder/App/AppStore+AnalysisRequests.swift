import Foundation

extension AppStore {
    /// Plan is read synchronously at the Analyze entry point. Database inputs
    /// and file evidence are then frozen before defaults or checkpoints change.
    func captureAnalysisRequest(video: VideoRecord, plan: AnalysisCheckpoint.Plan,
                                profile: BrandProfile, config: AIConfig, podcast: PodcastSettings,
                                language: String, freshSource: Bool = true, resolveType: Bool = false) async throws -> AnalysisRequest {
        var video = video
        guard let database else { throw ScriptError.invalid("No library is open.") }
        let people = try await database.fetchPeople()
        let markers = try await database.personMarkers(videoID: video.id)
        let notes = try await database.videoNotes(videoID: video.id)
        let usesTranscript = plan.includeTranscript || video.type?.usesPodcastPass == true || (video.type == nil && video.duration >= 300)
        let transcripts = usesTranscript ? try await database.fetchTranscripts(videoID: video.id).filter { !$0.isTranslation } : []
        let source = try await Task.detached(priority: .utility) {
            try SourceIdentityCache.shared.fingerprint(of: video.url, force: freshSource)
        }.value
        if resolveType, restoredAnalysisRequests[video.id] == nil, video.type == nil, video.duration >= 300 {
            let local = OnDevicePolicy.isEnabled(item: "long-recording", config: config)
            let features = local ? ((try? await database.fetchTranscriptFeatures(videoID: video.id)) ?? []) : []
            let speech = features.isEmpty ? nil : features.filter { $0.kind == .speech }.reduce(0) { $0 + $1.endTime - $1.startTime } / max(1, video.duration)
            let cuts = local ? await cachedDetectors(for: video)?.cuts : nil
            if let type = try await analyzer.classifyLongRecording(video: video, provider: plan.provider, model: plan.model,
                log: logSink(\.analysisLog), useLocal: local, speechFraction: speech, cuts: cuts) {
                video.videoType = type.rawValue
                try await database.setVideoType(id: video.id, type: type.rawValue)
            }
        }
        // Compare the video's sync natural key with freshly sampled bytes.
        // A replacement at the same path must never match the old request.
        let identity = source == video.hash ? video.hash : source
        var request = restoredAnalysisRequests[video.id] ?? AnalysisRequest(
            sourceIdentity: identity, videoType: video.videoType, pipeline: AnalysisPipeline.current(for: video.type),
            passVersions: ["scenes": AnalysisPipeline.current(for: video.type)], plan: plan)
        request.sourceIdentity = identity // never reuse a saved identity for changed bytes
        request.plan = plan
        if restoredAnalysisRequests[video.id] == nil {
            request.notes = plan.pastedNotes ?? notes.map { AnalysisRunNote(at: $0.atTime, note: $0.note) }
            request.markers = markers.map { marker in
                AnalysisRequest.Marker(at: marker.atTime, x: marker.x, y: marker.y, width: marker.width, height: marker.height,
                                       personKey: people.first { $0.id == marker.personID }?.key, ignored: marker.ignored)
            }
            // The identity hints actually supplied, excluding presentation names.
            request.people = people.map { .init(key: $0.key, descriptor: $0.descriptor) }
            request.tags = profile.effectiveTags
            request.domain = profile.effectiveDomain
            request.tasteRubric = profile.tasteRubric
            let hashes = await Task.detached(priority: .utility) {
                var hashes: [String: String] = [:]
                for path in Set(profile.tasteExemplarFrames + profile.tasteCategories.flatMap(\.exemplarFrames)) {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { hashes[path] = AnalysisRequest.digest(data) }
                }
                return hashes
            }.value
            request.exemplarHashes = profile.tasteExemplarFrames.compactMap { hashes[$0] }
            request.taste = profile.tasteCategories.map {
                .init(key: $0.key, rubric: $0.rubric, exemplarHashes: $0.exemplarFrames.compactMap { hashes[$0] })
            }
            request.onDevice = Dictionary(uniqueKeysWithValues: ["long-recording", "podcast-exchanges"].map {
                ($0, OnDevicePolicy.isEnabled(item: $0, config: config))
            })
            request.transcriptKey = transcripts.first?.transcriptionKey
            request.transcriptHash = await Task.detached(priority: .utility) {
                AnalysisRequest.transcriptFingerprint(transcripts)
            }.value
            request.language = video.type?.usesPodcastPass == true ? "" : language
            request.podcastJSON = AnalysisRequest.json(podcast)
            let routing = AIService(config: config)
            for task in ["analysis", "people", "exchanges"] {
                let primary = await routing.resolveProviderModel(task: task, provider: plan.provider, model: plan.model)
                var seen: Set<String> = [primary.provider]
                var routes = [AnalysisRequest.Route(provider: primary.provider, model: primary.model)]
                for entry in AICatalog.recommendedChains[task] ?? [] where seen.insert(entry.provider).inserted {
                    routes.append(.init(provider: entry.provider, model: entry.model))
                }
                request.routing[task] = routes
            }
        } else {
            request.notes = plan.pastedNotes ?? request.notes
            if let key = request.transcriptKey {
                let rows = try await database.fetchTranscripts(videoID: video.id, transcriptionKey: key).filter { !$0.isTranslation }
                if !rows.isEmpty {
                    // Keep the selected set, but corrections to that set are
                    // new inputs and must not retain the previous digest.
                    request.transcriptHash = await Task.detached(priority: .utility) {
                        AnalysisRequest.transcriptFingerprint(rows)
                    }.value
                }
            }
        }
        request.refreshPasses()
        return request.normalized
    }

    func refreshAnalysisComparisons() async {
        let generation = profileGeneration
        let plan = AnalysisRequest.capturePlan(defaults: .standard, singleVideo: true, provider: nil, model: nil, includeFightScoring: true)
        for video in videos where video.isPresent {
            do {
                // Previews trust the size/date-validated identity cache; Analyze
                // itself re-reads the source before it runs.
                let request = try await captureAnalysisRequest(video: video, plan: plan, profile: activeProfile,
                    config: effectiveAIConfig, podcast: podcastEditingSettings, language: editingDefaults.footage.language,
                    freshSource: false)
                guard !Task.isCancelled, generation == profileGeneration else { return }
                analysisRequestPreviews[video.id] = request
            } catch { analysisRequestPreviews[video.id] = nil }
        }
    }

    func duplicateAnalysis(for video: VideoRecord) -> AnalysisRun? {
        guard let request = analysisRequestPreviews[video.id] else { return nil }
        return AnalysisDuplicates.duplicate(videoID: video.id, request: request, runs: analysisRuns, passes: analysisPasses)
    }

    func analysisRequestHelp(for video: VideoRecord) -> String {
        guard let request = analysisRequestPreviews[video.id] else { return "Analyze this video with the current settings." }
        if duplicateAnalysis(for: video) != nil { return "Up to date, same settings. Analyze again to choose which passes to run." }
        guard let run = AnalysisDuplicates.successfulRuns(videoID: video.id, runs: analysisRuns, passes: analysisPasses).first,
              let old = AISettingsJSON.decode(AnalysisRequest.self, run.requestJSON) else { return "Analyze this video with the current settings." }
        return AnalysisRequestDiff.describe(old: old, new: request).joined(separator: "; ")
    }

    /// Restore portable inputs into a per-run profile, leaving the user's
    /// current profile untouched. Local exemplar paths are resolved by bytes.
    func analysisProfile(for request: AnalysisRequest, current: BrandProfile) async throws -> BrandProfile {
        try await Task.detached(priority: .utility) {
            var profile = current
            profile.tagSchema = request.tags
            profile.contentDomain = request.domain
            profile.tasteRubric = request.tasteRubric
            var paths: [String: String] = [:]
            for path in Set(current.tasteExemplarFrames + current.tasteCategories.flatMap(\.exemplarFrames)) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { paths[AnalysisRequest.digest(data)] = path }
            }
            let required = Set(request.exemplarHashes + request.taste.flatMap(\.exemplarHashes))
            guard required.allSatisfy({ paths[$0] != nil }) else {
                throw ScriptError.invalid("Some saved taste reference images are not available on this Mac.")
            }
            profile.tasteExemplarFrames = request.exemplarHashes.compactMap { paths[$0] }
            profile.tasteCategories = request.taste.map { item in
                TasteCategory(key: item.key, label: item.key, rubric: item.rubric,
                              exemplarFrames: item.exemplarHashes.compactMap { paths[$0] })
            }
            return profile
        }.value
    }
}
