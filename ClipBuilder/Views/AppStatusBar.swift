import SwiftUI

/// Permanent window chrome, outside the split views so it cannot cover editing controls.
struct AppStatusBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("statusBar.logExpanded") private var logExpanded = false
    @AppStorage("statusBar.logChannel") private var channelFilter = ""
    @AppStorage("log.verbose") private var verboseLog = false

    private var lines: [AppLogLine] { AppLogChannels.lines(store.unifiedLog, channel: channelFilter) }
    private var activities: [StatusBarSummary.Activity] { StatusBarSummary.activities(store: store) }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // One always-visible toolbar: provider lights, the running
            // activity (or the latest log line), and the log controls.
            // Double-click opens the drawer with every activity and the log.
            header
            if store.wizardFailureMessage != nil {
                GenerationFailureNotice().padding(Theme.spaceS)
            }
            if let completion = store.analysisCompletion {
                AnalysisCompletionNotice(completion: completion).padding(Theme.spaceS)
            }
            if logExpanded {
                if activities.count > 1 {
                    Divider()
                    ScrollView {
                        VStack(spacing: Theme.spaceXS) {
                            ForEach(activities) { activity in
                                activityRow(activity)
                            }
                        }
                        .padding(.horizontal, Theme.spaceM)
                        .padding(.vertical, Theme.spaceXS)
                    }
                    .frame(height: min(CGFloat(activities.count) * 32 + 8, 136))
                }
                Divider()
                AppLogDrawer(lines: lines).frame(height: 200)
            }
        }
        .background(.bar)
        .onChange(of: store.googleDrive.revision) { store.refreshAll() }
        .onChange(of: store.googleDrive.jobs.map { "\($0.id):\($0.status.rawValue)" }) { old, _ in
            for job in store.googleDrive.jobs where !old.contains("\(job.id):\(job.status.rawValue)") {
                store.recordUnifiedLog(channel: "drive", text: "\(job.title): \(job.status.rawValue)")
            }
        }
        .onChange(of: store.builderWizard?.identityMatches) { _, matches in
            if matches == false, let model = store.builderWizard, !model.identityMatches { model.dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceS) {
            ProviderStatusRow(compact: true)
            Divider().frame(height: 16)
            if let first = activities.first {
                activityRow(first)
                    .frame(maxWidth: 560, alignment: .leading)
                if activities.count > 1 {
                    Text("+\(activities.count - 1)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help(activities.dropFirst().map { "\(AppLogChannels.title($0.channel)): \($0.detail)" }
                            .joined(separator: "\n") + "\nDouble-click to see every activity")
                        .accessibilityLabel("\(activities.count - 1) more activities")
                }
            } else {
                Text(StatusBarSummary(store: store).title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.spaceS)
            // Recovery actions appear only when something needs recovering;
            // an always-present menu that is usually empty reads as broken.
            recoveryActions
            Picker("App Log section", selection: $channelFilter) {
                Text("All sections").tag("")
                ForEach(AppLogChannels.available(in: store.unifiedLog, selection: channelFilter), id: \.self) { channel in
                    Text(AppLogChannels.title(channel)).tag(channel)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Filter log messages by section")
            Text("\(lines.count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Toggle("Verbose", isOn: $verboseLog)
                .toggleStyle(.checkbox)
                .help("Include the full AI prompt in logs")
            LogActions(lines: lines.map(AppLogDrawer.render)) { store.clearUnifiedLog(channel: channelFilter) }
            Button(logExpanded ? "Hide Log" : "Show Log",
                   systemImage: logExpanded ? "chevron.down" : "chevron.up", action: toggleLog)
                .help("Expand or collapse the App Log and every running activity. You can also double-click this bar.")
                .accessibilityValue(logExpanded ? "Expanded" : "Collapsed")
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.spaceM)
        // A fixed height: the bar sits in the window root, and a height that
        // depends on its own content can oscillate between layout passes and
        // trip AppKit's update-constraints guard.
        .frame(height: 32)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleLog)
        .accessibilityElement(children: .contain)
    }

    private func toggleLog() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { logExpanded.toggle() }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if !store.isPipelineRunning, !store.pipelineStage.isEmpty {
            if store.canResumePipeline {
                Button("Resume Pipeline") { store.resumePipeline() }
                    .help("Continue the stopped pipeline from where it left off")
            }
            Button("Dismiss Pipeline") { store.dismissPipelineBar() }
                .help("Clear the finished pipeline status")
        }
        if let status = store.igStatus, !status.running {
            Button("Dismiss Instagram") { store.dismissIGStatusBar() }
                .help("Clear the finished Instagram sync status")
        }
        if store.googleDrive.jobs.contains(where: { $0.status == .stopped || $0.status == .failed || $0.status == .reconnect }) {
            Menu("Transfers") {
                ForEach(store.googleDrive.jobs.filter { $0.status == .stopped || $0.status == .failed || $0.status == .reconnect }) { job in
                    Section(job.title) {
                        if job.status == .reconnect { OpenGoogleDriveSettingsButton() }
                        if !job.isAsset { Button("Resume") { store.googleDrive.resume(job.id) } }
                        Button("Dismiss") { store.googleDrive.cancel(job.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Resume or dismiss stopped Google Drive transfers")
        }
        if let model = store.builderWizard, model.hasStatus {
            Menu("Copy Wizard Details", systemImage: "doc.on.clipboard") {
                Button("Copy Tool Outcomes") { copy(model.copyText(kind: .toolOutcomes)) }
                Button("Copy Everything") { copy(model.copyText(kind: .everything)) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .labelStyle(.iconOnly)
            .help("Copy Builder Wizard outcomes or the complete run details")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func activityRow(_ activity: StatusBarSummary.Activity) -> some View {
        HStack(spacing: Theme.spaceS) {
            Text(AppLogChannels.title(activity.channel)).fontWeight(.medium)
            Text("\(activity.project) · \(activity.detail)").lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let progress = activity.progress {
                ProgressView(value: min(1, max(0, progress))).frame(width: 140)
                    .accessibilityLabel("\(activity.detail) progress")
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 36, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(activity.detail)
            }
            stopButton(activity)
        }
        .font(.caption)
        .controlSize(.small)
        .frame(height: 28)
    }

    @ViewBuilder
    private func stopButton(_ activity: StatusBarSummary.Activity) -> some View {
        switch activity.id {
        case "builder-wizard": Button("Stop") { store.builderWizard?.cancelRun() }
        case "pipeline": Button("Stop") { store.cancelPipeline() }
        case "analysis": Button("Stop") { store.cancelAnalysis() }
        case "builder": Button("Stop") { store.cancelBuilderRender() }
        case "wizard", "prefill": Button("Stop") { store.cancelWizard() }
        case "instagram-sync": Button("Stop") { store.cancelInstagramWork() }
        case "instagram-analysis": Button("Stop") {
            for id in store.igAnalyzingMediaIDs { store.cancelInstagramAnalysis(mediaID: id) }
        }
        case "transcription": Button("Stop") {
            for id in store.transcribingVideoIDs { store.cancelTranscription(videoID: id) }
        }
        default:
            if let job = store.googleDrive.jobs.first(where: { "drive-\($0.id)" == activity.id }) {
                Button("Stop") { store.googleDrive.stop(job.id) }
            }
        }
    }
}

/// Stable section names remain selectable even before the first message arrives.
enum AppLogChannels {
    static let known = ["app", "analysis", "wizard", "builder", "builder-wizard", "pipeline", "instagram", "instagram-analysis", "instagram-download", "instagram-reports", "builder-prefill", "builder-preview", "script-preview", "drive", "error"]

    static func title(_ channel: String) -> String {
        switch channel {
        case "app": "App"
        case "analysis": "Analysis"
        case "wizard": "Generation"
        case "builder": "Builder Render"
        case "builder-wizard": "Builder Wizard"
        case "pipeline": "Wizard Pipeline"
        case "instagram": "Instagram"
        case "instagram-analysis": "Instagram Analysis"
        case "instagram-download": "Instagram Downloads"
        case "instagram-reports": "Instagram Reports"
        case "builder-prefill": "Builder Pre-fill"
        case "builder-preview": "Builder Preview"
        case "script-preview": "Script Preview"
        case "drive": "Google Drive"
        case "error": "Errors"
        default: channel
        }
    }

    static func available(in lines: [AppLogLine], selection: String) -> [String] {
        Array(Set(known + lines.map(\.channel) + (selection.isEmpty ? [] : [selection])))
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    static func lines(_ lines: [AppLogLine], channel: String) -> [AppLogLine] {
        channel.isEmpty ? lines : lines.filter { $0.channel == channel }
    }
}

struct StatusBarSummary: Equatable {
    var title: String
    var detail: String?
    var symbol: String
    var tint: Color
    var busy: Bool
    var progress: Double?

    @MainActor
    init(store: AppStore) {
        if let first = Self.activities(store: store).first {
            title = "\(first.project) · \(first.detail)"
            detail = store.unifiedLog.last(where: { $0.channel == first.channel })?.text
            symbol = "circle.fill"; tint = Theme.createTint; busy = true; progress = first.progress
        } else {
            title = store.unifiedLog.last.map { "[\($0.channel)] \($0.text)" } ?? "Ready"
            detail = nil; symbol = "circle.fill"; tint = .secondary; busy = false; progress = nil
        }
    }

    struct Activity: Identifiable, Equatable {
        var id: String
        var channel: String
        var project: String
        var detail: String
        var progress: Double?
    }

    @MainActor
    static func activities(store: AppStore) -> [Activity] {
        var rows: [Activity] = []
        func add(_ id: String, _ channel: String, _ title: String, _ running: Bool,
                 progress: Double? = nil, project: String? = nil) {
            if running {
                rows.append(Activity(id: id, channel: channel, project: project ?? store.activeProject?.name ?? "Project",
                                     detail: title, progress: progress))
            }
        }
        add("builder-wizard", "builder-wizard", store.builderWizard?.statusText ?? "Running Wizard",
            store.builderWizard?.busy == true)
        add("pipeline", "pipeline", store.pipelineStage.isEmpty ? "Running pipeline" : store.pipelineStage,
            store.isPipelineRunning, progress: store.pipelineProgress)
        add("instagram-sync", "instagram", store.igStatus?.stage ?? "Syncing Instagram",
            store.igStatus?.running == true || store.isFetchingInstagram || store.isImportingPeaceGrappler,
            progress: store.igStatus?.fraction)
        add("builder", "builder", "Rendering timeline", store.isBuilderRendering, project: store.builderRenderProjectName)
        add("builder-preview", "builder-preview", "Rendering exact preview", store.isBuilderPreviewRendering)
        add("analysis", "analysis", store.analysisStage.isEmpty ? "Analyzing" : store.analysisStage,
            store.isAnalyzing, progress: store.analysisProgress, project: store.analysisProjectName)
        add("prefill", "builder-prefill", "Pre-filling Builder from template", store.isPlanningIntoBuilder)
        add("wizard", "wizard", store.wizardStatus?.stage ?? "Generating video",
            store.isWizardRunning && !store.isPlanningIntoBuilder, progress: store.wizardStatus?.fraction,
            project: store.wizardProjectName)
        add("manual-build-render", "wizard", "Rendering manual build", store.isManualBuildRendering)
        add("manual-build-preview", "wizard", "Rendering manual build preview", store.isManualBuildPreviewRendering)
        add("transcription", "analysis", "Transcribing \(store.transcribingVideoIDs.count) videos", !store.transcribingVideoIDs.isEmpty)
        add("people", "analysis", store.peopleDetectionStage ?? "Detecting people", store.isDetectingPeople)
        add("framing", "analysis", "Detecting framing", store.isDetectingFraming, progress: store.framingProgress)
        add("research", "analysis", "Researching fights", !store.fightResearchInFlight.isEmpty)
        add("scoring", "analysis", "Scoring fights", !store.fightScoringInFlight.isEmpty)
        add("instagram-analysis", "instagram-analysis", "Analyzing \(store.igAnalyzingMediaIDs.count) reels", !store.igAnalyzingMediaIDs.isEmpty)
        add("instagram-download", "instagram-download", "Downloading \(store.igDownloadingMediaIDs.count) reels", !store.igDownloadingMediaIDs.isEmpty)
        add("instagram-reports", "instagram-reports", "Building reports", store.isLoadingIGReport)
        add("instagram-connect", "instagram", "Connecting Instagram", store.isConnectingInstagram)
        add("instagram-publish", "instagram", "Publishing to Instagram", store.isPublishingToInstagram)
        add("taste", "instagram", "Learning from reels", store.isStudyingTaste)
        add("performance", "instagram", "Distilling performance lessons", store.isDistillingPerformanceLessons)
        add("lessons", "wizard", "Distilling lessons", store.isDistillingLessons)
        add("house-style", "wizard", "Distilling house style", store.isDistillingHouseStyle)
        add("script-preview", "script-preview", "Running JSON preview", store.isScriptPreviewRunning)
        add("project", "app", "Loading project", store.isLoadingProject)
        add("update", "app", "Downloading update", store.isDownloadingUpdate)
        add("tools", "analysis", "Installing tools", store.isInstallingTools || !store.installingProviderCLIs.isEmpty)
        for job in store.googleDrive.jobs where job.status == .running || job.status == .waiting {
            add("drive-\(job.id)", "drive", job.title, true,
                progress: job.totalBytes == nil ? nil : job.progress, project: job.projectName)
        }
        add("drive-connect", "drive", "Connecting Google Drive", !store.googleDrive.connecting.isEmpty)
        return rows
    }
}

private struct AppLogDrawer: View {
    @Environment(AppStore.self) private var store
    let lines: [AppLogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.spaceXS) {
                    if lines.isEmpty {
                        Text("No log entries in this section.").foregroundStyle(.secondary)
                            .padding(Theme.spaceS)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: Theme.spaceS) {
                            Text(Self.clock.string(from: line.time)).foregroundStyle(.secondary)
                            Text(AppLogChannels.title(line.channel)).foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            logText(line)
                        }
                        .font(.caption.monospaced())
                        .padding(.horizontal, Theme.spaceM)
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.spaceXS)
            }
            .onChange(of: lines.last?.id, initial: true) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func logText(_ line: AppLogLine) -> some View {
        if line.text.hasPrefix("VIDEO:"), let name = line.text.dropFirst(6).split(separator: ":").first {
            Button(String(name), systemImage: "play.rectangle") {
                if let url = store.generatedVideoURL(named: String(name)) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.plain)
            .help("Open generated video")
        } else {
            Text(line.text)
                .foregroundStyle(line.channel == "error" || line.text.hasPrefix("DONE:error") ? Color.red : .primary)
                .textSelection(.enabled)
        }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func render(_ line: AppLogLine) -> String {
        "\(clock.string(from: line.time)) [\(AppLogChannels.title(line.channel))] \(line.text)"
    }
}


/// A finished (or stopped) analysis stays visible until dismissed: the
/// Sources row of an already analyzed video looks the same before and after
/// a run, so the status bar says what happened and where to look.
private struct AnalysisCompletionNotice: View {
    @Environment(AppStore.self) private var store
    let completion: AppStore.AnalysisCompletion

    var body: some View {
        HStack(spacing: Theme.spaceS) {
            Label(completion.stopped ? "Analysis stopped" : completion.failed > 0 ? "Analysis finished with errors" : "Analysis finished",
                  systemImage: completion.stopped ? "stop.circle.fill" : completion.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(completion.stopped ? Color.secondary : completion.failed > 0 ? .orange : .green)
            Text(completion.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: Theme.spaceS)
            if !completion.stopped {
                Button("Open Scenes") {
                    store.selectedSection = .scenes
                    store.analysisCompletion = nil
                }
                .controlSize(.small)
                .help("Show the scenes and people this analysis produced")
            }
            Button("Dismiss") { store.analysisCompletion = nil }
                .controlSize(.small)
                .help("Hide this notice")
        }
        .accessibilityElement(children: .combine)
    }
}
