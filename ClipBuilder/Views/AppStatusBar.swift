import SwiftUI

/// The permanent strip at the bottom of the window: one line that always
/// says what the app is doing, the controls for the work in progress, and
/// a drawer with every log line the app produces. It is laid out as part of
/// the window, never as an inset, so no screen can paint underneath it.
struct AppStatusBar: View {
    @Environment(AppStore.self) private var store
    @AppStorage("statusBar.logExpanded") private var logExpanded = false
    @AppStorage("statusBar.logChannel") private var channelFilter = ""
    @State private var showWizardLog = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            statusRow
            if logExpanded {
                Divider()
                AppLogDrawer(channelFilter: $channelFilter)
                    .frame(height: 200)
            }
        }
        .background(.bar)
        .sheet(isPresented: $showWizardLog) { BuilderWizardLogSheet() }
        // Drive refreshes used to ride on the activity strip; keep them firing.
        .onChange(of: store.googleDrive.revision) { store.refreshAll() }
        .onChange(of: store.builderWizard?.identityMatches) { _, matches in
            if matches == false, let model = store.builderWizard, !model.identityMatches { model.dismiss() }
        }
    }

    private var summary: StatusBarSummary { StatusBarSummary(store: store) }

    private var statusRow: some View {
        let summary = summary
        return HStack(spacing: 10) {
            Image(systemName: summary.symbol)
                .foregroundStyle(summary.tint)
                .accessibilityHidden(true)
            if summary.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Busy")
            }
            Text(summary.title)
                .font(.caption)
                .lineLimit(1)
                .layoutPriority(1)
            if let progress = summary.progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
            }
            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            contextActions
            Button(logExpanded ? "Hide Log" : "Log",
                   systemImage: logExpanded ? "chevron.down" : "chevron.up") {
                withAnimation(.easeInOut(duration: 0.15)) { logExpanded.toggle() }
            }
            .help(logExpanded ? "Hide the app log" : "Show every log line the app produced")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status: \(summary.title)")
    }

    /// Controls for whichever work owns the status line.
    @ViewBuilder
    private var contextActions: some View {
        if store.isPipelineRunning {
            Button("Stop", systemImage: "stop.circle") { store.cancelPipeline() }
                .help("Stop the Wizard Pipeline run — finished steps are kept and Resume picks up from here")
        } else if !store.pipelineStage.isEmpty {
            if store.canResumePipeline {
                Button("Resume", systemImage: "play.circle") { store.resumePipeline() }
                    .buttonStyle(.borderedProminent)
                    .help("Continue the stopped run — finished steps are skipped")
            }
            Button("Pipeline Log") { store.showPipelineLog = true }
                .help("The full Wizard Pipeline log")
            Button("Clear") { store.dismissPipelineBar() }
                .help("Clear the finished run from the status line (its log and resume point go with it)")
        }
        if let status = store.igStatus {
            if status.running {
                Button("Stop", systemImage: "stop.circle") { store.cancelInstagramWork() }
                    .help("Stop — finished steps are kept and the next run resumes from its checkpoints")
            } else {
                Button("Instagram Log") { store.showIGLog = true }
                    .help("The full Instagram sync log")
                Button("Clear") { store.dismissIGStatusBar() }
                    .help("Clear the finished run from the status line")
            }
        }
        if let model = store.builderWizard, model.hasStatus {
            Button("Wizard Log") { showWizardLog = true }
                .help("The Builder Wizard log with copy and clear controls")
        }
    }
}

/// What the status line says, resolved from the store in priority order:
/// the Builder Wizard, a pipeline run, an Instagram run, background work,
/// then the newest log line, then "Ready".
struct StatusBarSummary: Equatable {
    var title: String
    var detail: String?
    var symbol: String
    var tint: Color
    var busy: Bool
    var progress: Double?

    @MainActor
    init(store: AppStore) {
        let activities = StatusBarSummary.activities(store: store)
        if let wizard = store.builderWizard, wizard.hasStatus {
            self.init(title: wizard.statusText, detail: wizard.latestLogLine,
                      symbol: "wand.and.stars", tint: Theme.createTint,
                      busy: wizard.busy, progress: nil)
        } else if store.isPipelineRunning || !store.pipelineStage.isEmpty {
            let stage = store.pipelineStage
            self.init(title: stage.isEmpty ? "Wizard Pipeline" : "Wizard Pipeline — \(stage)",
                      detail: store.pipelineLog.last, symbol: "wand.and.rays", tint: Theme.createTint,
                      busy: store.isPipelineRunning, progress: store.pipelineProgress)
        } else if let status = store.igStatus {
            self.init(title: status.stage.isEmpty ? status.title : "\(status.title) — \(status.stage)",
                      detail: status.running ? store.igLog.last : nil,
                      symbol: "play.rectangle.on.rectangle", tint: Theme.instagramTint,
                      busy: status.running, progress: status.fraction)
        } else if let first = activities.first {
            let more = activities.count > 1 ? " · \(activities.count - 1) more" : ""
            self.init(title: "\(first.project) · \(first.detail)\(more)",
                      detail: store.unifiedLog.last?.text, symbol: "circle.fill", tint: Theme.createTint,
                      busy: true, progress: nil)
        } else {
            self.init(title: store.unifiedLog.last.map { "[\($0.channel)] \($0.text)" } ?? "Ready",
                      detail: nil, symbol: "circle.fill", tint: .secondary, busy: false, progress: nil)
        }
    }

    init(title: String, detail: String?, symbol: String, tint: Color, busy: Bool, progress: Double?) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.busy = busy
        self.progress = progress
    }

    struct Activity: Equatable {
        var project: String
        var detail: String
    }

    /// Background work in progress, one row each, in the order the old
    /// activity strip listed them.
    @MainActor
    static func activities(store: AppStore) -> [Activity] {
        var rows: [Activity] = []
        if store.isBuilderRendering {
            rows.append(Activity(project: store.builderRenderProjectName ?? "Project", detail: "Rendering timeline"))
        }
        if store.isAnalyzing {
            rows.append(Activity(project: store.analysisProjectName ?? "Project",
                                 detail: store.analysisStage.isEmpty ? "Analyzing" : store.analysisStage))
        }
        if store.isWizardRunning, let status = store.wizardStatus {
            rows.append(Activity(project: store.wizardProjectName ?? "Project", detail: status.stage))
        }
        let uploads = store.googleDrive.jobs.filter { $0.status != .complete }
        if !uploads.isEmpty {
            rows.append(Activity(project: "Google Drive", detail: uploads.count == 1
                                 ? (uploads[0].title) : "\(uploads.count) transfers"))
        }
        return rows
    }
}

/// The unified log: every channel, filterable, newest at the bottom.
private struct AppLogDrawer: View {
    @Environment(AppStore.self) private var store
    @Binding var channelFilter: String

    private var channels: [String] {
        Array(Set(store.unifiedLog.map(\.channel))).sorted()
    }

    private var lines: [AppLogLine] {
        channelFilter.isEmpty ? store.unifiedLog : store.unifiedLog.filter { $0.channel == channelFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spaceS) {
                Text("App Log").font(.caption).bold()
                Picker("Channel", selection: $channelFilter) {
                    Text("All channels").tag("")
                    ForEach(channels, id: \.self) { channel in
                        Text(channel).tag(channel)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .help("Show one channel of the log")
                Text("\(lines.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                LogActions(lines: lines.map(AppLogDrawer.render), clear: store.clearUnifiedLog)
                DriveActivityRows()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if lines.isEmpty {
                            Text("No log entries yet.")
                                .foregroundStyle(.secondary)
                                .padding(Theme.spaceS)
                        }
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: Theme.spaceS) {
                                Text(AppLogDrawer.clock.string(from: line.time))
                                    .foregroundStyle(.tertiary)
                                Text(line.channel)
                                    .foregroundStyle(line.channel == "error" ? Color.red : .secondary)
                                    .frame(width: 64, alignment: .leading)
                                Text(line.text)
                                    .textSelection(.enabled)
                            }
                            .font(.caption.monospaced())
                            .padding(.horizontal, 12)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear {
                    if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func render(_ line: AppLogLine) -> String {
        "\(clock.string(from: line.time)) [\(line.channel)] \(line.text)"
    }
}
