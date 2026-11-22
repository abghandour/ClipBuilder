import SwiftUI

struct FightScoringLessonsSection: View {
    @Environment(AppStore.self) private var store
    @State private var lessons: [FightScoringLesson] = []
    @State private var sourceCount = 0
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fight scoring").font(.headline).lineLimit(1).fixedSize()
                Spacer()
                Text("Learned from \(sourceCount) corrections")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Text("Used when scoring later fights in this profile on this Mac. Five new or changed corrections are learned after a retry.")
                .font(.caption).foregroundStyle(.secondary)
            if lessons.isEmpty {
                Text("No fight scoring lessons yet. Correct actions and retry a fight to teach the scorer.")
                    .foregroundStyle(.secondary)
            }
            ForEach(lessons) { lesson in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("Use lesson", isOn: Binding(
                        get: { lesson.enabled },
                        set: { enabled in change { database in
                            try await database.setFightScoringLessonEnabled(id: lesson.id, enabled: enabled)
                        } }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Use lesson: " + lesson.text)
                    Text(lesson.text).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        change { database in try await database.deleteFightScoringLesson(id: lesson.id) }
                    }.lineLimit(1).fixedSize()
                }.disabled(saving)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: "\(store.profileGeneration)|\(store.fightLessonsRevision)") { await reload() }
    }

    private func reload() async {
        guard let database = store.database else { lessons = []; sourceCount = 0; return }
        let generation = store.profileGeneration
        do {
            let lessons = try await database.fetchFightScoringLessons()
            let count = try await database.fightScoringLessonSourceCount()
            guard !Task.isCancelled, generation == store.profileGeneration, store.database === database else { return }
            self.lessons = lessons
            sourceCount = count
            error = nil
        } catch {
            ErrorLog.record("Load fight scoring lessons", error.localizedDescription)
            guard !Task.isCancelled, generation == store.profileGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    private func change(_ operation: @escaping (Database) async throws -> Void) {
        guard let database = store.database else { return }
        let generation = store.profileGeneration
        saving = true
        Task {
            defer { saving = false }
            do {
                try await operation(database)
                guard !Task.isCancelled, generation == store.profileGeneration, store.database === database else { return }
                store.fightLessonsRevision += 1
                await reload()
            } catch {
                ErrorLog.record("Change fight scoring lesson", error.localizedDescription)
                guard generation == store.profileGeneration, store.database === database else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
