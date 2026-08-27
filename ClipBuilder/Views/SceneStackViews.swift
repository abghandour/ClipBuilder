import SwiftUI

/// Dropdown controlling how aggressively similar scenes group into stacks.
/// Backed by one shared `@AppStorage` key, so changing it on any surface
/// (Raw Scenes, Builder browser, Curated, People) changes it everywhere.
struct SceneStackLevelPicker: View {
    /// Compact renders as a stack-icon menu for dense filter bars; the
    /// default is a plain labeled Picker (a submenu inside toolbar menus).
    var compact = false

    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue

    private var level: SceneStackLevel { .from(stackLevelRaw) }

    var body: some View {
        Group {
            if compact {
                Menu {
                    picker
                        .pickerStyle(.inline)
                        .labelsHidden()
                } label: {
                    Label(level == .off ? "Group" : level.label,
                          systemImage: level == .off ? "square.stack.slash" : "square.stack")
                }
                .fixedSize()
            } else {
                picker
            }
        }
        .help("Collapse takes of the same moment into one stacked card — Light groups only takes seconds apart, Aggressive merges a wider window, Off shows every scene. Applies everywhere scenes are listed.")
    }

    private var picker: some View {
        Picker("Group Similar Scenes", selection: $stackLevelRaw) {
            ForEach(SceneStackLevel.allCases) { level in
                Text(level.label).tag(level.rawValue)
            }
        }
    }
}

/// The "this card is a stack" indicator: member count on a stack icon.
/// With an action it doubles as the button that opens the stack picker.
struct SceneStackBadge: View {
    /// Total takes in the stack (the fronting one included).
    let count: Int
    /// The top take is the user's remembered pick (vs the AI's default).
    let userPicked: Bool
    var compact = false
    /// Opens the stack picker; nil renders a passive badge.
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .help("\(count) similar scenes around the same moment — "
              + (userPicked ? "your pick is on top. " : "the AI's pick is on top. ")
              + "Choose a different one from the stack's context menu"
              + (action != nil ? " or by clicking this badge" : ""))
    }

    private var label: some View {
        Label("\(count)", systemImage: "square.stack")
            .font(compact ? .badgeCompact : .caption2.bold())
            .padding(3)
            .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.chipRadius))
            .foregroundStyle(.white)
    }
}

extension View {
    /// Deck-of-cards chrome for a card fronting a stack: sheet edges
    /// peeking out below. Layer it behind the card's own background.
    func sceneStackDeck(count: Int) -> some View {
        background {
            if count > 1 {
                ForEach(1..<min(3, count), id: \.self) { layer in
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .fill(.background.secondary)
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(.quaternary))
                        .padding(.horizontal, CGFloat(layer) * 5)
                        .offset(y: CGFloat(layer) * 4)
                        .opacity(layer == 1 ? 0.8 : 0.5)
                }
            }
        }
    }
}

/// The stack picker popup (long-press or context menu on a stacked card):
/// every take of the moment side by side, the current best first. Click a
/// take's player to watch it inline; "Use as Best" puts it on top of the
/// stack and the choice is remembered.
struct SceneStackPicker: View {
    /// Stack members in display order — the current best fronts the list.
    let members: [SceneRecord]
    let onPick: (SceneRecord) -> Void
    let onPreview: (SceneRecord) -> Void

    /// What the AI would put on top, shown even when the user overrode it
    /// so they can find their way back to it.
    private var aiBestID: Int64? { SceneStacks.aiBest(of: members)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(members.count) Similar Scenes")
                    .font(.headline)
                Text("Takes of the same moment — the best one fronts the stack. Click a take to watch it, then Use as Best to put it on top. Your pick is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.spaceM, alignment: .top)],
                          spacing: Theme.spaceM) {
                    ForEach(members) { member in
                        memberCell(member)
                    }
                }
            }
            .frame(maxHeight: 460)
        }
        .padding(Theme.spaceL)
        .frame(width: 520)
    }

    private func memberCell(_ member: SceneRecord) -> some View {
        let isTop = member.id == members.first?.id
        return VStack(alignment: .leading, spacing: 6) {
            SceneInlinePlayer(scene: member)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if let score = member.score {
                        ScoreBadge(score: score)
                            .padding(4)
                            .allowsHitTesting(false)
                            .help(member.narrative ?? "Entertainment score")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: member.duration)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if member.stackChoice || member.id == aiBestID {
                        Label(member.stackChoice ? "YOUR PICK" : "AI PICK",
                              systemImage: member.stackChoice ? "checkmark.circle.fill" : "sparkles")
                            .font(.badgeCompact)
                            .padding(3)
                            .background(member.stackChoice ? .blue.opacity(0.85) : .indigo.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: Theme.chipRadius))
                            .foregroundStyle(.white)
                            .padding(4)
                            .allowsHitTesting(false)
                            .help(member.stackChoice
                                  ? "The take you chose as the best of this stack"
                                  : "The take the AI ranks best (score, excitement, your ratings)")
                    }
                }

            Text("\(member.startTime.timecode)–\(member.endTime.timecode)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            if let narrative = member.narrative {
                Text(narrative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(narrative)
            }

            HStack {
                if isTop {
                    Label("On top", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use as Best") { onPick(member) }
                        .controlSize(.small)
                        .help("Front the stack with this take — the choice is remembered")
                }
                Spacer()
                Button {
                    onPreview(member)
                } label: {
                    Label("Large Preview", systemImage: "play.rectangle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open this take in the large preview player")
            }
        }
    }
}
