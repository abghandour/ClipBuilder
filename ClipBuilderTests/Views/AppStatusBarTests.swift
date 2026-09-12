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
        #expect(pipeline.title == "Wizard Pipeline — rendering" && pipeline.progress == 0.5 && pipeline.busy)

        store.isPipelineRunning = false
        let stopped = StatusBarSummary(store: store)
        #expect(stopped.title == "Wizard Pipeline — rendering" && !stopped.busy)
        store.pipelineStage = ""
        store.isAnalyzing = false
        // Ending analysis logs "Analysis end", so that is the newest line.
        let idle = StatusBarSummary(store: store)
        #expect(idle.title.hasPrefix("[analysis] Analysis end") && !idle.busy)
    }
}
