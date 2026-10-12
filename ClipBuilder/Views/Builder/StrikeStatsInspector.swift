import SwiftUI

struct StrikeStatsInspector: View {
    @Environment(AppStore.self) private var store
    let item: TextOverlayItem

    var body: some View {
        if let stat = item.stat {
            VStack(alignment: .leading, spacing: 8) {
                Label("AI-scored", systemImage: "sparkles").font(.caption)
                Text(StrikeStatsCopy.scope(stat.scope)).font(.caption).foregroundStyle(.secondary)
                if StrikeStatSourceBinding.mapped(item, clips: store.builder.document.videoTrack,
                                                  scenes: store.scenes, videos: store.videos).isEmpty {
                    Label("Source not on timeline", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text((stat.states ?? []).map(\.rawValue).joined(separator: " · ")).font(.caption)
                Picker("Fighter", selection: fighterBinding) {
                    Text("Both fighters").tag("")
                    ForEach(stat.values?.fighters ?? [], id: \.key) { fighter in
                        Text(fighter.name ?? "Unattributed").tag(fighter.key ?? "")
                    }
                }
                .help("Show both fighters or one fighter's offense and defense")
                Picker("Rows", selection: kindBinding) {
                    Text("Takedowns and submissions").tag("")
                    ForEach(AttemptKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .help("Choose which grappling rows appear on the card")
                Picker("Units", selection: unitBinding) {
                    ForEach(StrikeStatPayload.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Saved unit preference; count cards have no speed estimates")
                Text(StrikeStatsCopy.text(stat)).font(.caption).textSelection(.enabled)
                Button("Refresh from analysis") { store.refreshStrikeStats(item) }
                    .lineLimit(1).fixedSize()
                    .help("Replace this card's saved numbers using current source analysis")
                Text("Editing the text detaches the counts and removes the AI-scored badge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fighterBinding: Binding<String> {
        Binding(get: { item.stat?.fighterKey ?? "" }, set: { key in
            guard var stat = item.stat else { return }
            stat.fighterKey = key.isEmpty ? nil : key
            store.builder.updateStat(item.uid, payload: stat)
        })
    }
    private var kindBinding: Binding<String> {
        Binding(get: { item.stat?.attemptKind?.rawValue ?? "" }, set: { key in
            guard var stat = item.stat else { return }
            stat.attemptKind = AttemptKind(rawValue: key)
            store.builder.updateStat(item.uid, payload: stat)
        })
    }
    private var unitBinding: Binding<StrikeStatPayload.Unit> {
        Binding(get: { item.stat?.unit ?? .kmh }, set: { unit in
            guard var stat = item.stat else { return }
            stat.unit = unit
            store.builder.updateStat(item.uid, payload: stat)
        })
    }
}
