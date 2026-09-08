import AppKit
import BugReporterKit
import Foundation
import OSLog

@MainActor
enum BugReporting {
    private(set) static var isConfigured = false
    private(set) static var logDirectory: URL?
    static let unavailableMessage = "Bug reporting is not configured in this build"

    /// The override permits missing-key tests without configuring the process-wide kit.
    static func configureIfPossible(store: AppStore, info: [String: Any]? = nil) {
        startFieldDiagnostics()
        let info = info ?? Bundle.main.infoDictionary ?? [:]
        let key = (info["VCIngestKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = (info["VCEndpoint"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !endpoint.isEmpty,
              let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
            isConfigured = false
            Logger(subsystem: "com.mokotti-solutions.clipbuilder", category: "diagnostics")
                .notice("Bug reporting is not configured in this build")
            return
        }
        guard !isConfigured else { return }
        // AppStore.init has already resolved (and handled rejection of) the data folder.
        let directory = SettingsStore.dataDirectory.appendingPathComponent("logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            isConfigured = false
            Logger(subsystem: "com.mokotti-solutions.clipbuilder", category: "diagnostics")
                .error("Could not create the bug reporting log directory")
            return
        }
        store.diagnosticsDataFolder = homeRelative(SettingsStore.dataDirectory)
        store.updateBugReportContext()
        let snapshot = store.bugReportContext
        var config = BugReporterConfig(
            appID: "clipbuilder", ingestKey: key, endpoint: url, logDirectory: directory,
            identity: .optional, attachmentSources: [.files, .drop],
            captureScreenshotByDefault: true, pickUpCrashes: true
        )
        config.contextProvider = { snapshot.read().fields }
        config.redaction = config.redaction.appending([
            .init(name: "instagram-graph-token", pattern: #"\bIGQ[A-Za-z0-9._~+/=-]+"#,
                  template: "«redacted Instagram token»"),
            .init(name: "verticalcorn-header", pattern: #"(?i)\bX-VC-Key[\"']?\s*[:=]\s*[\"']?[^\s,;\"']+"#,
                  template: "X-VC-Key: «redacted»"),
            .init(name: "google-client-secret", pattern: #"\bGOCSPX-[A-Za-z0-9_-]+"#,
                  template: "«redacted Google client secret»"),
        ])
        // This host owns qa.toolbarButton. Never enable the kit's floating panel.
        // Discard a legacy/developer floating-panel preference before the kit reads it.
        UserDefaults.standard.removeObject(forKey: QAModeStore.enabledKey)
        BugReporter.configure(config)
        isConfigured = true
        logDirectory = directory
        let context = snapshot.read()
        BugReporter.log("app", "Launch version=\(context.version) build=\(context.build) dataFolder=\(context.dataFolder)")
        store.startBugReportObservation()
    }

    /// The main-thread watchdog and the click-timing monitor run in every
    /// build, configured kit or not: their output goes to the rolling log and
    /// the diagnostics folder that bug reports pick up, and to the unified
    /// log for a Console.app session. Idempotent.
    private static var fieldDiagnosticsStarted = false

    static func startFieldDiagnostics() {
        guard !fieldDiagnosticsStarted else { return }
        fieldDiagnosticsStarted = true
        UITiming.install()
        let directory = DiagnosticFiles.directory(
            under: SettingsStore.dataDirectory.appendingPathComponent("logs", isDirectory: true))
        MainThreadWatchdog.shared.start(directory: directory) { stall in
            let seconds = String(format: "%.2f", stall.duration)
            let sample = stall.sampleFile.map { " — sample: \($0.lastPathComponent)" }
                ?? (stall.duration >= 1 ? " — no sample captured" : "")
            BugReporter.log("hang", "Main thread stalled \(seconds) s\(sample)")
            Logger(subsystem: "com.mokotti-solutions.clipbuilder", category: "watchdog")
                .error("Main thread stalled \(seconds, privacy: .public) s\(sample, privacy: .public)")
        }
        // `-ClipBuilderSimulateStall 2` blocks the main thread for that many
        // seconds shortly after launch, to prove the watchdog end to end.
        let simulated = UserDefaults.standard.double(forKey: "ClipBuilderSimulateStall")
        if simulated > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                BugReporter.log("hang", "Simulating a \(simulated) s main-thread stall")
                Thread.sleep(forTimeInterval: simulated)
            }
        }
    }

    static func presentReport(title: String? = nil, details: String? = nil) {
        guard requireConfiguration() else { return }
        // Let the originating alert or sheet finish dismissing first.
        Task { @MainActor in
            await Task.yield()
            BugReporter.presentReportSheet(prefill: title.map { ReportPrefill(title: $0, error: details) })
        }
    }

    @discardableResult
    static func requireConfiguration() -> Bool {
        guard isConfigured else {
            showMessage(unavailableMessage)
            return false
        }
        return true
    }

    static func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func takeScreenshot() {
        guard requireConfiguration() else { return }
        let screenshots = ScreenshotStore.shared
        guard !screenshots.isFull else {
            showScreenshotLimit()
            return
        }
        guard let png = Snapshot.captureFrontWindowPNG() else {
            showMessage("Could not capture the front window")
            return
        }
        if !screenshots.add(png: png) { showScreenshotLimit() }
    }

    private static func showScreenshotLimit() {
        showMessage("\(ScreenshotStore.capacity) screenshots max")
    }

    static func revealLogFolder() {
        guard requireConfiguration(), let logDirectory else { return }
        NSWorkspace.shared.open(logDirectory)
    }

    nonisolated static func homeRelative(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    nonisolated static func qaButtonVisible(preference: Bool, isDebug: Bool) -> Bool {
        isDebug || preference
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func logChannel(for keyPath: ReferenceWritableKeyPath<AppStore, [String]>) -> String? {
        switch keyPath {
        case \AppStore.analysisLog: "analysis"
        case \AppStore.wizardLog: "wizard"
        case \AppStore.builderLog: "builder"
        case \AppStore.igLog: "instagram"
        case \AppStore.pipelineLog: "pipeline"
        default: nil
        }
    }

    static func logDriveChanges(from old: [DriveTransfer], to current: [DriveTransfer]) {
        let previous = Dictionary(old.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        for job in current where previous[job.id] != job.status {
            // No URL, error message, account identity, or token-bearing transfer metadata.
            BugReporter.log("drive", "\(job.title): \(job.status.rawValue)")
        }
    }
}
