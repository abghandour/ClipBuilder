import SwiftUI

/// Window-wide strip for background work (rendering, analysis, pipeline,
/// planning Wizard, Drive jobs). Present only while there is something to
/// show; the Drive revision observer stays mounted so refreshes keep firing.
struct ActivityStatusInset: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if !isIdle {
                VStack(spacing: 0) {
                    Divider()
                    HStack(alignment: .top, spacing: Theme.spaceM) {
                        Circle()
                            .fill(Theme.createTint)
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                            .accessibilityLabel("Busy")
                        VStack(alignment: .leading, spacing: Theme.spaceXS) {
                            ForEach(activities) { activity in
                                HStack(spacing: Theme.spaceS) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text(activity.project)
                                        .bold()
                                    Text("· \(activity.detail)")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .help("\(activity.project): \(activity.detail)")
                            }
                            DriveActivityRows()
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .onChange(of: store.googleDrive.revision) { store.refreshAll() }
    }

    private var isIdle: Bool {
        activities.isEmpty && store.googleDrive.jobs.allSatisfy { $0.status == .complete }
    }

    private var activities: [ProjectActivity] {
        var rows: [ProjectActivity] = []
        if store.isBuilderRendering {
            rows.append(
                ProjectActivity(
                    id: "builder",
                    project: store.builderRenderProjectName ?? "Project",
                    detail: "Rendering timeline"
                ))
        }
        if store.isAnalyzing {
            rows.append(
                ProjectActivity(
                    id: "analysis",
                    project: store.analysisProjectName ?? "Project",
                    detail: store.analysisStage.isEmpty ? "Analyzing" : store.analysisStage
                ))
        }
        if store.isPipelineRunning {
            rows.append(
                ProjectActivity(
                    id: "pipeline",
                    project: store.pipelineProjectName ?? "Project",
                    detail: store.pipelineStage.isEmpty ? "Running pipeline" : store.pipelineStage
                ))
        }
        if store.isWizardRunning, let status = store.wizardStatus {
            rows.append(
                ProjectActivity(
                    id: "wizard",
                    project: store.wizardProjectName ?? "Project",
                    detail: status.stage
                ))
        }
        return rows
    }
}

private struct ProjectActivity: Identifiable {
    let id: String
    let project: String
    let detail: String
}
