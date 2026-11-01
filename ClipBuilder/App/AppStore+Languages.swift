import Foundation

extension AppStore {
    func resolvedLanguages(for project: ProjectRecord?) -> ProjectLanguages {
        var profile = activeProfile
        profile.editing = editingDefaults
        return ProjectLanguageResolver.resolve(project: project?.languages, profile: profile)
    }

    var projectLanguages: ProjectLanguages { resolvedLanguages(for: activeProject) }

    func transcriptionLanguage(for video: VideoRecord? = nil) -> String {
        ProjectLanguageResolver.transcriptionLanguage(for: video, languages: projectLanguages)
    }

    func refreshLanguageReadiness() async {
        languageReadinessRevision &+= 1
        let revision = languageReadinessRevision
        let generation = profileGeneration
        let projectID = activeProjectID
        let database = database
        let profile = activeProfile
        let entries = projects.map { ($0.id, resolvedLanguages(for: $0)) }
        let engine = editingDefaults.footage.dubEngine.flatMap(DubVoiceEngine.init(rawValue:))
        var results: [Int64: [LanguageAsset]] = [:]
        var checked: [ProjectLanguages: [LanguageAsset]] = [:]
        for (id, languages) in entries {
            let assets: [LanguageAsset]
            if let cached = checked[languages] { assets = cached }
            else { assets = await LanguageReadiness.assets(for: languages, dubEngine: engine, probe: languageProbe) }
            checked[languages] = assets
            guard !Task.isCancelled, revision == languageReadinessRevision, generation == profileGeneration,
                  self.database === database, activeProjectID == projectID, activeProfile.profileName == profile.profileName,
                  activeProfile.editing == profile.editing, activeProfile.captionLanguages == profile.captionLanguages else { return }
            results[id] = assets
        }
        projectLanguageAssets = results
        languageAssets = projectID.flatMap { results[$0] } ?? []
    }

    func saveProjectLanguages(_ languages: ProjectLanguages?, project: ProjectRecord) async throws {
        guard let database, project.profileName == activeProfile.profileName else { throw CancellationError() }
        let generation = profileGeneration
        try await database.setProjectLanguages(id: project.id, languages: languages)
        let updated = try await database.fetchProjects()
        guard generation == profileGeneration, self.database === database else { throw CancellationError() }
        projects = updated
        analysisComparisonKeys = [:]
        projectLanguageAssets[project.id] = nil
        if activeProjectID == project.id { languageAssets = [] }
        Task { await refreshLanguageReadiness() }
    }

    /// Always probes fresh, including when invoked before the first UI refresh finishes.
    func requireProjectRecognizers(languages: ProjectLanguages? = nil) async throws {
        let generation = profileGeneration
        let database = database
        let required = languages ?? projectLanguages
        let assets = await LanguageReadiness.assets(for: ProjectLanguages(spoken: required.spoken), dubEngine: nil, probe: languageProbe)
        guard !Task.isCancelled, generation == profileGeneration, self.database === database else { throw CancellationError() }
        try LanguageReadiness.requireRecognizers(assets)
    }

    func installLanguageAssets() {
        guard let project = activeProject else { return }
        let generation = profileGeneration
        let languages = projectLanguages
        let engine = editingDefaults.footage.dubEngine.flatMap(DubVoiceEngine.init(rawValue:))
        let probe = languageProbe
        let translationID = UUID()
        jobs.start(.languageAssets, title: "Language Assets — \(project.name)", project: project,
                   profileGeneration: generation, subjectID: String(project.id), cleanup: { [weak self] in
            guard let self else { return }
            if self.languageTranslationInstall?.id == translationID { self.languageTranslationInstall = nil }
            Task { await self.refreshLanguageReadiness() }
        }) { [self] log in
            let assets = await LanguageReadiness.assets(for: languages, dubEngine: engine, probe: probe)
            try Task.checkCancellation()
            let recognizers = assets.filter { $0.kind == .recognizer && $0.installable }
            let total = max(1, assets.filter(\.installable).count)
            log("PROGRESS:0")
            for (index, asset) in recognizers.enumerated() {
                log("Installing \(asset.title) (\(index + 1)/\(recognizers.count))…")
                try await LanguageReadiness.installRecognizer(asset.language)
                log("PROGRESS:\(Double(index + 1) / Double(total))")
            }
            guard generation == profileGeneration, activeProjectID == project.id else { throw CancellationError() }
            let translations = assets.filter { $0.kind == .translation && $0.installable }
            if !translations.isEmpty {
                languageTranslationInstall = LanguageTranslationInstall(id: translationID, projectID: project.id,
                    generation: generation, pending: translations)
                log("Open Sources and approve the translation downloads. Stop cancels this installation.")
                var completed = recognizers.count
                while true {
                    try Task.checkCancellation()
                    guard generation == profileGeneration, activeProjectID == project.id,
                          let work = languageTranslationInstall, work.id == translationID else { throw CancellationError() }
                    if let failure = work.failure { throw ScriptError.invalid(failure) }
                    let done = total - work.pending.count - (work.current == nil ? 0 : 1)
                    if done > completed {
                        completed = done
                        log("Installed \(done) of \(total) language assets.")
                        log("PROGRESS:\(Double(done) / Double(total))")
                    }
                    if work.finished { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            if assets.contains(where: { $0.kind == .dubVoice && $0.state != .installed }) {
                log("Install dub voices in System Settings. Siri voices also need their Clip Builder Dub shortcut.")
            }
            await refreshLanguageReadiness()
            log(LanguageReadiness.summary(languageAssets) ?? "Project languages are ready on this Mac.")
            return nil
        }
    }
}
