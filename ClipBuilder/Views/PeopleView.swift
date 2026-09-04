import SwiftUI

/// People: every distinct person the analyzer has detected across the
/// profile's footage, with the scenes they appear in. Name people here —
/// combined with the tag filter this answers searches like "scenes of
/// George where he is fighting".
struct PeopleView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedPersonIDs: Set<Int64> = []
    @State private var tagFilter = ""            // empty = all tags
    @State private var searchText = ""
    @State private var confirmDelete: PersonRecord?
    @State private var reassignScene: SceneRecord?
    @State private var newPersonName = ""
    @State private var showGenerateSheet = false
    @State private var mergeRequest: MergeRequest?
    /// Person whose avatar picker sheet is open.
    @State private var avatarPickerPerson: PersonRecord?
    /// How aggressively near-simultaneous takes collapse into one card —
    /// shared app-wide with every other scene surface.
    @AppStorage(SceneStacks.levelKey) private var stackLevelRaw = SceneStackLevel.standard.rawValue
    /// Card whose stack picker popover is open (long-press a stacked card).
    @State private var stackPickerSceneID: Int64?
    /// Scene playing in the stack picker's large-preview player.
    @State private var previewScene: SceneRecord?

    /// The people a merge sheet is deciding over — snapshotted at open so a
    /// selection change underneath can't alter what gets merged.
    struct MergeRequest: Identifiable {
        let id = UUID()
        var people: [PersonRecord]
    }

    private var selectedPeople: [PersonRecord] {
        store.people.filter { selectedPersonIDs.contains($0.id) }
    }

    private var visiblePeople: [PersonRecord] {
        store.people.filter { !$0.hidden }
    }

    private var hiddenPeople: [PersonRecord] {
        store.people.filter(\.hidden)
    }

    /// Detail only follows an explicit list selection. Falling back to the
    /// first record made the active person ambiguous in a dense library.
    private var selectedPerson: PersonRecord? {
        selectedPeople.first
    }

    private struct PersonKey: Equatable {
        var scenesVersion: Int
        var personTag: String
        var tagFilter: String
        var searchText: String
        var stackLevel: String
    }

    /// Usable scenes grouped by person tag, one pass per library version —
    /// every list row asks for its person's scenes.
    @State private var scenesByTagMemo = MemoBox<Int, [String: [SceneRecord]]>()
    @State private var contentsMemo = MemoBox<PersonKey, (scenes: [SceneRecord], stacks: [Int64: [SceneRecord]])>()

    /// All usable scenes featuring this person, newest analysis first.
    private func scenes(for person: PersonRecord) -> [SceneRecord] {
        let byTag = scenesByTagMemo(store.scenesVersion) {
            var grouped: [String: [SceneRecord]] = [:]
            for scene in store.scenes where !scene.ignored {
                for tag in scene.tags where tag.hasPrefix("person:") {
                    grouped[tag, default: []].append(scene)
                }
            }
            return grouped
        }
        return byTag[person.tag] ?? []
    }

    /// The person's scenes under the current activity/tag filters — what the
    /// grid displays and what Generate Video draws from. Takes of the same
    /// moment collapse behind their best one (`stacks` maps each fronting
    /// card's id to the whole stack).
    private func displayedContents(for person: PersonRecord)
        -> (scenes: [SceneRecord], stacks: [Int64: [SceneRecord]]) {
        let key = PersonKey(scenesVersion: store.scenesVersion, personTag: person.tag,
                            tagFilter: tagFilter, searchText: searchText, stackLevel: stackLevelRaw)
        return contentsMemo(key) { computeDisplayedContents(for: person) }
    }

    private func computeDisplayedContents(for person: PersonRecord)
        -> (scenes: [SceneRecord], stacks: [Int64: [SceneRecord]]) {
        let filtered = scenes(for: person).filter { scene in
            let visible = displayTags(scene)
            if !tagFilter.isEmpty && !visible.contains(tagFilter) { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return visible.contains { $0.lowercased().contains(query) }
            }
            return true
        }
        var scenes: [SceneRecord] = []
        var stacks: [Int64: [SceneRecord]] = [:]
        for stack in SceneStacks.group(filtered, level: .from(stackLevelRaw)) {
            scenes.append(stack[0])
            if stack.count > 1 { stacks[stack[0].id] = stack }
        }
        return (scenes, stacks)
    }

    private func displayedScenes(for person: PersonRecord) -> [SceneRecord] {
        displayedContents(for: person).scenes
    }

    var body: some View {
        Group {
            if store.people.isEmpty {
                ContentUnavailableView {
                    Label("No people yet", systemImage: "person.2")
                } description: {
                    Text("Analyze videos and distinct people are detected automatically. Re-analyze older videos to break down who appears in them.")
                } actions: {
                    Button("Open Raw Videos") { store.requestedSection = .analyze }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HSplitView {
                    peopleList
                        .rememberedPaneWidth("pane.people.list", min: 250, initial: 300, max: 400)
                        .frame(maxHeight: .infinity)
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("People")
        .navigationSubtitle(hiddenPeople.isEmpty
                            ? "\(store.people.count) detected"
                            : "\(visiblePeople.count) detected · \(hiddenPeople.count) hidden")
        .toolbar {
            if selectedPeople.count > 1 {
                Button {
                    mergeRequest = MergeRequest(people: selectedPeople)
                } label: {
                    ToolbarBubbleLabel(text: "Merge \(selectedPeople.count) People",
                                       systemImage: "person.2.crop.square.stack")
                }
                .help("These are the same person — pick the main record and combine their scenes under one identity")
            }
            Button {
                showGenerateSheet = true
            } label: {
                ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
            }
            .disabled(selectedPerson.map { displayedScenes(for: $0).isEmpty } ?? true)
            .help("Describe a video to create from the displayed scenes — this person and the active tag filter carry into the AI Wizard")
        }
        .sheet(item: $mergeRequest) { request in
            MergePeopleSheet(people: request.people) { main, name in
                store.mergePeople(request.people, into: main, renamingTo: name)
                selectedPersonIDs = [main.id]
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            if let person = selectedPerson {
                GenerateVideoSheet(source: .scenes(
                    displayedScenes(for: person),
                    personKeys: [person.key],
                    tags: tagFilter.isEmpty ? [] : [tagFilter]))
            }
        }
        .sheet(item: $previewScene) { scene in
            PlayerSheet(url: scene.videoURL,
                        title: "\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime, endTime: scene.endTime)
        }
        .sheet(item: $avatarPickerPerson) { person in
            AvatarPickerSheet(person: person)
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.displayName ?? "person")?",
            isPresented: Binding(get: { confirmDelete != nil },
                                 set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete Person", role: .destructive) {
                if let person = confirmDelete { store.deletePerson(person) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Removes the person and their tags from every scene. The scenes themselves stay.")
        }
        .alert("Move scene to a new person", isPresented: Binding(
            get: { reassignScene != nil },
            set: { if !$0 { reassignScene = nil; newPersonName = "" } })
        ) {
            TextField("Name", text: $newPersonName)
            Button("Create and Move") {
                if let scene = reassignScene, let person = selectedPerson,
                   !newPersonName.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.reassignScene(scene, from: person, to: nil,
                                        newPersonName: newPersonName.trimmingCharacters(in: .whitespaces))
                }
                reassignScene = nil
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) {
                reassignScene = nil
                newPersonName = ""
            }
        }
    }

    // MARK: - People list

    private var peopleList: some View {
        List(selection: $selectedPersonIDs) {
            ForEach(visiblePeople) { person in
                personRow(person)
            }
            // Officials, one-off bystanders, joke detections — out of the
            // way but never deleted, so their identity keeps working.
            if !hiddenPeople.isEmpty {
                Section("Hidden People") {
                    ForEach(hiddenPeople) { person in
                        personRow(person)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func personRow(_ person: PersonRecord) -> some View {
        PersonRow(person: person,
                  sceneCount: scenes(for: person).count,
                  videoCount: Set(scenes(for: person).map(\.videoID)).count)
            .tag(person.id)
            .contextMenu {
                if selectedPeople.count > 1, selectedPersonIDs.contains(person.id) {
                    Button("Merge Records…") {
                        mergeRequest = MergeRequest(people: selectedPeople)
                    }
                }
                if store.people.count > 1 {
                    Menu("Merge Into") {
                        ForEach(store.people.filter { $0.id != person.id }) { target in
                            Button(target.displayName) {
                                store.mergePeople(source: person, into: target)
                            }
                        }
                    }
                }
                Button("Choose Avatar…") {
                    avatarPickerPerson = person
                }
                .help("Pick which face is this person's avatar — the automatic crop can grab the wrong face when two people share the frame")
                Button(person.hidden ? "Unhide" : "Hide") {
                    store.setPersonHidden(person, hidden: !person.hidden)
                }
                .help(person.hidden
                      ? "Move this person back into the main list"
                      : "Tuck this person into the Hidden bucket at the bottom — their identity and scene tags stay")
                Button("Delete", role: .destructive) {
                    confirmDelete = person
                }
            }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let person = selectedPerson {
            let allScenes = scenes(for: person)
            let contents = displayedContents(for: person)
            let filtered = contents.scenes
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        avatarPickerPerson = person
                    } label: {
                        PersonFaceAvatar(person: person, size: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose avatar for \(person.displayName)")
                    .help("Choose which face is this person's avatar")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.displayName)
                            .font(.headline)
                        if !person.descriptor.isEmpty {
                            Text(person.descriptor)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    TextField("Filter by activity (e.g. striking)", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Menu(tagFilter.isEmpty ? "All tags" : tagFilter) {
                        Button("All tags") { tagFilter = "" }
                        Divider()
                        ForEach(personTags(allScenes), id: \.self) { tag in
                            Button(tag) { tagFilter = tag }
                        }
                    }
                    .fixedSize()
                    SceneStackLevelPicker(compact: true)
                }
                .padding()

                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No matching scenes",
                        systemImage: "person.crop.rectangle.badge.xmark",
                        description: Text(allScenes.isEmpty
                            ? "This person has no scenes yet."
                            : "No scenes of \(person.displayName) match the current filter."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)],
                                  spacing: 12) {
                            ForEach(filtered) { scene in
                                sceneCard(scene, stack: contents.stacks[scene.id])
                            }
                        }
                        .padding([.horizontal, .bottom])
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Select a person", systemImage: "person.crop.square")
        }
    }

    /// Tags worth filtering by — content tags, not people/bookkeeping ones.
    private func personTags(_ scenes: [SceneRecord]) -> [String] {
        Array(Set(scenes.flatMap(displayTags))).sorted()
    }

    private func displayTags(_ scene: SceneRecord) -> [String] {
        scene.tags.filter {
            !$0.hasPrefix("person:") && !$0.hasPrefix("vip:") && $0 != "auto-hidden"
        }
    }

    @ViewBuilder
    private func sceneCard(_ scene: SceneRecord, stack: [SceneRecord]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SceneInlinePlayer(scene: scene)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    DurationBadge(seconds: scene.duration)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if let score = scene.score {
                        ScoreBadge(score: score)
                            .padding(6)
                            .allowsHitTesting(false)
                            .help(scene.narrative ?? "Entertainment score")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let stack {
                        SceneStackBadge(count: stack.count,
                                        userPicked: scene.stackChoice,
                                        action: { stackPickerSceneID = scene.id })
                            .padding(6)
                    }
                }

            Text(scene.videoFilename)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SceneTagLine(tags: scene.tags)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .sceneStackDeck(count: stack?.count ?? 1)
        .onLongPressGesture(minimumDuration: 0.35) {
            if stack != nil { stackPickerSceneID = scene.id }
        }
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
                                 onPreview: { previewScene = $0 })
            }
        }
        .contextMenu {
            if let stack {
                Button("Choose Best of \(stack.count) Similar Scenes…") {
                    stackPickerSceneID = scene.id
                }
                Divider()
            }
            if let person = selectedPerson {
                Menu("Not \(person.displayName) — move scene to") {
                    ForEach(store.people.filter { $0.id != person.id }) { other in
                        Button(other.displayName) {
                            store.reassignScene(scene, from: person, to: other)
                        }
                    }
                    Divider()
                    Button("New Person…") {
                        reassignScene = scene
                    }
                    Button("Nobody (remove tag)", role: .destructive) {
                        store.reassignScene(scene, from: person, to: nil)
                    }
                }
            }
        }
    }
}

/// Merge confirmation modal: every selected person's avatar in a row — the
/// one the user picks is the Main record whose identity (key, avatar) is
/// used going forward; the others fold into it. The name field applies to
/// the merged person.
private struct MergePeopleSheet: View {
    let people: [PersonRecord]
    /// (main record, edited name) — called on Merge.
    let onMerge: (PersonRecord, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mainID: Int64
    @State private var name: String

    init(people: [PersonRecord], onMerge: @escaping (PersonRecord, String) -> Void) {
        self.people = people
        self.onMerge = onMerge
        let main = people.first { !$0.name.isEmpty } ?? people[0]
        _mainID = State(initialValue: main.id)
        _name = State(initialValue: main.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(people.count) People")
                .font(.headline)
            Text("These records become one person. Choose the main record — its picture and identity carry forward; every other record's scenes fold into it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(people) { person in
                        let isMain = person.id == mainID
                        Button {
                            mainID = person.id
                            // Adopt the new main's name unless the user
                            // already typed something of their own.
                            if name.isEmpty { name = person.name }
                        } label: {
                            VStack(spacing: 5) {
                                PersonFaceAvatar(person: person, size: 64)
                                    .overlay {
                                        Circle().strokeBorder(
                                            isMain ? Color.accentColor : .clear, lineWidth: 3)
                                    }
                                Text(person.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text("Main")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(isMain ? 1 : 0)
                            }
                            .frame(width: 86)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(person.displayName) as the main record")
                        .accessibilityValue(isMain ? "Selected" : "Not selected")
                        .help(person.descriptor)
                    }
                }
                .padding(2)
            }

            TextField("Name", text: $name, prompt: Text("Name this person"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Merge") {
                    if let main = people.first(where: { $0.id == mainID }) {
                        onMerge(main, name)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 400, maxWidth: 560)
        .modalCloseButton { dismiss() }
    }
}

/// One person row: round face avatar, inline-editable name, appearance
/// counts, and the AI's visual descriptor.
private struct PersonRow: View {
    @Environment(AppStore.self) private var store
    let person: PersonRecord
    let sceneCount: Int
    let videoCount: Int

    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            PersonFaceAvatar(person: person, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name this person", text: $name)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .onSubmit {
                        store.renamePerson(person, to: name)
                    }
                Text("\(sceneCount) scene\(sceneCount == 1 ? "" : "s") · \(videoCount) video\(videoCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !person.descriptor.isEmpty {
                    Text(person.descriptor)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { name = person.name }
        .onChange(of: person.name) { _, newValue in name = newValue }
    }
}
