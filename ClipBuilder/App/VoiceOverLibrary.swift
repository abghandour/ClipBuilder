import AVFoundation
import Observation

/// "Include in the reel" and the level of the reel's own sound under the
/// voice, remembered per profile. They take effect at once; they are not
/// part of the rough cut sheet's Apply and Discard.
nonisolated enum VoiceOverPreferences {
    static func includeKey(profile: String) -> String { "voiceOver.\(profile).include" }
    static func levelKey(profile: String) -> String { "voiceOver.\(profile).level" }

    /// The bed level Generate uses, or nil when the recordings are left out.
    static func bedLevel(profile: String, defaults: UserDefaults = .standard) -> Double? {
        if defaults.object(forKey: includeKey(profile: profile)) != nil,
           !defaults.bool(forKey: includeKey(profile: profile)) { return nil }
        guard defaults.object(forKey: levelKey(profile: profile)) != nil else { return VoiceOverMixer.defaultBedLevel }
        return min(1, max(0, defaults.double(forKey: levelKey(profile: profile))))
    }
}

/// The voice-over recordings of the Express reel on screen: the list the
/// rough cut sheet records into and the Express page shows.
///
/// Every read and write of the recordings' rows goes through one queue, in
/// the order it was asked for, and the list changes only to what the
/// database has confirmed. So a list fetched while something else was
/// happening is never older than what is shown, a correction is never
/// written to a row that is not there yet, and a recording's audio is
/// removed only after its row is known to be gone. Captioning and
/// translation take seconds and run outside the queue; only their short
/// writes join it.
@MainActor @Observable
final class VoiceOverLibrary {
    struct Owner: Equatable {
        var projectID: Int64
        var videoIDs: [Int64]
        /// The library file the recordings live in: two profiles can share
        /// project and video ids.
        var library = ""
    }

    private(set) var takes: [VoiceTake] = []
    private(set) var owner: Owner?
    /// The recording Delete just removed from the reel on screen; Undo puts it back.
    var lastDeleted: VoiceTake? { undoSlot.flatMap { $0.owner == owner ? $0.take : nil } }
    /// The take whose audio is being auditioned from its row.
    private(set) var auditioning: String?
    var message: String?
    /// Bumped when the level or Include changes, so the rough cut remixes its preview.
    var mixRevision = 0
    /// The rough cut is putting the recordings into its preview's sound.
    var mixing: Bool { mixToken != nil }
    private var mixToken: UUID?

    /// Marks a preview mix as running; the newest one owns the flag.
    func beginMix() -> UUID {
        let token = UUID()
        mixToken = token
        return token
    }

    /// Ends the mix `token` started, unless a newer one has taken over.
    func endMix(_ token: UUID) {
        if mixToken == token { mixToken = nil }
    }
    let recorder = VoiceRecorder()
    /// Rough cut sheets on screen. While there is one, the library is its
    /// to load; the Express page's panel takes it back after.
    var reviewSheets = 0

    /// The one delete that can be undone. Its row is gone from the database;
    /// its audio is kept until Undo is no longer offered. Quitting with Undo
    /// still offered leaves that file behind: nothing sweeps the folder,
    /// because another copy of the app on the same library may be holding
    /// a file for its own Undo.
    private var undoSlot: (take: VoiceTake, file: URL, owner: Owner, database: Database)?
    @ObservationIgnored private var audition: AVAudioPlayer?
    @ObservationIgnored private var auditionWatch: Task<Void, Never>?
    /// How captions are written here, kept so Undo can finish one it interrupted.
    @ObservationIgnored private var captioning: (language: String, ai: AIService)?
    /// Recordings whose caption is being written right now, by library file and id.
    @ObservationIgnored private var transcribing: Set<String> = []
    /// The end of the queue: the next piece of row work waits for it.
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    /// Lets AI work run as a job with a status-bar row; nil in tests.
    @ObservationIgnored weak var store: AppStore?

    /// Runs `work` after everything queued before it. Work in the queue must
    /// never wait for other queued work.
    @discardableResult
    private func queued<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let earlier = queueTail
        let task = Task {
            await earlier?.value
            return await work()
        }
        queueTail = Task { _ = await task.value }
        return task
    }

    /// Returns when everything queued so far has finished (tests).
    func settle() async {
        while let tail = queueTail {
            await tail.value
            if queueTail == tail { break }
        }
    }

    /// The list on screen is the one of this library file.
    private func shows(_ database: Database) -> Bool {
        owner?.library == database.path.path
    }

    /// Shows the recordings of `owner`, and writes the caption of any that
    /// was left waiting (the page moved on, or the app quit, mid-way).
    func load(_ owner: Owner, database: Database?, language: String, ai: AIService) async {
        guard let database else { takes = []; self.owner = nil; return }
        // Another reel: its recordings are not these.
        if self.owner != owner { takes = []; message = nil }
        self.owner = owner
        captioning = (language, ai)
        await queued { [self] in
            // A delete of another reel can no longer be undone from here.
            if let slot = undoSlot, slot.owner != self.owner { await forgetDeleted() }
            let loaded = (try? await database.fetchVoiceTakes(projectID: owner.projectID, videoIDs: owner.videoIDs)) ?? []
            guard self.owner == owner else { return }
            takes = loaded
            for take in loaded where take.state == .pending {
                transcribe(take, language: language, captionLanguage: nil, ai: ai, database: database)
            }
        }.value
    }

    // MARK: Recording

    /// Starts a recording; false when the microphone is not available.
    func beginRecording(database: Database) async -> Bool {
        guard !recorder.isRecording, await recorder.authorize() else { return false }
        stopAudition()
        let file = database.voiceTakesDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        guard recorder.start(to: file) else {
            message = "The microphone could not start recording."
            return false
        }
        message = nil
        return true
    }

    /// Stops the recording and keeps it at `reelTime`, anchored to the
    /// picture that was under it. A hold under 0.3 s is thrown away.
    func finishRecording(anchor: (videoID: Int64, sourceTime: Double, holdOffset: Double?, occurrence: Int)?, reelTime: Double,
                         language: String, captionLanguage: String?, ai: AIService, database: Database) {
        guard let result = recorder.stop() else { return }
        captioning = (language, ai)
        guard let owner, let anchor, result.duration >= 0.3 else {
            try? FileManager.default.removeItem(at: result.url)
            if anchor == nil, result.duration >= 0.3 { message = "No footage under the playhead; nothing was kept." }
            return
        }
        let take = VoiceTake(id: result.url.deletingPathExtension().lastPathComponent, projectID: owner.projectID,
                             videoID: anchor.videoID, sourceTime: anchor.sourceTime, holdOffset: anchor.holdOffset, occurrence: anchor.occurrence,
                             reelTime: max(0, reelTime),
                             duration: result.duration, file: result.url.lastPathComponent)
        queued { [self] in
            do {
                try await database.saveVoiceTake(take)
            } catch {
                // Not saved means not in the reel: it is not shown as kept.
                try? FileManager.default.removeItem(at: result.url)
                if self.owner == owner { message = "The recording could not be saved (\(error.localizedDescription))." }
                return
            }
            if self.owner == owner, !takes.contains(where: { $0.id == take.id }) { insert(take) }
            transcribe(take, language: language, captionLanguage: captionLanguage, ai: ai, database: database)
        }
    }

    /// Writes a recording's caption. It finishes against the database even
    /// if the page has moved to another source; the list is updated only
    /// when it still shows this recording.
    private func transcribe(_ take: VoiceTake, language: String, captionLanguage: String?, ai: AIService,
                            database: Database) {
        let key = "\(database.path.path)|\(take.id)"
        guard transcribing.insert(key).inserted else { return }
        Task {
            let spoken = await VoiceOverTranscriber.transcribe(take, audio: database.voiceTakeURL(take), language: language)
            let written = await queued { [self] in
                // False: deleted, or the user typed a caption while it was working.
                let written = (try? await database.setVoiceTakeTranscript(spoken)) == true
                await showStored(take.id, database: database)
                // Nothing more comes from this pass: one asked for from now on must start.
                if !written { transcribing.remove(key) }
                return written
            }.value
            guard written else { return }
            if let captionLanguage, !captionLanguage.isEmpty,
               !VoiceOverTranscriber.needingTranslation([spoken], target: captionLanguage).isEmpty {
                let translate: @MainActor () async -> Void = {
                    _ = await VoiceOverTranscriber.translateMissing([spoken], target: captionLanguage, ai: ai, database: database)
                }
                // An AI call: a job with a status-bar row and Stop, not a loose task.
                if let store {
                    try? await store.runVoiceOverJob(title: "Voice over — caption translation",
                                                     group: "voice-translate-take-\(take.id)", work: translate)
                } else {
                    await translate()
                }
            }
            await queued { [self] in
                await showStored(take.id, database: database)
                transcribing.remove(key)
            }.value
        }
    }

    /// Shows a recording as it is stored now. Queue work only: there the
    /// stored row cannot be older than the one shown.
    private func showStored(_ id: String, database: Database) async {
        guard let stored = (try? await database.fetchVoiceTake(id: id)) ?? nil, shows(database) else { return }
        replace(stored)
    }

    /// Stops a recording without keeping it (the sheet closed mid-hold).
    func cancelRecording() {
        guard let result = recorder.stop() else { return }
        try? FileManager.default.removeItem(at: result.url)
    }

    // MARK: Editing

    func delete(_ take: VoiceTake, database: Database) {
        if auditioning == take.id { stopAudition() }
        let asked = owner
        queued { [self] in
            // Asked twice, or the reel on screen changed first: nothing to delete here.
            guard let asked, owner == asked, shows(database),
                  let current = takes.first(where: { $0.id == take.id }) else { return }
            let removed: Bool
            do {
                removed = try await database.deleteVoiceTake(id: current.id)
            } catch {
                // Still in the database means still in the reel: it stays in the list.
                if owner == asked { message = "The recording could not be deleted (\(error.localizedDescription))." }
                return
            }
            if owner == asked { takes.removeAll { $0.id == current.id } }
            // Already deleted by another copy of the app on this library: that
            // copy offers the Undo and owns the audio. Nothing to undo here.
            guard removed else { return }
            // Only one delete can be undone: the one before it goes for good.
            await forgetDeleted()
            undoSlot = (current, database.voiceTakeURL(current), asked, database)
        }
    }

    func undoDelete(database: Database) {
        queued { [self] in
            // Asked twice, or for another reel's delete: nothing to put back here.
            guard let slot = undoSlot, slot.owner == owner, shows(database) else { return }
            // Taken out first: nothing may dispose of the audio while its row is being put back.
            undoSlot = nil
            do {
                // The audio is gone: there is nothing to put back.
                guard try await database.restoreVoiceTake(slot.take) else { return }
            } catch {
                // Not put back: Undo is offered again.
                undoSlot = slot
                if owner == slot.owner { message = "The recording could not be put back (\(error.localizedDescription))." }
                return
            }
            if owner == slot.owner, !takes.contains(where: { $0.id == slot.take.id }) { insert(slot.take) }
            // Deleted while its caption was being written: that result was
            // thrown away with the row, so it is written again.
            if slot.take.state == .pending, let captioning {
                transcribe(slot.take, language: captioning.language, captionLanguage: nil, ai: captioning.ai, database: database)
            }
        }
    }

    /// Gives up the delete that could be undone. Queue work only, so no
    /// put-back of this copy is under way. Its audio is removed only when
    /// the row is known to be gone still: another copy of the app on the
    /// same library may have put the recording back, and then the file is its.
    private func forgetDeleted() async {
        guard let slot = undoSlot else { return }
        undoSlot = nil
        try? await slot.database.discardVoiceTakeAudio(slot.take)
    }

    func setText(_ text: String, for id: String, database: Database) {
        correct(id, database: database) { stored in
            var corrected = VoiceOverTranscriber.corrected(stored, text: text)
            if corrected != stored, corrected.state == .pending || corrected.state == .failed {
                corrected.state = corrected.text.isEmpty ? .empty : .done
            }
            return corrected
        }
    }

    func setTranslation(_ text: String, language: String, for id: String, database: Database) {
        correct(id, database: database) { VoiceOverTranscriber.corrected($0, translation: text, language: language) }
    }

    /// Applies a correction to the row as it is stored when its turn comes
    /// (read and written in one step, so a translation arriving from
    /// elsewhere cannot fall between), and shows the row once it is saved.
    private func correct(_ id: String, database: Database, _ change: @escaping @Sendable (VoiceTake) -> VoiceTake) {
        queued { [self] in
            do {
                // False: gone (deleted before this turn came), or nothing changed.
                guard try await database.correctVoiceTake(id: id, change) else { return }
                await showStored(id, database: database)
            } catch {
                if shows(database) { message = "The caption could not be saved (\(error.localizedDescription))." }
            }
        }
    }

    /// Fills in the caption language for takes spoken in another one.
    func translate(to language: String, ai: AIService, database: Database) async {
        let missing = VoiceOverTranscriber.needingTranslation(takes, target: language)
        guard !missing.isEmpty else { return }
        _ = await VoiceOverTranscriber.translateMissing(missing, target: language, ai: ai, database: database)
        // The database only took translations of text that had not changed.
        await queued { [self] in
            for take in missing { await showStored(take.id, database: database) }
        }.value
    }

    // MARK: Listening

    func toggleAudition(_ take: VoiceTake, database: Database) {
        if auditioning == take.id { stopAudition(); return }
        stopAudition()
        guard let player = try? AVAudioPlayer(contentsOf: database.voiceTakeURL(take)), player.play() else {
            message = "The recording's audio file is missing."
            return
        }
        audition = player
        auditioning = take.id
        auditionWatch = Task { [weak self] in
            while !Task.isCancelled, player.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled, let self, self.audition === player else { return }
            self.auditioning = nil
            self.audition = nil
        }
    }

    func stopAudition() {
        auditionWatch?.cancel()
        audition?.stop()
        audition = nil
        auditioning = nil
    }

    private func insert(_ take: VoiceTake) {
        takes.append(take)
        takes.sort { ($0.reelTime, $0.createdAt) < ($1.reelTime, $1.createdAt) }
    }

    private func replace(_ take: VoiceTake) {
        guard let index = takes.firstIndex(where: { $0.id == take.id }) else { return }
        takes[index] = take
    }
}
