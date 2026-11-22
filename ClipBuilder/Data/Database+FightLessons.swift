import Foundation

extension Database {
    func fightScoringLessonSourceCount() throws -> Int {
        Int(try connection.query("SELECT source_count FROM fight_scoring_learning_state WHERE id = 1")
            .first?["source_count"]?.intValue ?? 0)
    }

    func fetchFightScoringLessons() throws -> [FightScoringLesson] {
        try connection.query("SELECT * FROM fight_scoring_lessons ORDER BY id").map { row in
            FightScoringLesson(id: row["id"]?.intValue ?? 0, text: row["text"]?.stringValue ?? "",
                sourceCount: Int(row["source_count"]?.intValue ?? 0), createdAt: row["created_at"]?.stringValue,
                enabled: row["enabled"]?.intValue == 1)
        }
    }

    func fightLearningSnapshot() throws -> FightLearningSnapshot {
        try connection.transaction { try fightLearningSnapshotUnlocked() }
    }

    private func fightLearningSnapshotUnlocked() throws -> FightLearningSnapshot {
        let state = try connection.query("SELECT * FROM fight_scoring_learning_state WHERE id = 1").first
        let receipts = try connection.query("SELECT * FROM fight_correction_learning")
        let folded = Dictionary(uniqueKeysWithValues: receipts.compactMap { row -> (Int64, String)? in
            guard let id = row["correction_id"]?.intValue, let fingerprint = row["fingerprint"]?.stringValue else { return nil }
            return (id, fingerprint)
        })
        let videos = try connection.query("SELECT DISTINCT video_id FROM fight_corrections ORDER BY video_id")
            .compactMap { $0["video_id"]?.intValue }
        var pending: [FightCorrectionRecord] = []
        var roster: [VideoPersonRecord] = []
        for videoID in videos {
            let corrections = try fetchFightCorrections(videoID: videoID).filter {
                try folded[$0.id] != FightCorrections.learningFingerprint($0)
            }
            pending += corrections
            if !corrections.isEmpty { roster += try fetchVideoPeople(videoID: videoID) }
        }
        return FightLearningSnapshot(lessons: try fetchFightScoringLessons(), corrections: pending, roster: roster,
            revision: state?["revision"]?.intValue ?? 0, sourceCount: Int(state?["source_count"]?.intValue ?? 0))
    }

    /// Invalid JSON changes neither lessons nor receipts. Revision and content
    /// checks protect concurrent toggles, correction edits and other retry jobs.
    @discardableResult
    func saveFightScoringLessons(response: String, snapshot: FightLearningSnapshot) throws -> Int {
        let texts = try FightCorrections.parseLessons(response)
        return try connection.transaction {
            try Task.checkCancellation()
            let current = try fightLearningSnapshotUnlocked()
            guard current.revision == snapshot.revision,
                  snapshot.corrections.allSatisfy({ correction in
                      current.corrections.contains { $0.id == correction.id &&
                          (try? FightCorrections.learningFingerprint($0)) == (try? FightCorrections.learningFingerprint(correction)) }
                  }) else {
                throw AIError.notConfigured("Fight reviews or lessons changed while learning; the saved lessons were kept.")
            }
            // An empty answer is far more likely a failed distillation than a
            // decision to drop every rule: nothing is deleted, and the
            // corrections stay unlearned for the next attempt.
            if texts.isEmpty, !current.lessons.isEmpty {
                throw AIError.notConfigured("Fight scoring lessons came back empty; the saved lessons were kept.")
            }
            let count = current.sourceCount + snapshot.corrections.count
            // Retained rules keep their identity and disabled state.
            for lesson in current.lessons where !texts.contains(lesson.text) {
                try connection.execute("DELETE FROM fight_scoring_lessons WHERE id = ?", [.integer(lesson.id)])
            }
            for text in texts {
                if let prior = current.lessons.first(where: { $0.text == text }) {
                    try connection.execute("UPDATE fight_scoring_lessons SET source_count = ? WHERE id = ?",
                                           [.integer(Int64(count)), .integer(prior.id)])
                } else {
                    try connection.execute("INSERT INTO fight_scoring_lessons(text, source_count) VALUES (?, ?)",
                                           [.text(text), .integer(Int64(count))])
                }
            }
            for correction in snapshot.corrections {
                try connection.execute("""
                    INSERT INTO fight_correction_learning(correction_id, fingerprint) VALUES (?, ?)
                    ON CONFLICT(correction_id) DO UPDATE SET fingerprint = excluded.fingerprint
                    """, [.integer(correction.id), .text(try FightCorrections.learningFingerprint(correction))])
            }
            try connection.execute("UPDATE fight_scoring_learning_state SET revision = revision + 1, source_count = ? WHERE id = 1",
                                   [.integer(Int64(count))])
            return texts.count
        }
    }

    func setFightScoringLessonEnabled(id: Int64, enabled: Bool) throws {
        try connection.transaction {
            try connection.execute("UPDATE fight_scoring_lessons SET enabled = ? WHERE id = ?", [.integer(enabled ? 1 : 0), .integer(id)])
            try connection.execute("UPDATE fight_scoring_learning_state SET revision = revision + 1 WHERE id = 1")
        }
    }

    func deleteFightScoringLesson(id: Int64) throws {
        try connection.transaction {
            try connection.execute("DELETE FROM fight_scoring_lessons WHERE id = ?", [.integer(id)])
            try connection.execute("UPDATE fight_scoring_learning_state SET revision = revision + 1 WHERE id = 1")
        }
    }
}
