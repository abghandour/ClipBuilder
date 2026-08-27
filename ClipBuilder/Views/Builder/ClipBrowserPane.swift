import SwiftUI

/// Scene browser for the Builder: filter the analyzed scenes and drag them
/// onto the timeline (or click + to append to Track I).
struct ClipBrowserPane: View {
    @Environment(AppStore.self) private var store

    @State private var tagFilter: String?
    @State private var favoritesOnly = false
    @State private var orientation = OrientationFilter.all
    @State private var batchFilter: Int64?
    @State private var durationFilter = DurationFilter.any
    @State private var playingScene: SceneRecord?
    /// How aggressively near-simultaneous takes collapse into one card —
    /// shared app-wide with every other scene surface.
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue
    /// Card whose stack picker popover is open (via badge or context menu).
    @State private var stackPickerSceneID: Int64?

    enum OrientationFilter: String, CaseIterable {
        case all = "All"
        case vertical = "Vertical"
        case wide = "Wide"
    }

    /// Upper bound on scene length; nil = unbounded.
    enum DurationFilter: String, CaseIterable {
        case any = "Any length"
        case under5 = "< 5s"
        case under15 = "< 15s"
        case under30 = "< 30s"

        var maxSeconds: Double? {
            switch self {
            case .any: return nil
            case .under5: return 5
            case .under15: return 15
            case .under30: return 30
            }
        }
    }

    /// Every filter except the tag itself — the tag dropdown's counts are
    /// computed over exactly these scenes, so they stay truthful as the
    /// batch/duration/orientation/favorites filters change.
    private func passesNonTagFilters(_ scene: SceneRecord) -> Bool {
        if scene.excluded { return false }
        if favoritesOnly && !scene.favorite { return false }
        if orientation == .wide && !scene.wide { return false }
        if orientation == .vertical && scene.wide { return false }
        if let batchFilter, scene.runID != batchFilter { return false }
        if let maxSeconds = durationFilter.maxSeconds, scene.duration >= maxSeconds { return false }
        return true
    }

    private var filteredScenes: [SceneRecord] {
        store.scenes.filter { scene in
            passesNonTagFilters(scene)
                && (tagFilter.map { scene.tags.contains($0) } ?? true)
        }
    }

    /// The grid's cards plus, for every card fronting a stack of takes of
    /// the same moment, the whole stack behind it (best take first).
    private var gridContents: (scenes: [SceneRecord], stacks: [Int64: [SceneRecord]]) {
        var scenes: [SceneRecord] = []
        var stacks: [Int64: [SceneRecord]] = [:]
        for stack in SceneStacks.group(filteredScenes, level: .from(stackLevelRaw)) {
            scenes.append(stack[0])
            if stack.count > 1 { stacks[stack[0].id] = stack }
        }
        return (scenes, stacks)
    }

    /// Tags with at least one matching scene, with their scene counts. The
    /// active tag stays listed even when its count drops to zero, so the
    /// picker's selection never dangles.
    private var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for scene in store.scenes where passesNonTagFilters(scene) {
            for tag in Set(scene.tags) { counts[tag, default: 0] += 1 }
        }
        if let tagFilter, counts[tagFilter] == nil { counts[tagFilter] = 0 }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Analyze batches that actually hold scenes, newest first.
    private var batches: [AnalyzeBatchFilterList.Batch] {
        store.analysisRuns
            .filter { $0.sceneCount > 0 }
            .sorted { $0.id > $1.id }
            .map { .init(id: $0.id, name: $0.name, count: $0.sceneCount) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                AnalyzeBatchFilterList(batches: batches, selection: $batchFilter)
                HStack {
                    Picker("Tag", selection: $tagFilter) {
                        Text("All Tags").tag(String?.none)
                        ForEach(tagCounts, id: \.tag) { entry in
                            Text("\(entry.tag) (\(entry.count))").tag(String?.some(entry.tag))
                        }
                    }
                    .labelsHidden()
                    Picker("Orientation", selection: $orientation) {
                        ForEach(OrientationFilter.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .labelsHidden()
                    Picker("Duration", selection: $durationFilter) {
                        ForEach(DurationFilter.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Only show scenes shorter than this")
                    Toggle(isOn: $favoritesOnly) {
                        Image(systemName: "heart.fill")
                    }
                    .toggleStyle(.button)
                    .help("Favorites only")
                    SceneStackLevelPicker(compact: true)
                }
                .controlSize(.small)
            }
            .padding(10)

            Divider()

            let contents = gridContents
            if contents.scenes.isEmpty {
                ContentUnavailableView("No Scenes", systemImage: "square.grid.3x3",
                                       description: Text("Analyze source videos, then drag scenes onto the timeline."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .top)],
                              spacing: 8) {
                        ForEach(contents.scenes) { scene in
                            let stack = contents.stacks[scene.id]
                            BrowserSceneCard(scene: scene,
                                             onAdd: { store.builder.addScene(scene) },
                                             onPlay: { playingScene = scene },
                                             stackMembers: stack,
                                             onPickFromStack: stack != nil
                                                 ? { stackPickerSceneID = scene.id } : nil)
                                .popover(isPresented: Binding(
                                    get: { stackPickerSceneID == scene.id },
                                    set: { if !$0 { stackPickerSceneID = nil } })
                                ) {
                                    if let stack {
                                        SceneStackPicker(members: stack,
                                                         onPick: { pick in
                                                             stackPickerSceneID = nil
                                                             store.chooseStackBest(pick, among: stack)
                                                         },
                                                         onPreview: { playingScene = $0 })
                                    }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .sheet(item: $playingScene) { scene in
            PlayerSheet(url: scene.videoURL,
                        title: "\(scene.videoFilename) \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime,
                        endTime: scene.endTime)
        }
    }
}

/// Compact draggable scene card. The drag payload is "scene:<id>", which the
/// timeline lanes decode in their drop destinations.
struct BrowserSceneCard: View {
    let scene: SceneRecord
    let onAdd: () -> Void
    let onPlay: () -> Void
    /// Set when this card fronts a stack of near-simultaneous takes (2+
    /// members, this scene first) — draws the stack badge.
    var stackMembers: [SceneRecord]?
    /// Opens the stack picker (badge click or context menu — long-press is
    /// taken by dragging here).
    var onPickFromStack: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VideoThumbnail(url: scene.videoURL, time: (scene.startTime + scene.endTime) / 2)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    DurationBadge(seconds: scene.duration)
                }
                .overlay(alignment: .topLeading) {
                    if let score = scene.score {
                        ScoreBadge(score: score, compact: true)
                            .padding(4)
                            .help(scene.narrative ?? "Entertainment score")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if scene.wide {
                            WideBadge(compact: true)
                        }
                        if scene.favorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                        if let stackMembers, stackMembers.count > 1 {
                            SceneStackBadge(count: stackMembers.count,
                                            userPicked: scene.stackChoice,
                                            compact: true,
                                            action: onPickFromStack)
                        }
                    }
                    .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onAdd) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add to timeline")
                    .padding(4)
                }
            Text(scene.videoFilename)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !scene.tags.isEmpty {
                SceneTagLine(tags: scene.tags)
            }
        }
        .draggable("scene:\(scene.id)")
        .highPriorityGesture(TapGesture(count: 2).onEnded { onPlay() })
        .contextMenu {
            Button("Add to Timeline") { onAdd() }
            Button("Play") { onPlay() }
            if let onPickFromStack, let stackMembers {
                Button("Choose Best of \(stackMembers.count) Similar Scenes…") {
                    onPickFromStack()
                }
            }
        }
    }
}
