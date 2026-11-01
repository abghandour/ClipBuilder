import SwiftUI

/// Side-by-side numbers for the renders of one hook comparison: Instagram
/// stats per opening (dashes when unpublished), the A/B pick if any, and a
/// fixed caveat that organic posts are not a randomized test. No winner is
/// declared. Opened from a Library card ("Compare hooks") and as the hook
/// job's review sheet.
struct HookVariantReadout: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let groupID: String
    /// Set when shown as a job review; Done clears the job.
    var jobID: UUID? = nil
    var alternatives: [HookAlternative] = []
    var provenance: AIProvenance? = nil

    @State private var preferences: [(chosenID: Int64, rejectedID: Int64)] = []

    private var videos: [GeneratedVideoRecord] { store.hookVariantVideos(groupID: groupID) }
    private var rows: [HookVariantBuilder.ReadoutRow] {
        HookVariantBuilder.readout(videos: videos, preferences: preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack(spacing: 8) {
                Text("Hook comparison")
                    .font(.headline)
                if let provenance {
                    AIInfoButton(provenance: provenance, style: .full, role: "Hooks by")
                }
            }
            Text("The same reel with different openings. Everything after the first seconds is identical.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("These renders are no longer in the Library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                table
            }

            Text(HookVariantBuilder.readoutCaveat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Pick a Favorite…", systemImage: "rectangle.split.3x1") {
                    let groupID = groupID
                    close()
                    store.queueHookComparison(groupID: groupID)
                }
                .disabled(videos.count < 2)
                .help("Watch the openings side by side and record which one you prefer")
                Spacer()
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 700)
        .modalCloseButton { close() }
        .task(id: store.generatedVideos.map(\.id)) {
            preferences = await store.hookPreferences(groupID: groupID)
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.spaceM, verticalSpacing: Theme.spaceS) {
            GridRow {
                ForEach(["Opening", "Views", "Reach", "Likes", "Saves", "Avg watch", "Your pick"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider()
            ForEach(rows) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.callout.weight(.medium)).lineLimit(1)
                        if let reason = alternatives.first(where: { $0.label == row.label })?.reason {
                            Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        } else if !row.published {
                            Text("Not published").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                    number(row.stats?.views)
                    number(row.stats?.reach)
                    number(row.stats?.likes)
                    number(row.stats?.saves)
                    Text(row.stats?.avgWatchTime.map { String(format: "%.1f s", $0) } ?? "—")
                        .monospacedDigit().lineLimit(1)
                    Text(row.picks > 0 ? (row.picks == 1 ? "Picked" : "Picked ×\(row.picks)") : "—")
                        .foregroundStyle(row.picks > 0 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map { $0.formatted() } ?? "—")
            .monospacedDigit()
            .lineLimit(1)
    }

    private func close() {
        if let jobID { store.jobs.markReviewed(jobID) }
        dismiss()
    }
}
