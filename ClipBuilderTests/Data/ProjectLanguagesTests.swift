import Foundation
import Testing
@testable import Clip_Builder

struct ProjectLanguagesTests {
    @Test func inheritsEachEmptyListAndDeduplicates() {
        var profile = Fixtures.brand()
        profile.editing = ProfileEditingDefaults()
        profile.editing?.footage.language = "pt-BR"
        profile.editing?.footage.dubLanguage = "pt-BR"
        profile.captionLanguages = ["en"]
        profile.editing?.podcast.autoTranslateLanguage = "en"
        let inherited = ProjectLanguageResolver.resolve(project: nil, profile: profile)
        #expect(inherited == ProjectLanguages(spoken: ["pt-BR"], captions: ["en"], dub: ["pt-BR"]))
        let explicit = ProjectLanguageResolver.resolve(project: ProjectLanguages(spoken: ["en_US", "en-US"], dub: ["fr-FR"]), profile: profile)
        #expect(explicit == ProjectLanguages(spoken: ["en-US"], captions: ["en"], dub: ["fr-FR"]))
    }

    @Test func languageChoiceAndCandidateOrder() {
        #expect(ProjectLanguageResolver.transcriptionLanguage(languages: ProjectLanguages()) == "")
        #expect(ProjectLanguageResolver.transcriptionLanguage(languages: ProjectLanguages(spoken: ["pt-BR"])) == "pt-BR")
        #expect(ProjectLanguageResolver.transcriptionLanguage(languages: ProjectLanguages(spoken: ["pt-BR", "en-US"])) == "")
        #expect(ProjectLanguageResolver.podcastCandidates(["fr-FR", "pt_BR"]) == ["fr-FR", "pt-BR", "en-US"])
    }

    @Test func databaseRoundTripNilDuplicateAndSync() async throws {
        let temp = try await TempDatabase()
        let id = try await temp.database.createProject(profileName: "Test", name: "Languages")
        #expect(try await temp.database.fetchProjects().first?.languages == nil)
        let scope = SyncScope(teamID: UUID(), profileID: UUID())
        try await temp.database.bindSync(to: scope)
        let table = try #require(SyncTable.history.first { $0.name == "projects" })
        let initial = try await temp.database.pendingSyncChanges(scope: scope, limit: 100, table: table)
        try await temp.database.acknowledgeSyncChanges(initial)
        let languages = ProjectLanguages(spoken: ["pt-BR", "en-US"], captions: ["en"], dub: ["pt-BR"])
        try await temp.database.setProjectLanguages(id: id, languages: languages)
        #expect(try await temp.database.fetchProjects().first?.languages == languages)
        let changes = try await temp.database.pendingSyncChanges(scope: scope, limit: 100, table: table)
        #expect(changes.contains { change in
            guard case .string(let json) = change.wire["languages_json"] else { return false }
            return AISettingsJSON.decode(ProjectLanguages.self, json) == languages
        })
        let copy = try await temp.database.duplicateProject(id: id, profileName: "Test", name: "Copy")
        #expect(try await temp.database.fetchProjects().first { $0.id == copy }?.languages == languages)
        try await temp.database.setProjectLanguages(id: id, languages: nil)
        #expect(try await temp.database.fetchProjects().first { $0.id == id }?.languages == nil)
    }

    @Test func migratesVersion42() async throws {
        let directory = try TempDirectory(prefix: "LanguageMigration")
        let path = directory.url.appendingPathComponent("legacy.db")
        do {
            let raw = try SQLiteConnection(path: path.path)
            try raw.executeScript("""
                CREATE TABLE projects (id INTEGER PRIMARY KEY, profile_name TEXT NOT NULL, name TEXT NOT NULL,
                    created_at TEXT, last_opened_at TEXT, archived INTEGER DEFAULT 0, is_home INTEGER DEFAULT 0,
                    thumbnail_video_id INTEGER, ui_state_json TEXT);
                INSERT INTO projects (profile_name, name) VALUES ('Test', 'Legacy');
                PRAGMA user_version = 42;
                """)
        }
        let db = try Database(path: path)
        let project = try #require(try await db.fetchProjects().first)
        #expect(project.name == "Legacy")
        #expect(project.languages == nil)
        try await db.setProjectLanguages(id: project.id, languages: ProjectLanguages(spoken: ["pt-BR"]))
        #expect(try await db.fetchProjects().first?.languages?.spoken == ["pt-BR"])
    }
}
