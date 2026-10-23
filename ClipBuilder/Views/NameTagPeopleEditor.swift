import SwiftUI

/// The people a wizard's name tags will label, with their tag copy editable
/// in place: the name, and the line the chosen tag style prints under it
/// (its description field, "Role" by default). Edits are the person's
/// profile-wide values, the same ones the People screen shows, so a fix made
/// here is kept for every later video. Every keystroke is saved after a short
/// pause, and leaving the field or pressing Return saves at once, so nothing
/// typed here is lost when the section collapses or the run starts.
struct NameTagPeopleEditor: View {
    @Environment(AppStore.self) private var store
    /// People to list; nil = derive them from `videoIDs`' rosters.
    var people: [PersonRecord]?
    /// Videos whose rosters name the people, when `people` is nil.
    var videoIDs: [Int64]?
    let styleID: String?
    let profile: BrandProfile

    @State private var rosterKeys: Set<String>?
    @State private var values: [String: String] = [:]
    @State private var positions: [String: String] = [:]
    @State private var nameDrafts: [String: String] = [:]
    @State private var valueDrafts: [String: String] = [:]
    @State private var pending: [String: Task<Void, Never>] = [:]
    @State private var error: String?
    @FocusState private var focused: String?

    static let saveDelay: Duration = .milliseconds(500)

    private var field: String { profile.tagStyle(id: styleID).description.field }

    /// Ordered by key so a rename never moves the row being edited.
    private var listed: [PersonRecord] {
        let shown: [PersonRecord]
        if let people {
            shown = people.filter { !$0.hidden }
        } else if let rosterKeys {
            shown = store.people.filter { rosterKeys.contains($0.key) && !$0.hidden }
        } else {
            shown = []
        }
        return shown.sorted { $0.key < $1.key }
    }

    var body: some View {
        let shown = listed
        if !shown.isEmpty || rosterKeys == nil && people == nil {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                if shown.isEmpty {
                    FormCaption("Looking up who appears in the footage…")
                } else {
                    FormCaption("Tags print the name and \(field). Edit either here; the change applies to the person everywhere and is saved as you type. "
                        + "Position overrides the run's tag position for that person.")
                    ForEach(shown) { person in
                        row(person)
                    }
                }
                if let error {
                    FormCaption(error, tone: .warning)
                }
            }
            .task(id: "\(store.profileGeneration)|\(field)|\(store.personTagFieldsVersion)|\(videoIDs ?? [])") {
                await load()
            }
            .onChange(of: focused) { previous, _ in
                // Leaving a field saves it at once, with the first-name research.
                guard let previous, let person = shown.first(where: { previous.hasSuffix(":" + $0.key) }) else { return }
                if previous.hasPrefix("name:") { commitName(person) } else { commitValue(person) }
            }
            .onDisappear {
                for person in shown {
                    commitName(person)
                    commitValue(person)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ person: PersonRecord) -> some View {
        HStack(alignment: .center, spacing: Theme.spaceS) {
            PersonFaceAvatar(person: person, size: 28)
            TextField(person.displayName, text: Binding(
                get: { nameDrafts[person.key] ?? person.name },
                set: { text in
                    nameDrafts[person.key] = text
                    schedule("name:" + person.key) { commitName(person, research: false) }
                }))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 160)
                .focused($focused, equals: "name:" + person.key)
                .onSubmit { commitName(person) }
                .accessibilityLabel("Name of \(person.displayName)")
            TextField(field, text: Binding(
                get: { valueDrafts[person.key] ?? values[person.key] ?? "" },
                set: { text in
                    valueDrafts[person.key] = text
                    schedule("value:" + person.key) { commitValue(person) }
                }))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 200)
                .focused($focused, equals: "value:" + person.key)
                .onSubmit { commitValue(person) }
                .accessibilityLabel("\(field) of \(person.displayName)")
            Picker("Position", selection: Binding(
                get: { positions[person.key] ?? "" },
                set: { setPosition(person, $0) })) {
                Text("Run default").lineLimit(1).fixedSize().tag("")
                Text("Top left").lineLimit(1).fixedSize().tag(NameTagPlanner.Corner.topLeading.rawValue)
                Text("Top right").lineLimit(1).fixedSize().tag(NameTagPlanner.Corner.topTrailing.rawValue)
                Text("Bottom left").lineLimit(1).fixedSize().tag(NameTagPlanner.Corner.bottomLeading.rawValue)
                Text("Bottom right").lineLimit(1).fixedSize().tag(NameTagPlanner.Corner.bottomTrailing.rawValue)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Tag position of \(person.displayName)")
            .help("Where this person's tag sits; Run default follows the Tag position above")
            Image(systemName: hasChanges(person) ? "ellipsis.circle" : "checkmark.circle")
                .foregroundStyle(hasChanges(person) ? Color.secondary : Color.green)
                .controlSize(.small)
                .accessibilityLabel(hasChanges(person) ? "Saving" : "Saved")
                .help(hasChanges(person) ? "Saving…" : "Saved")
        }
    }

    /// True while a typed value has not reached the database yet.
    private func hasChanges(_ person: PersonRecord) -> Bool {
        let name = nameDrafts[person.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = valueDrafts[person.key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name != nil && name != person.name) || (value != nil && value != (values[person.key] ?? ""))
    }

    /// One save per field at a time; a new keystroke restarts the pause.
    private func schedule(_ id: String, _ action: @escaping () -> Void) {
        pending[id]?.cancel()
        pending[id] = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func load() async {
        guard let database = store.database else { return }
        do {
            if people == nil {
                var keys = Set<String>()
                for id in videoIDs ?? [] {
                    keys.formUnion(try await database.fetchVideoPeople(videoID: id).map(\.key))
                }
                guard store.database === database else { return }
                rosterKeys = keys
            }
            let text = try await database.tagText(field: field)
            let corners = try await database.tagText(field: NameTagPlanner.positionField)
            guard store.database === database else { return }
            values = text
            positions = corners
            // Drafts that now match the stored value have been saved.
            for (key, draft) in valueDrafts where draft.trimmingCharacters(in: .whitespacesAndNewlines) == (text[key] ?? "") {
                valueDrafts[key] = nil
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setPosition(_ person: PersonRecord, _ corner: String) {
        guard let database = store.database, corner != (positions[person.key] ?? "") else { return }
        positions[person.key] = corner
        Task {
            do {
                if corner.isEmpty {
                    try await database.clearPersonTagField(personKey: person.key, field: NameTagPlanner.positionField)
                } else {
                    try await database.savePersonTagField(personKey: person.key, field: NameTagPlanner.positionField,
                                                          value: corner, provenance: nil, source: "user")
                }
                guard store.database === database else { return }
                store.personTagFieldsVersion &+= 1
                await store.reloadPeople()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Saves the typed name. The draft stays in the field until the store's
    /// people reflect it, so the text never jumps back while typing.
    private func commitName(_ person: PersonRecord, research: Bool = true) {
        pending["name:" + person.key]?.cancel()
        guard let draft = nameDrafts[person.key] else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == person.name {
            nameDrafts[person.key] = nil
            return
        }
        guard !trimmed.isEmpty else { return }
        store.renamePerson(person, to: trimmed, research: research)
    }

    private func commitValue(_ person: PersonRecord) {
        pending["value:" + person.key]?.cancel()
        guard let draft = valueDrafts[person.key], let database = store.database else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == (values[person.key] ?? "") {
            valueDrafts[person.key] = nil
            return
        }
        let name = nameDrafts[person.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? person.displayName
        let value: String?
        if trimmed.isEmpty {
            value = nil
        } else if TagTextWriter.isHandleField(field) {
            value = TagTextWriter.normalizeHandle(trimmed, field: field).flatMap { TagTextWriter.clean($0, name: name) }
        } else {
            guard trimmed.count <= 40 else { error = "\(field) is limited to 40 characters."; return }
            value = TagTextWriter.clean(trimmed, name: name)
        }
        let field = field
        Task {
            do {
                if let value {
                    try await database.savePersonTagField(personKey: person.key, field: field, value: value,
                                                          provenance: nil, source: "user")
                } else {
                    try await database.clearPersonTagField(personKey: person.key, field: field)
                }
                guard store.database === database else { return }
                values[person.key] = value ?? ""
                // Keep a draft the user has typed past since this save started.
                if valueDrafts[person.key] == draft { valueDrafts[person.key] = nil }
                store.personTagFieldsVersion &+= 1
                error = nil
                store.appendLog(\.analysisLog, ["Name tag: \(field) for \(person.displayName) set to \(value ?? "nothing")"])
            } catch {
                self.error = error.localizedDescription
                store.appendLog(\.analysisLog, ["Name tag: could not save \(field) for \(person.displayName): \(error.localizedDescription)"])
            }
        }
    }
}
