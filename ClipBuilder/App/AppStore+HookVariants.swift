import Foundation

/// Controlled hook comparisons: the model proposes alternative openings for
/// one timeline, each variant (and the original) renders into the Library
/// with a shared `variantGroupID`, and the A/B comparison sheet asks which
/// opening is best. Runs as a background job; see docs/Hook-Variants-Plan.md.
extension AppStore {
    /// True while hook variants are being made for this timeline.
    func isMakingHookVariants(timelineID: Int64) -> Bool {
        jobs.running.contains { $0.kind == .hookVariants && $0.subjectID == String(timelineID) }
    }

    /// Ask for alternative openings of a timeline, render the original and
    /// each variant, then queue the side-by-side pick. The open timeline
    /// uses the Builder's current document, unsaved edits included.
    func startHookVariants(timelineID: Int64) {
        guard let database else { return }
        let document: TimelineDocument
        let builderScenes: [SceneRecord]?
        if timelineID == openTimelineID {
            document = builder.document
            builderScenes = builder.scenes
        } else if let record = timelines.first(where: { $0.id == timelineID }),
                  let data = record.documentJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TimelineDocument.self, from: data) {
            document = decoded
            builderScenes = nil
        } else {
            presentError("Could not open that timeline for hook variants.")
            return
        }
        guard HookVariantBuilder.openingTrack(document).count > 0 else {
            presentError("Add clips to the timeline first.")
            return
        }
        let timelineName = timelines.first { $0.id == timelineID }?.name ?? "Timeline"
        let generation = profileGeneration
        let profile = activeProfile
        let projectID = activeProjectID
        let projectName = activeProject?.name
        let renderer = multitrackRenderer
        let ai = ai
        let discoveryScenes = scenes
        jobs.start(.hookVariants, title: "Hook Variants — \(timelineName)", project: activeProject,
                   profileGeneration: generation, subjectID: String(timelineID)) { [weak self] log in
            let scenes: [SceneRecord]
            if let builderScenes {
                scenes = builderScenes
            } else {
                let referenced = try await database.fetchScenes(ids: Set(document.videoTrack.compactMap(\.sceneID)))
                scenes = SceneReferences.combining(discoveryScenes, referenced: referenced)
            }
            if let missing = FootageAvailability.missingSource(document: document, scenes: scenes) {
                throw AppJobEmptyResult(message: "\(missing): Not on this Mac. Download or import the source file first.")
            }
            log("Asking for alternative openings…")
            let prompt = HookVariantBuilder.prompt(
                document: document, scenes: scenes,
                allowClipAlternatives: HookVariantBuilder.allowsClipAlternatives(document))
            let response = try await ai.call(prompt: prompt, task: .hooks, log: log)
            let alternatives = HookVariantBuilder.parseAlternatives(response.text, document: document)
            let variants = HookVariantBuilder.variants(base: document, alternatives: alternatives)
            guard !variants.isEmpty else {
                throw AppJobEmptyResult(message: "The model proposed no usable alternative opening.")
            }
            log("\(variants.count) alternative opening(s): \(variants.map(\.label).joined(separator: ", "))")
            let groupID = "hooks-\(UUID().uuidString)"
            let renders = [(label: HookVariantBuilder.originalLabel, document: document)] + variants
            var rendered = 0
            for (index, variant) in renders.enumerated() {
                try Task.checkCancellation()
                log("Rendering \(index + 1) of \(renders.count): \(variant.label)")
                let outputName = MultitrackRenderer.outputBaseName(project: projectName,
                                                                   timeline: "\(timelineName) - Hook \(variant.label)")
                do {
                    let result = try await renderer.render(document: variant.document, scenes: scenes,
                                                           profile: profile, database: database,
                                                           centerStageCamera: WizardDefaults.fallbackFramingCamera,
                                                           projectID: projectID, outputName: outputName,
                                                           batchID: groupID, emit: log)
                    if let recordID = result.recordID {
                        try await database.updateGeneratedHookVariant(id: recordID, variantGroupID: groupID,
                                                                      hookLabel: variant.label)
                        rendered += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One failed variant should not lose the others.
                    log("\(variant.label) failed: \(error.userMessage)")
                }
            }
            guard let self, self.profileGeneration == generation else { return nil }
            await self.refreshAllNow()
            guard self.profileGeneration == generation else { return nil }
            guard rendered >= 2 else {
                throw AppJobEmptyResult(message: "Fewer than two hook variants rendered; nothing to compare.")
            }
            self.queueHookComparison(groupID: groupID)
            return .hookVariants(groupID: groupID, alternatives: alternatives, provenance: response.provenance)
        }
    }

    /// Present the side-by-side pick for one hook comparison.
    func queueHookComparison(groupID: String) {
        let videos = hookVariantVideos(groupID: groupID)
        guard videos.count > 1 else { return }
        let batch = ComparisonBatch(id: groupID, videos: videos)
        comparisonQueue.removeAll { $0.id == groupID }
        comparisonQueue.append(batch)
        if pendingComparison == nil { pendingComparison = comparisonQueue.first }
    }

    /// The renders of one hook comparison, in render order.
    func hookVariantVideos(groupID: String) -> [GeneratedVideoRecord] {
        generatedVideos.filter { $0.variantGroupID == groupID }.sorted { $0.id < $1.id }
    }

    /// The A/B picks recorded between the renders of one hook comparison.
    func hookPreferences(groupID: String) async -> [(chosenID: Int64, rejectedID: Int64)] {
        guard let database else { return [] }
        let ids = hookVariantVideos(groupID: groupID).map(\.id)
        return (try? await database.fetchHookPreferences(videoIDs: ids)) ?? []
    }
}
