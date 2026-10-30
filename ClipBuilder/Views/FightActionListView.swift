import SwiftUI

/// The scored actions behind one count in the inspector's Fight Action
/// section, as a wrapping grid of frames: one per strike, the start frame
/// per attempt with its end time. Pressing a frame plays that action on
/// repeat in the preview player.
struct FightActionListView: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord
    let events: [FightEventRecord]
    let fighterKey: String
    let category: FightScoreDigest.Category
    /// The entry currently looping, by id.
    let looping: Int64?
    let onPick: (FightScoreDigest.Entry) -> Void

    private var entries: [FightScoreDigest.Entry] {
        FightScoreDigest.entries(events: events, fighter: fighterKey, category: category)
    }

    private func name(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "" }
        return store.people.first { $0.key == key }?.displayName ?? key
    }

    private func timeBadge(_ entry: FightScoreDigest.Entry) -> String {
        if let end = entry.frameTimes.last, end != entry.time { return "\(entry.time.timecode)–\(end.timecode)" }
        return entry.time.timecode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name(fighterKey).isEmpty ? "Unattributed" : name(fighterKey)) · \(category.label.lowercased()) (\(entries.count))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("No scored \(category.label.lowercased()) for this fighter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            FlowLayout(spacing: 6) {
                ForEach(entries) { entry in
                    let active = looping == entry.id
                    Button {
                        onPick(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            VideoThumbnail(url: video.url, time: entry.time, cornerRadius: Theme.mediaRadius)
                                .frame(width: 96, height: 54)
                                .overlay(alignment: .bottomLeading) {
                                    MediaBadge(text: timeBadge(entry))
                                        .padding(Theme.spaceXS)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if active {
                                        Image(systemName: "repeat")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(2)
                                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Theme.chipRadius))
                                            .foregroundStyle(.white)
                                            .padding(Theme.spaceXS)
                                    }
                                }
                            Text(entry.summary)
                                .font(.caption2)
                                .foregroundStyle(active ? .primary : .secondary)
                                .lineLimit(2)
                                .frame(width: 96, alignment: .leading)
                        }
                        .padding(3)
                        .background(active ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help((active ? "Stop repeating" : "Play on repeat") + ": " + entry.summary
                          + ((entry.targetKey.map(name) ?? "").isEmpty ? "" : " on \(name(entry.targetKey))")
                          + " (\(timeBadge(entry)))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
