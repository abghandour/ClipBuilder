import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Bug reporting", .serialized)
struct BugReportingTests {
    private func makeStore(database: Database? = nil) -> AppStore {
        let settings = AppSettings()
        let profiles = [Fixtures.brand(name: "One"), Fixtures.brand(name: "Two")]
        return AppStore(settings: settings, profiles: profiles, active: profiles[0],
                        ai: AIService(config: settings.ai), database: database)
    }

    @Test("missing or empty plist keys leave reporting unconfigured", arguments: [0, 1, 2, 3])
    func missingConfiguration(_ variant: Int) throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        let info: [String: Any]
        switch variant {
        case 0: info = [:]
        case 1: info = ["VCIngestKey": "", "VCEndpoint": "https://example.invalid"]
        case 2: info = ["VCIngestKey": "test-placeholder", "VCEndpoint": ""]
        default: info = ["VCIngestKey": "  \n", "VCEndpoint": "  "]
        }
        // Intentionally no try: this entry point must remain nonthrowing.
        BugReporting.configureIfPossible(store: store, info: info)
        #expect(!BugReporting.isConfigured)
    }

    @Test("snapshot follows profile changes without exposing mutable store state")
    func profileContext() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        let before = store.bugReportContext.read()
        #expect(before.profile == "One")
        store.switchProfile(named: "Two")
        #expect(store.bugReportContext.read().profile == "Two")
        #expect(before.profile == "One")
        store.activeProfile.profileName = "Renamed"
        #expect(store.bugReportContext.read().profile == "Renamed")
    }

    @Test("snapshot follows real project selection and project rename")
    func projectContext() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let target = try await temp.database.createProject(profileName: "One", name: "Other")
        let store = makeStore(database: temp.database)
        await store.initializeProjectWorkspace()
        let home = try #require(try await temp.database.homeProjectID(profileName: "One"))
        await store.selectProject(home)?.value
        await store.selectProject(target)?.value
        #expect(store.bugReportContext.read().project == "Other")
        let index = try #require(store.projects.firstIndex { $0.id == target })
        store.projects[index].name = "Renamed project"
        #expect(store.bugReportContext.read().project == "Renamed project")
        store.selectedSection = .wizard
        #expect(store.bugReportContext.read().section == "wizard")
    }

    @Test("appendLog tees every channel and preserves the capped activity arrays")
    func logChannels() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        var received: [(String, String)] = []
        store.diagnosticLogSink = { received.append(($0, $1)) }
        let channels: [(ReferenceWritableKeyPath<AppStore, [String]>, String)] = [
            (\AppStore.analysisLog, "analysis"), (\AppStore.wizardLog, "wizard"),
            (\AppStore.builderLog, "builder"), (\AppStore.igLog, "instagram"),
            (\AppStore.pipelineLog, "pipeline"),
        ]
        for (keyPath, channel) in channels {
            store.appendLog(keyPath, ["\(channel) one", "\(channel) two"])
            #expect(store[keyPath: keyPath] == ["\(channel) one", "\(channel) two"])
        }
        #expect(received.map { $0.0 } == channels.flatMap { [$0.1, $0.1] })
        #expect(received.map { $0.1 } == channels.flatMap { ["\($0.1) one", "\($0.1) two"] })
        received = []
        let overflow = (0...AppStore.logLineCap).map(String.init)
        store.appendLog(\.analysisLog, overflow)
        #expect(store.analysisLog == Array(overflow.suffix(AppStore.logLineCap)))
        #expect(received.count == overflow.count)
    }

    @Test("context keeps the last three interleaved wizard and pipeline lines")
    func recentContext() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let store = makeStore()
        store.appendLog(\.wizardLog, ["old", "wizard"])
        store.appendLog(\.pipelineLog, ["pipeline"])
        store.appendLog(\.wizardLog, ["latest"])
        store.appendLog(\.builderLog, ["ffmpeg version fixture-version\nconfiguration: fixture"])
        #expect(store.bugReportContext.read().recentStatus == ["wizard", "pipeline", "latest"])
        #expect(store.bugReportContext.read().fields["ffmpegVersion"] == "ffmpeg version fixture-version")
    }

    @Test("Debug forces toolbar visibility; Release follows preference")
    func qaVisibility() {
        #expect(BugReporting.qaButtonVisible(preference: false, isDebug: true))
        #expect(BugReporting.qaButtonVisible(preference: true, isDebug: true))
        #expect(!BugReporting.qaButtonVisible(preference: false, isDebug: false))
        #expect(BugReporting.qaButtonVisible(preference: true, isDebug: false))
    }
}
