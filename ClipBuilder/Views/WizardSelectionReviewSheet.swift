import SwiftUI

struct WizardSelectionReviewSheet: View {
    @Environment(AppStore.self) private var store
    let request: WizardSelectionReviewRequest
    @State private var name: String
    @State private var takes: [WizardSelectionTake]
    @State private var selectedTakeID: Int64?
    @State private var scenes: [SceneRecord]
    @State private var note = ""

    init(request: WizardSelectionReviewRequest) {
        self.request = request
        _name = State(initialValue: request.selection.name)
        _takes = State(initialValue: request.takes)
        _selectedTakeID = State(initialValue: request.selectedTakeID)
        _scenes = State(initialValue: request.scenes)
    }

    private var take: WizardSelectionTake? { takes.first { $0.id == selectedTakeID } }
    private var plan: WizardPlan? { take.flatMap { WizardSelectionRules.resolvedPlan($0.plan, scenes: scenes) } }
    private var canAccept: Bool { plan?.clips.isEmpty == false && !store.isWizardRunning }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                TextField("Selection name", text: $name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, value in store.renameWizardSelection(request.selection.id, name: value) }
                HStack {
                    Text(ReelRecipe.recipe(id: request.selection.recipe)?.title ?? request.selection.recipe)
                    Text("·")
                    Text(request.selection.step1Options.targetDurationSeconds.map { "\($0) seconds" } ?? "Auto length")
                    Spacer()
                    if let take { Text("Take \(take.ordinal)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                FormCaption(take?.plan.rationale ?? "Choose a take to review its moments.")
                    .lineLimit(1)
                    .help(take?.plan.rationale ?? "")
            }
            .padding(Theme.spaceM)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selectedTakeID) {
                    ForEach(takes) { take in
                        takeRow(take).tag(take.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 220)
                .accessibilityLabel("Takes")
                Divider()
                if let plan, let take {
                    ProposedCutsEditor(plan: plan,
                        sceneMap: Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })) { edited in
                        guard let index = takes.firstIndex(where: { $0.id == take.id }) else { return }
                        takes[index].plan = edited
                        takes[index].criticScore = nil
                        takes[index].criticNotes = nil
                        store.saveWizardTakePlan(edited, takeID: take.id)
                    }
                    .id("\(take.id):\(store.scenesVersion)")
                } else {
                    ContentUnavailableView("Footage changed", systemImage: "video.slash",
                        description: Text("The saved video or time range is no longer available. Ask for another take to plan from the current footage."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            VStack(spacing: Theme.spaceS) {
                HStack {
                    TextField("What should change in the next take?", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(anotherTake)
                    Button("Another take", systemImage: "arrow.trianglehead.2.clockwise", action: anotherTake)
                        .disabled(store.isWizardRunning)
                }
                HStack {
                    Button("Keep for later") { store.keepWizardSelectionForLater() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Open in Builder") { accept(openInBuilder: true) }
                        .disabled(!canAccept)
                    Button("Accept") { accept() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAccept)
                }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .padding(Theme.spaceM)
        }
        .frame(minWidth: 1220, idealWidth: 1300, minHeight: 640, idealHeight: 760)
        .task(id: store.scenesVersion) {
            guard let database = store.database else { return }
            if let current = try? await database.fetchScenes(projectID: request.selection.projectID), !Task.isCancelled {
                scenes = current
            }
        }
    }

    private func takeRow(_ take: WizardSelectionTake) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            HStack {
                Text("Take \(take.ordinal)").font(.headline)
                Spacer(minLength: 0)
                if request.selection.bestTakeID == take.id {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                        .accessibilityLabel("Best take")
                }
                if let score = take.criticScore { Text("\(score)/100").font(.caption.monospacedDigit()) }
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            Text("\(Int(WizardSelectionRules.duration(take.plan).rounded())) s · \(take.plan.clips.count) \(take.plan.clips.count == 1 ? "cut" : "cuts")")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            if let note = take.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(note)
            }
            if WizardSelectionRules.resolvedPlan(take.plan, scenes: scenes) == nil {
                Label("Footage changed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.spaceS)
        .help(take.criticNotes ?? WizardSelectionRules.takeLabel(take))
    }

    private func anotherTake() {
        guard !store.isWizardRunning else { return }
        store.anotherWizardTake(selectionID: request.selection.id, note: note, options: request.options)
    }

    private func accept(openInBuilder: Bool = false) {
        guard canAccept, let take else { return }
        store.acceptWizardSelection(request.selection.id, takeID: take.id, options: request.options, openInBuilder: openInBuilder)
    }
}
