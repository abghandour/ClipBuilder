import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("App status bar")
struct AppStatusBarTests {
    private func makeStore() -> AppStore {
        let profile = Fixtures.brand(name: "One")
        return AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                        ai: AIService(config: AIConfig()))
    }

    @Test("every log channel lands in the unified log, split by line and capped")
    func unifiedLog() {
        let store = makeStore()
        var forwarded: [(String, String)] = []
        store.diagnosticLogSink = { forwarded.append(($0, $1)) }
        store.appendLog(\.analysisLog, ["Extracting frames", "  ", "line one\nline two"])
        store.logEvent("app", "Project switched: Home")
        store.recordUnifiedLog(channel: "wizard", text: "\n")
        #expect(store.unifiedLog.map(\.channel) == ["analysis", "analysis", "analysis", "app"])
        #expect(store.unifiedLog.map(\.text) == ["Extracting frames", "line one", "line two", "Project switched: Home"])
        // The diagnostic file still gets every raw line (blank ones included);
        // only the in-app log is split and trimmed.
        #expect(forwarded.map(\.0) == ["analysis", "analysis", "analysis", "app"])
        #expect(store.unifiedLog.map(\.id) == Array(1...4))

        for index in 0..<(AppStore.unifiedLogLimit + 5) {
            store.recordUnifiedLog(channel: "pipeline", text: "line \(index)")
        }
        #expect(store.unifiedLog.count == AppStore.unifiedLogLimit)
        #expect(store.unifiedLog.last?.text == "line \(AppStore.unifiedLogLimit + 4)")
        store.clearUnifiedLog()
        #expect(store.unifiedLog.isEmpty)
    }

    @Test("the status line prefers running work, then the newest log line, then Ready")
    func summaryPriority() {
        let store = makeStore()
        store.diagnosticLogSink = { _, _ in }
        #expect(StatusBarSummary(store: store).title == "Ready")
        #expect(!StatusBarSummary(store: store).busy)

        store.logEvent("app", "Project switched: Home")
        #expect(StatusBarSummary(store: store).title == "[app] Project switched: Home")

        store.isAnalyzing = true
        store.analysisStage = "tagging (30 frames)"
        let analyzing = StatusBarSummary(store: store)
        #expect(analyzing.busy && analyzing.title.contains("tagging (30 frames)"))
        // Starting analysis logs "Analysis start", which becomes the detail line.
        #expect(analyzing.detail == "Analysis start")

        store.pipelineStage = "rendering"
        store.isPipelineRunning = true
        store.pipelineProgress = 0.5
        let pipeline = StatusBarSummary(store: store)
        #expect(pipeline.title.contains("rendering") && pipeline.progress == 0.5 && pipeline.busy)

        store.isPipelineRunning = false
        let stopped = StatusBarSummary(store: store)
        #expect(stopped.title.contains("tagging (30 frames)") && stopped.busy)
        store.pipelineStage = ""
        store.isAnalyzing = false
        // Ending analysis logs "Analysis end", so that is the newest line.
        let idle = StatusBarSummary(store: store)
        #expect(idle.title.hasPrefix("[analysis] Analysis end") && !idle.busy)
    }

    @Test("section filtering and clearing preserve unrelated messages and future entries")
    func sectionFiltering() {
        let store = makeStore()
        store.diagnosticLogSink = { _, _ in }
        store.appendLog(\.wizardLog, ["Generation"])
        store.recordUnifiedLog(channel: "builder-wizard", text: "Editing")
        store.appendLog(\.igLog, ["Downloading"], channel: "instagram-download")
        #expect(AppLogChannels.lines(store.unifiedLog, channel: "wizard").map(\.text) == ["Generation"])
        #expect(AppLogChannels.lines(store.unifiedLog, channel: "builder-wizard").map(\.text) == ["Editing"])
        store.clearUnifiedLog(channel: "builder-wizard")
        #expect(store.unifiedLog.map(\.text) == ["Generation", "Downloading"])
        store.recordUnifiedLog(channel: "builder-wizard", text: "Next edit")
        #expect(AppLogChannels.lines(store.unifiedLog, channel: "builder-wizard").map(\.text) == ["Next edit"])
        #expect(AppLogChannels.available(in: [], selection: "custom").contains("custom"))
        #expect(AppLogChannels.available(in: [], selection: "").contains("instagram-reports"))
    }

    @Test("finished status cannot hide simultaneous activity, including previews and downloads")
    func simultaneousActivity() {
        let store = makeStore()
        store.diagnosticLogSink = { _, _ in }
        let wizard = WizardSheetModel(store: store)
        wizard.appendLog("Finished Wizard run")
        store.builderWizard = wizard
        store.pipelineStage = "done"
        store.igStatus = AppStore.IGSyncStatus(title: "Instagram", stage: "done", fraction: 1, running: false)
        store.isBuilderPreviewRendering = true
        store.igDownloadingMediaIDs = [42]
        store.isAnalyzing = true
        store.analysisProgress = 0.25
        let activities = StatusBarSummary.activities(store: store)
        #expect(activities.contains { $0.id == "builder-preview" && $0.progress == nil })
        #expect(activities.contains { $0.id == "instagram-download" })
        #expect(activities.contains { $0.id == "analysis" && $0.progress == 0.25 })
        #expect(!activities.contains { $0.id == "builder-wizard" || $0.id == "pipeline" || $0.id == "instagram-sync" })
        #expect(StatusBarSummary(store: store).busy)
        store.isBuilderPreviewRendering = false
        store.igDownloadingMediaIDs = []
        store.isAnalyzing = false
        #expect(!StatusBarSummary.activities(store: store).contains { ["builder-preview", "instagram-download", "analysis"].contains($0.id) })
    }

    @Test("operation channels do not change the diagnostic log destination")
    func sectionDiagnostics() {
        let store = makeStore()
        var channels: [String] = []
        store.diagnosticLogSink = { channel, _ in channels.append(channel) }
        store.appendLog(\.igLog, ["Analyze reel"], channel: "instagram-analysis")
        store.appendLog(\.igLog, ["Download reel"], channel: "instagram-download")
        #expect(channels == ["instagram", "instagram"])
        #expect(store.unifiedLog.map(\.channel) == ["instagram-analysis", "instagram-download"])
        #expect(store.igLog == ["Analyze reel", "Download reel"])
    }

}
