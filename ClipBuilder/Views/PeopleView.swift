import SwiftUI

/// People: every distinct person the analyzer has detected across the
/// profile's footage, with the scenes they appear in. Name people here —
/// combined with the tag filter this answers searches like "scenes of
/// George where he is fighting".
struct PeopleView: View {
    @Environment(AppStore.self) private var store

    @State private var selectedPersonIDs: Set<Int64> = []
    /// Which bucket the list shows — every category, one role, the people
    /// still waiting on a confirmed name, or the Hidden bucket.
    @State private var bucketFilter: PeopleBucket = .all
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

    /// An explicit selection wins; otherwise research visible people still awaiting a role.
    nonisolated static func researchTargets(selected: [PersonRecord], visible: [PersonRecord]) -> [PersonRecord] {
        if !selected.isEmpty { return selected }
        return visible.filter { $0.category == nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var peopleToResearch: [PersonRecord] {
        Self.researchTargets(selected: selectedPeople, visible: visiblePeople)
    }

    /// People with footage in the current project; Home (or no project)
    /// lists the whole profile. Merge targets stay profile-wide.
    private var projectPeople: [PersonRecord] {
        guard store.activeProjectID != nil, !store.isHomeProject else { return store.people }
        let tags = Set(store.sceneIndex.personTagsByVideo.values.flatMap { $0 })
        return store.people.filter { tags.contains($0.tag) }
    }

    private var visiblePeople: [PersonRecord] {
        projectPeople.filter { !$0.hidden }.sorted { lhs, rhs in
            let lhsInProject = store.sceneIndex.allTags.contains(lhs.tag)
            let rhsInProject = store.sceneIndex.allTags.contains(rhs.tag)
            if lhsInProject != rhsInProject { return lhsInProject }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var hiddenPeople: [PersonRecord] {
        projectPeople.filter(\.hidden)
    }

    /// The list's buckets: every role the user has filed people under,
    /// Unknown (no confirmed name yet) and Hidden.
    enum PeopleBucket: Hashable {
        case all
        case category(PersonCategory)
        case uncategorized
        case unknown
        case hidden

        var label: String {
            switch self {
            case .all: "All People"
            case .category(let category): category.pluralLabel
            case .uncategorized: "Uncategorized"
            case .unknown: "Unknown"
            case .hidden: "Hidden"
            }
        }

        var systemImage: String {
            switch self {
            case .all: "person.2"
            case .category(let category): category.systemImage
            case .uncategorized: "person.crop.circle.dashed"
            case .unknown: "person.fill.questionmark"
            case .hidden: "eye.slash"
            }
        }

        /// Every bucket a picker offers, in list order.
        static var pickerCases: [PeopleBucket] {
            [.all] + PersonCategory.allCases.map(PeopleBucket.category) + [.uncategorized, .unknown, .hidden]
        }
    }

    /// Visible (non-hidden) people that belong in a bucket. Unknown holds
    /// everyone still waiting on a confirmed name, whatever their role.
    private func people(in bucket: PeopleBucket) -> [PersonRecord] {
        switch bucket {
        case .all: visiblePeople
        case .category(let category):
            visiblePeople.filter { $0.category == category && !$0.needsConfirmation }
        case .uncategorized:
            visiblePeople.filter { $0.category == nil && !$0.needsConfirmation }
        case .unknown: visiblePeople.filter(\.needsConfirmation)
        case .hidden: hiddenPeople
        }
    }

    /// The sections the list shows for the current filter: All groups by
    /// role and appends Unknown and Hidden; a single bucket shows just it.
    private var listSections: [(bucket: PeopleBucket, people: [PersonRecord])] {
        let buckets: [PeopleBucket] = bucketFilter == .all
            ? PersonCategory.allCases.map(PeopleBucket.category) + [.uncategorized, .unknown, .hidden]
            : [bucketFilter]
        return buckets.map { ($0, people(in: $0)) }.filter { !$0.people.isEmpty }
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
            if projectPeople.isEmpty {
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
        // Another screen asked for a person (the avatar popover's Open in
        // People): select them once, then forget the request.
        .task(id: store.requestedPersonID) {
            guard let requested = store.requestedPersonID else { return }
            store.requestedPersonID = nil
            if store.people.contains(where: { $0.id == requested }) { selectedPersonIDs = [requested] }
        }
        .screenTitle("People", subtitle: hiddenPeople.isEmpty ? "\(projectPeople.count) \(store.isHomeProject ? "detected" : "in this project")" : "\(visiblePeople.count) \(store.isHomeProject ? "detected" : "in this project") · \(hiddenPeople.count) hidden")
        .toolbar {
            if let snapshot = store.previousPeopleMerge {
                Button {
                    Task { if await store.undoPeopleMerge() { selectedPersonIDs = [] } }
                } label: {
                    ToolbarBubbleLabel(text: "Undo Merge", systemImage: "arrow.uturn.backward")
                }
                .help("Put back the \(snapshot.sources.count) people merged into \(snapshot.survivor.displayName)")
            }
            Button {
                store.researchPeople(peopleToResearch, reason: "refresh")
            } label: {
                ToolbarBubbleLabel(text: "Refresh Research", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!peopleToResearch.contains { !$0.isUnnamed && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                      || peopleToResearch.allSatisfy { store.personResearchInFlight.contains($0.id) })
            .help("Search the web for the selected people's profile fields and role — or, with nothing selected, propose a role for everyone without one. You review every value before it is saved.")
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
            PlayerSheet(url: scene.videoURL, transcriptVideoID: scene.videoID,
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
        VStack(spacing: 0) {
            Picker("Show", selection: $bucketFilter) {
                ForEach(PeopleBucket.pickerCases, id: \.self) { bucket in
                    Label {
                        Text(bucket.label)
                    } icon: {
                        Image(systemName: bucket.systemImage)
                    }
                    .tag(bucket)
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Show one role, the people whose name still needs confirming, or the Hidden bucket")
            Divider()
            List(selection: $selectedPersonIDs) {
                // Roles first, then the people still waiting on a confirmed
                // name, then Hidden: officials, one-off bystanders, joke
                // detections — out of the way but never deleted, so their
                // identity keeps working.
                ForEach(listSections, id: \.bucket) { section in
                    Section {
                        ForEach(section.people) { person in
                            personRow(person)
                        }
                    } header: {
                        Label(sectionTitle(section.bucket), systemImage: section.bucket.systemImage)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if listSections.isEmpty {
                    ContentUnavailableView(
                        "No \(bucketFilter.label.lowercased())",
                        systemImage: bucketFilter.systemImage,
                        description: Text(emptyBucketHint))
                }
            }
        }
    }

    private func sectionTitle(_ bucket: PeopleBucket) -> String {
        switch bucket {
        case .unknown: "Unknown — needs confirmation"
        case .hidden: "Hidden People"
        default: bucket.label
        }
    }

    private var emptyBucketHint: String {
        switch bucketFilter {
        case .all: "Analyze videos and distinct people are detected automatically."
        case .category(let category):
            "Right-click a person and choose Category › \(category.label) to file them here."
        case .uncategorized: "Every confirmed person has a category."
        case .unknown: "Every detected person has a confirmed name."
        case .hidden: "Right-click a person and choose Hide to tuck them away here."
        }
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
                categoryMenu(for: person)
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

    /// Category submenu: one entry per role plus None; the current one is checked.
    private func categoryMenu(for person: PersonRecord) -> some View {
        Menu("Category") {
            ForEach(PersonCategory.allCases, id: \.self) { category in
                Toggle(isOn: Binding(
                    get: { person.category == category },
                    set: { store.setPersonCategory(person, category: $0 ? category : nil) })
                ) {
                    Label(category.label, systemImage: category.systemImage)
                }
            }
            Divider()
            Button("None") { store.setPersonCategory(person, category: nil) }
                .disabled(person.category == nil)
        }
        .help("File this person under a role — the list groups and filters by it")
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
                        HStack(spacing: 8) {
                            Text(person.displayName)
                                .font(.headline)
                            Picker("Category", selection: Binding(
                                get: { person.category },
                                set: { store.setPersonCategory(person, category: $0) })
                            ) {
                                Text("No category").tag(PersonCategory?.none)
                                Divider()
                                ForEach(PersonCategory.allCases, id: \.self) { category in
                                    Label(category.label, systemImage: category.systemImage)
                                        .tag(PersonCategory?.some(category))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                            .help("File this person under a role — the list groups and filters by it")
                        }
                        if person.isUnnamed, person.keyName != nil {
                            Text("Name read by the analyzer — confirm it in the list on the left")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
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

                ScrollView {
                    PersonTagFieldsView(person: person)
                        .id(person.key)
                        .padding(.horizontal)
                }
                .frame(maxHeight: 280)

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
    @State private var showMergeConfirmation = false

    init(people: [PersonRecord], onMerge: @escaping (PersonRecord, String) -> Void) {
        self.people = people
        self.onMerge = onMerge
        let main = people.first { !$0.name.isEmpty } ?? people[0]
        _mainID = State(initialValue: main.id)
        _name = State(initialValue: main.name)
    }

    private var mergeName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (people.first { $0.id == mainID }?.displayName ?? "") : trimmed
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
                Button("Cancel") { dismiss() }
                Button("Merge") { showMergeConfirmation = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .confirmationDialog("Merge \(people.count) people into \(mergeName)?",
                                    isPresented: $showMergeConfirmation, titleVisibility: .visible) {
                    Button("Merge", role: .destructive) {
                        if let main = people.first(where: { $0.id == mainID }) {
                            onMerge(main, name)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The other \(people.count - 1) records are removed and their scenes, roster entries, speaker turns, transcript lines, markers and name-tag fields move to \(mergeName). Undo Merge in the toolbar puts them back until you switch profiles.")
                }
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
                // An unconfirmed person shows the name the analyzer read as
                // the placeholder; typing (or submitting it) confirms it.
                TextField(person.keyName.map { "\($0) — press Return to confirm" } ?? "Name this person",
                          text: $name)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .onSubmit {
                        let typed = name.trimmingCharacters(in: .whitespaces)
                        let confirmed = typed.isEmpty ? (person.keyName ?? "") : typed
                        guard !confirmed.isEmpty else { return }
                        name = confirmed
                        store.renamePerson(person, to: confirmed)
                    }
                Text((person.category.map { "\($0.label) · " } ?? "")
                     + "\(sceneCount) scene\(sceneCount == 1 ? "" : "s") · \(videoCount) video\(videoCount == 1 ? "" : "s")")
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
