import SwiftUI

struct EditingPerformanceView: View {
    @Environment(AppStore.self) private var store
    @State private var insights: EditingPerformanceInsights?
    @State private var athleteMetric = "Reach"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceL) {
            if let insights {
                SectionCard(title: "Suggested Setup", subtitle: "Learned from linked published reels") {
                    Button("Export Reports as CSV…", systemImage: "tablecells", action: exportCSV)
                    LabeledContent("Hook", value: insights.suggestedHook ?? "Not enough data")
                    LabeledContent("Screen type", value: insights.suggestedLayout ?? "Not enough data")
                    LabeledContent("Cadence") {
                        if let cadence = insights.suggestedCadence {
                            Text("\(cadence.formatted(.number.precision(.fractionLength(1)))) cuts/min")
                        } else {
                            Text("Not enough data")
                        }
                    }
                    Toggle(
                        "Feed winners into this profile's standard setup",
                        isOn: Binding(
                            get: { store.activeProfile.useLearnedEditingDefaults },
                            set: { enabled in
                                store.activeProfile.useLearnedEditingDefaults = enabled
                                if enabled {
                                    store.applyLearnedEditingDefaults(insights)
                                } else {
                                    store.saveActiveProfile()
                                }
                            }))
                    if store.activeProfile.useLearnedEditingDefaults {
                        Label(
                            "Learned from your results: \(store.activeProfile.learnedHookStyle), \(store.activeProfile.learnedLayoutPreference), \(store.activeProfile.defaultPacing.cadence.label)",
                            systemImage: "chart.line.uptrend.xyaxis"
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                SectionCard(title: "Athlete Return", subtitle: "Per appearance; choose the ranking metric") {
                    Picker("Rank by", selection: $athleteMetric) {
                        ForEach(
                            ["Reach", "Views", "Watch Time", "Shares", "Saves", "Comments", "Followers"], id: \.self
                        ) {
                            Text($0).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow {
                            Text("Athlete")
                            Text("Apps")
                            Text(athleteMetric)
                            Text("Reach / app")
                        }.foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(sortedAthletes(insights.athletes)) { athlete in
                            GridRow {
                                Text(athlete.name)
                                Text(athlete.appearances.formatted()).monospacedDigit()
                                Text(metricValue(athlete).formatted(.number.precision(.fractionLength(1))))
                                    .monospacedDigit()
                                Text(athlete.reach.formatted(.number.precision(.fractionLength(0))))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                SectionCard(title: "Hook, Screen & Cadence Performance") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                        GridRow {
                            Text("Dimension")
                            Text("Variant")
                            Text("Reels")
                            Text("Avg watch")
                            Text("Avg reach")
                        }
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(insights.patterns) { pattern in
                            GridRow {
                                Text(pattern.dimension)
                                Text(pattern.value)
                                Text(pattern.reels.formatted()).monospacedDigit()
                                Text(pattern.averageWatchTime.formatted(.number.precision(.fractionLength(1))))
                                Text(pattern.averageReach.formatted(.number.precision(.fractionLength(0))))
                            }
                        }
                    }
                }
            } else {
                ProgressView("Calculating editing performance…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let database = store.database else { return }
        let traits = (try? await database.fetchGeneratedTraits()) ?? [:]
        let result = PerformanceAnalytics.build(
            videos: store.generatedVideos, traits: traits,
            people: store.people,
            followersGained: store.igReport?.overview.newFollowersTotal ?? 0)
        insights = result
        if store.activeProfile.useLearnedEditingDefaults { store.applyLearnedEditingDefaults(result) }
    }

    private func metricValue(_ athlete: EditingPerformanceInsights.Athlete) -> Double {
        switch athleteMetric {
        case "Views": athlete.views
        case "Watch Time": athlete.watchTime
        case "Shares": athlete.shares
        case "Saves": athlete.saves
        case "Comments": athlete.comments
        case "Followers": athlete.followersGained
        default: athlete.reach
        }
    }

    private func sortedAthletes(_ athletes: [EditingPerformanceInsights.Athlete]) -> [EditingPerformanceInsights
        .Athlete]
    {
        athletes.sorted { metricValue($0) > metricValue($1) }
    }

    private func exportCSV() {
        guard let insights, let database = store.database else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let folder = root.appending(path: "ClipBuilder-Reports", directoryHint: .isDirectory)
        Task {
            do {
                let traits = try await database.fetchGeneratedTraits()
                _ = try ReportCSVExporter.export(
                    directory: folder, videos: store.generatedVideos,
                    traits: traits, report: store.igReport,
                    insights: insights)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch { store.presentError("Could not export CSV reports", error) }
        }
    }
}
