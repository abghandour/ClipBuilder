import Foundation

/// The exact text the Wizard sent when it last planned a reel for a profile,
/// kept whole. `AIRunCapture` only stores 2,000-character previews and the
/// Markdown run report exists only next to a rendered video, so this is the
/// one place the AI Lessons page can show "what the Wizard actually read".
nonisolated struct LastPlanRecord: Codable, Sendable, Equatable {
    enum Outcome: Codable, Sendable, Equatable {
        case pending, answered, failed(String), cancelled
    }
    struct Attempt: Codable, Sendable, Equatable {
        var prompt: String
        /// Attachment labels, in the order they were sent.
        var frames: [String]
        var requestedAt: Date
        var provider: String? = nil
        var model: String? = nil
        var outcome: Outcome = .pending
    }

    var profile: String
    var capturedAt: Date
    var attempts: [Attempt]
    /// Index into `attempts` of the plan the reel used; nil when none survived.
    var acceptedAttempt: Int?

    var accepted: Attempt? { acceptedAttempt.flatMap { attempts.indices.contains($0) ? attempts[$0] : nil } }

    /// Hidden file inside the learned directory so `LearnedLibrary.documents()` skips it.
    static func url(profile: String, library: LearnedLibrary = LearnedLibrary()) -> URL {
        library.directory.appendingPathComponent(".last-plan-" + LearnedPreferences.stableID(profile) + ".json")
    }

    func save(library: LearnedLibrary = LearnedLibrary()) throws {
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(profile: profile, library: library), options: .atomic)
    }

    static func load(profile: String, library: LearnedLibrary = LearnedLibrary()) -> LastPlanRecord? {
        guard let data = try? Data(contentsOf: url(profile: profile, library: library)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(LastPlanRecord.self, from: data), record.profile == profile else { return nil }
        return record
    }
}

/// Bookkeeping for one planning run, kept apart from the Wizard so every
/// branch (retry adopted, retry rejected, request failed, cancelled) is unit
/// testable. The Wizard begins an attempt before awaiting the provider, so a
/// request that never returns still leaves a trace.
nonisolated struct LastPlanRecorder: Sendable, Equatable {
    private(set) var record: LastPlanRecord

    init(profile: String, now: Date = Date()) {
        record = LastPlanRecord(profile: profile, capturedAt: now, attempts: [], acceptedAttempt: nil)
    }

    /// Returns the attempt index to report the outcome against.
    mutating func begin(prompt: String, frames: [String], now: Date = Date()) -> Int {
        record.attempts.append(.init(prompt: prompt, frames: frames, requestedAt: now))
        return record.attempts.count - 1
    }
    mutating func answered(_ index: Int, provider: String?, model: String?) {
        guard record.attempts.indices.contains(index) else { return }
        record.attempts[index].provider = provider
        record.attempts[index].model = model
        record.attempts[index].outcome = .answered
    }
    mutating func failed(_ index: Int, error: any Error) {
        guard record.attempts.indices.contains(index) else { return }
        record.attempts[index].outcome = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
    }
    mutating func accept(_ index: Int?) {
        record.acceptedAttempt = index.flatMap { record.attempts.indices.contains($0) ? $0 : nil }
    }
    func save(library: LearnedLibrary = LearnedLibrary(), now: Date = Date()) throws {
        var record = record
        record.capturedAt = now
        try record.save(library: library)
    }
}
