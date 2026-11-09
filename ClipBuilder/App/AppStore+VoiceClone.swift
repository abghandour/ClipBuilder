import Foundation

extension AppStore {
    func isVoiceCloneBusy(personKey: String) -> Bool {
        voiceCloneInFlight.contains("\(profileGeneration)|\(personKey)")
    }

    /// Call only after the consent sheet's checkbox has been accepted.
    func startVoiceClone(personKey: String) {
        guard let database, let person = people.first(where: { $0.key == personKey }),
              !isVoiceCloneBusy(personKey: personKey) else { return }
        let generation = profileGeneration
        let operation = "\(generation)|\(personKey)"
        let previousID = editingDefaults.clonedVoices?[personKey]
        voiceCloneInFlight.insert(operation)
        jobs.start(.voiceClone, title: "Clone \(person.displayName)'s voice", project: nil,
                   profileGeneration: generation, subjectID: personKey,
                   cleanup: { self.voiceCloneInFlight.remove(operation) }) { log in
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipBuilder-voice-clone-\(UUID().uuidString)", isDirectory: true)
            var createdID: String?
            var client: ElevenLabsClient?
            var committed = false
            do {
                log("Picking clean speech for \(person.displayName)…")
                let files = try await VoiceCloneWork.extract(personKey: personKey, name: person.displayName,
                                                            database: database, scratch: scratch, log: log)
                try Task.checkCancellation()
                guard generation == self.profileGeneration, self.database === database else { throw CancellationError() }
                let uploader = try await VoiceCloneWork.client()
                client = uploader
                try Task.checkCancellation()
                guard generation == self.profileGeneration, self.database === database else { throw CancellationError() }
                log("Uploading \(person.displayName)'s voice…")
                let gender: String = switch DubVoiceGender.inferred(from: person.descriptor) {
                case .male: "male"
                case .female: "female"
                case .unknown: "unknown"
                }
                // Let an in-flight mutation return its ID even after Stop. The
                // parent checks cancellation immediately and deletes that ID.
                createdID = try await Task.detached {
                    try await uploader.addVoice(name: person.displayName + ElevenLabsVoices.cloneNameSuffix, files: files,
                        labels: ["gender": gender, "source": "clip-builder"], removeBackgroundNoise: true)
                }.value
                try Task.checkCancellation()
                log("Refreshing ElevenLabs voices…")
                try await ElevenLabsVoiceCache.shared.refresh()
                guard try await VoiceCloneWork.client().apiKey == uploader.apiKey else {
                    throw NSError(domain: "VoiceClone", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "The ElevenLabs key changed while cloning. Start again with the current account."])
                }
                try Task.checkCancellation()
                log("Removing scratch audio…")
                try await VoiceCloneWork.removeScratch(scratch)
                try Task.checkCancellation()
                guard generation == self.profileGeneration, self.database === database,
                      self.people.contains(where: { $0.key == personKey }), let id = createdID else {
                    throw CancellationError()
                }
                log("Saving \(person.displayName)'s cloned voice…")
                var editing = self.editingDefaults
                var voices = editing.dubVoices ?? [:]
                var clones = editing.clonedVoices ?? [:]
                voices[personKey] = ElevenLabsVoices.identifierPrefix + id
                clones[personKey] = id
                editing.dubVoices = voices
                editing.clonedVoices = clones
                try self.saveVoiceCloneEditing(editing)
                committed = true
                NotificationCenter.default.post(name: ElevenLabsVoices.settingsChanged, object: nil)
                if let previousID, previousID != id {
                    log("Removing the previous clone…")
                    // Replacement is already saved. A cleanup failure must not
                    // delete the new voice or lose the old ID from the error.
                    do {
                        try await Task.detached { try await uploader.deleteVoice(id: previousID) }.value
                        await ElevenLabsVoiceCache.shared.invalidate()
                        NotificationCenter.default.post(name: ElevenLabsVoices.settingsChanged, object: nil)
                    } catch {
                        self.presentError("New clone saved; could not remove previous ElevenLabs voice \(previousID)", error)
                    }
                }
                log("\(person.displayName)'s cloned voice is ready")
                return nil
            } catch {
                if !committed, let id = createdID, let client {
                    do {
                        try await Task.detached { try await client.deleteVoice(id: id) }.value
                        await ElevenLabsVoiceCache.shared.invalidate()
                    } catch {
                        self.presentError("Could not clean up ElevenLabs voice \(id); remove it in ElevenLabs", error)
                    }
                }
                do { try await VoiceCloneWork.removeScratch(scratch) }
                catch { self.presentError("Could not remove voice-clone scratch audio at \(scratch.path)", error) }
                throw error
            }
        }
    }

    /// The visible controls ask for confirmation before calling this.
    func removeVoiceClone(personKey: String) {
        guard let id = editingDefaults.clonedVoices?[personKey], !isVoiceCloneBusy(personKey: personKey) else { return }
        let generation = profileGeneration
        let profileName = activeProfile.profileName
        let operation = "\(generation)|\(personKey)"
        let name = people.first { $0.key == personKey }?.displayName ?? personKey
        voiceCloneInFlight.insert(operation)
        jobs.start(.voiceClone, title: "Remove \(name)'s clone", project: nil,
                   profileGeneration: generation, subjectID: personKey,
                   cleanup: { self.voiceCloneInFlight.remove(operation) }) { log in
            let client = try await VoiceCloneWork.client()
            try Task.checkCancellation()
            log("Removing \(name)'s voice from ElevenLabs…")
            // Once DELETE succeeds, reconcile local maps even if Stop raced it.
            try await Task.detached { try await client.deleteVoice(id: id) }.value
            if profileName != self.activeProfile.profileName {
                // A profile switch cancels the job but cannot undo DELETE.
                // Reconcile the originating profile on disk, never the active one.
                if var profile = ProfileStore.load(name: profileName),
                   profile.editing?.clonedVoices?[personKey] == id {
                    profile.editing?.clonedVoices?[personKey] = nil
                    profile.editing?.dubVoices?[personKey] = nil
                    try ProfileStore.save(profile)
                }
                await ElevenLabsVoiceCache.shared.invalidate()
                throw CancellationError()
            }
            if self.editingDefaults.clonedVoices?[personKey] == id {
                var editing = self.editingDefaults
                editing.clonedVoices?[personKey] = nil
                editing.dubVoices?[personKey] = nil
                do { try self.saveVoiceCloneEditing(editing) }
                catch {
                    // DELETE cannot be undone, even when Stop raced the save.
                    self.presentError("Voice removed from ElevenLabs, but its profile mapping could not be saved", error)
                    throw error
                }
            }
            await ElevenLabsVoiceCache.shared.invalidate()
            NotificationCenter.default.post(name: ElevenLabsVoices.settingsChanged, object: nil)
            log("\(name)'s clone removed")
            return nil
        }
    }

    /// Throw before publishing new state so a failed save can roll back the
    /// remote clone. The mapping rides the shared profile document, so every
    /// teammate sees who has a clone; a teammate whose ElevenLabs key is for
    /// another account sees it marked as such and keeps their own voice.
    private func saveVoiceCloneEditing(_ editing: ProfileEditingDefaults) throws {
        var profile = activeProfile
        profile.editing = editing
        try ProfileStore.save(profile)
        activeProfile = profile
        if let index = profiles.firstIndex(where: { $0.profileName == profile.profileName }) {
            profiles[index] = profile
        }
        queueSharedProfileSync()
    }
}
