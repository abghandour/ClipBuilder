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

    private var selectedPeople: [PersonRecord] {
        store.people.filter { selectedPersonIDs.contains($0.id) }
    }

    /// Detail shows a single person; with a multi-selection the first one.
    private var selectedPerson: PersonRecord? {
        selectedPeople.first ?? store.people.first
    }

    /// All usable scenes featuring this person, newest analysis first.
    private func scenes(for person: PersonRecord) -> [SceneRecord] {
        store.scenes.filter { !$0.ignored && $0.tags.contains(person.tag) }
    }

    /// The person's scenes under the current activity/tag filters — what the
    /// grid displays and what Generate Video draws from.
    private func displayedScenes(for person: PersonRecord) -> [SceneRecord] {
        scenes(for: person).filter { scene in
            let visible = displayTags(scene)
            if !tagFilter.isEmpty && !visible.contains(tagFilter) { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return visible.contains { $0.lowercased().contains(query) }
            }
            return true
        }
    }

    var body: some View {
        Group {
            if store.people.isEmpty {
                ContentUnavailableView(
                    "No people yet",
                    systemImage: "person.2",
                    description: Text("Analyze videos and distinct people are detected automatically. Re-analyze older videos to break down who appears in them."))
            } else {
                HSplitView {
                    peopleList
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 400, maxHeight: .infinity)
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("People")
        .navigationSubtitle("\(store.people.count) detected")
        .toolbar {
            if selectedPeople.count > 1 {
                Button {
                    mergeSelected()
                } label: {
                    ToolbarBubbleLabel(text: "Merge \(selectedPeople.count) People",
                                       systemImage: "person.2.crop.square.stack")
                }
                .help("These are the same person — combine their scenes under one identity")
            }
            Button {
                showGenerateSheet = true
            } label: {
                ToolbarBubbleLabel(text: "Generate Video", systemImage: "wand.and.stars")
            }
            .disabled(selectedPerson.map { displayedScenes(for: $0).isEmpty } ?? true)
            .help("Describe a video to create from the displayed scenes — this person and the active tag filter carry into the AI Wizard")
        }
        .sheet(isPresented: $showGenerateSheet) {
            if let person = selectedPerson {
                GenerateVideoSheet(source: .scenes(
                    displayedScenes(for: person),
                    personKeys: [person.key],
                    tags: tagFilter.isEmpty ? [] : [tagFilter]))
            }
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

    /// Survivor: the first named selection, else the one with most scenes.
    private func mergeSelected() {
        let selected = selectedPeople
        guard selected.count > 1 else { return }
        let survivor = selected.first { !$0.name.isEmpty }
            ?? selected.max { scenes(for: $0).count < scenes(for: $1).count }
            ?? selected[0]
        selectedPersonIDs = [survivor.id]
        store.mergePeople(selected, into: survivor)
    }

    // MARK: - People list

    private var peopleList: some View {
        List(store.people, selection: $selectedPersonIDs) { person in
            PersonRow(person: person,
                      sceneCount: scenes(for: person).count,
                      videoCount: Set(scenes(for: person).map(\.videoID)).count)
                .tag(person.id)
                .contextMenu {
                    if store.people.count > 1 {
                        Menu("Merge Into") {
                            ForEach(store.people.filter { $0.id != person.id }) { target in
                                Button(target.displayName) {
                                    store.mergePeople(source: person, into: target)
                                }
                            }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        confirmDelete = person
                    }
                }
        }
        .listStyle(.inset)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let person = selectedPerson {
            let allScenes = scenes(for: person)
            let filtered = displayedScenes(for: person)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    PersonFaceAvatar(person: person, size: 40)
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
                                sceneCard(scene)
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
    private func sceneCard(_ scene: SceneRecord) -> some View {
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

            Text(scene.videoFilename)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SceneTagLine(tags: scene.tags)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
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
