import SwiftUI

/// Researched profile fields and any custom fields used by the profile's tag styles.
struct PersonTagFieldsView: View {
    @Environment(AppStore.self) private var store
    let person: PersonRecord
    @State private var fields: [PersonTagField] = []
    @State private var drafts: [String: PersonTagField] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            if !fields.isEmpty {
                HStack {
                    Text("Name tag").font(.headline).lineLimit(1).fixedSize()
                    Spacer()
                    Button("Research on the Web") {
                        store.researchPeople([person], reason: "refresh")
                    }
                    .lineLimit(1).fixedSize()
                    .disabled(person.isUnnamed || store.personResearchInFlight.contains(person.id))
                    .help("Searches the web for this person's role, profession, record, team, nationality, Instagram and X handles and proposes values for review.")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spaceM, alignment: .top), count: 3),
                          alignment: .leading, spacing: Theme.spaceM) {
                    ForEach(fields) { savedField in
                        let draft = Binding(
                            get: { drafts[savedField.id] ?? savedField },
                            set: { drafts[savedField.id] = $0 }
                        )
                        let field = draft.wrappedValue
                        let repeatsPersonName = !TagTextWriter.isHandleField(field.field) && repeatsName(field.value)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(field.field).font(.caption.weight(.medium)).lineLimit(1).fixedSize()
                                Spacer()
                                if let provenance = field.provenance { AIInfoButton(provenance: provenance, role: "Name tag text") }
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    store.researchPeople([person], fields: [field.field], reason: "refresh")
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless).controlSize(.small)
                                .lineLimit(1).fixedSize()
                                .disabled(person.isUnnamed || store.personResearchInFlight.contains(person.id))
                                .help("Search the web again for this field")
                                Button("Save", systemImage: "checkmark.circle") { save(field) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless).controlSize(.small)
                                    .lineLimit(1).fixedSize()
                                    .disabled(field.value == savedField.value
                                        || (!TagTextWriter.isHandleField(field.field)
                                            && (field.value.count > 40 || repeatsName(field.value))))
                                    .help("Save this value")
                                Button("Clear", systemImage: "trash", role: .destructive) { clear(field) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless).controlSize(.small)
                                    .lineLimit(1).fixedSize()
                                    .disabled(field.value.isEmpty)
                                    .help("Clear this field")
                            }
                            HStack(spacing: 4) {
                                if TagTextWriter.isHandleField(field.field) {
                                    Text("@").lineLimit(1).fixedSize()
                                }
                                TextField(field.field, text: draft.value)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .onChange(of: field.value) { _, value in
                                        if !TagTextWriter.isHandleField(field.field), value.count > 40 {
                                            draft.wrappedValue.value = String(value.prefix(40))
                                        }
                                    }
                                if let handle = TagTextWriter.normalizeHandle(field.value, field: field.field),
                                   let url = URL(string: "https://\(field.field == "Instagram" ? "instagram.com" : "x.com")/\(handle)") {
                                    Link(destination: url) {
                                        Label("Open", systemImage: "arrow.up.right.square").labelStyle(.iconOnly)
                                    }
                                    .lineLimit(1).fixedSize()
                                    .help("Open the profile")
                                }
                            }
                            HStack {
                                Text(repeatsPersonName ? "Use a description instead of repeating the name." : metadata(field) ?? " ")
                                    .font(.caption2)
                                    .foregroundStyle(repeatsPersonName || isStale(field) ? Color.orange : Color.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(field.value.count)/\(field.field == "Instagram" ? 30 : field.field == "X" ? 15 : 40)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("The second line of this person’s name tag. A blank field is filled by AI on the next run that shows a tag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: "\(store.profileGeneration)|\(person.key)|\(store.personTagFieldsVersion)") {
            fields = []
            guard let database = store.database else { return }
            do {
                let loaded = try await database.personTagFields(personKey: person.key)
                try Task.checkCancellation()
                guard store.database === database else { return }
                fields = withStyleFields(loaded)
                error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: fields) { _, _ in drafts = [:] }
    }

    /// Saved rows plus all seven profile fields and any custom style fields.
    private func withStyleFields(_ saved: [PersonTagField]) -> [PersonTagField] {
        let profile = store.activeProfile
        let styles = [profile.tagStyle(id: nil)] + (profile.tagStyles ?? []).map(\.style)
        let profileFields = TagTextWriter.profileFields.map { TagTextWriter.fieldKey($0) }
        let customFields = Set(styles.map { TagTextWriter.fieldKey($0.description.field) }
            + saved.map { TagTextWriter.fieldKey($0.field) })
            .subtracting(profileFields).sorted()
        return (profileFields + customFields).map { key in
            if var field = saved.first(where: { TagTextWriter.fieldKey($0.field) == key }) {
                field.field = key
                return field
            }
            return PersonTagField(personKey: person.key, field: key, value: "", provenance: nil)
        }
    }

    private func isStale(_ field: PersonTagField) -> Bool {
        field.field == "MMA record" && !field.value.isEmpty
            && PersonResearch.needsRecordRefresh(fields: [field], person: person, now: Date())
    }

    private func metadata(_ field: PersonTagField) -> String? {
        var parts: [String] = []
        if let at = field.provenance?.at {
            parts.append("Updated \(at.formatted(date: .abbreviated, time: .omitted))")
        } else if field.provenance == nil && !field.value.isEmpty {
            parts.append("Added by hand")
        }
        if let host = PersonResearch.sourceURL(field.source)?.host { parts.append(host) }
        if isStale(field) { parts.append("stale") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func repeatsName(_ value: String) -> Bool {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = person.displayName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !text.isEmpty && text.caseInsensitiveCompare(name) == .orderedSame
    }

    private func save(_ field: PersonTagField) {
        let value: String?
        if TagTextWriter.isHandleField(field.field) {
            value = TagTextWriter.normalizeHandle(field.value, field: field.field)
                .flatMap { TagTextWriter.clean($0, name: person.displayName) }
        } else {
            guard field.value.count <= 40, !repeatsName(field.value) else { return }
            value = TagTextWriter.clean(field.value, name: person.displayName)
        }
        guard let database = store.database else { return }
        Task {
            do {
                if let value {
                    try await database.savePersonTagField(personKey: person.key, field: field.field, value: value, provenance: nil)
                } else {
                    try await database.clearPersonTagField(personKey: person.key, field: field.field)
                }
                let loaded = try await database.personTagFields(personKey: person.key)
                guard store.database === database else { return }
                fields = withStyleFields(loaded)
                store.personTagFieldsVersion &+= 1
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func clear(_ field: PersonTagField) {
        guard let database = store.database else { return }
        Task {
            do {
                try await database.clearPersonTagField(personKey: person.key, field: field.field)
                guard store.database === database else { return }
                fields = withStyleFields(fields.filter { $0.id != field.id })
                store.personTagFieldsVersion &+= 1
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
