import SwiftUI

/// The second line of this person's name tag, one row per field the profile's
/// tag styles use. A blank field is written by AI on the next run that needs it.
struct PersonTagFieldsView: View {
    @Environment(AppStore.self) private var store
    let person: PersonRecord
    @State private var fields: [PersonTagField] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            if !fields.isEmpty {
                Text("Name tag").font(.headline).lineLimit(1).fixedSize()
                ForEach($fields) { $field in
                    VStack(alignment: .leading, spacing: Theme.spaceXS) {
                        TextField(field.field, text: $field.value)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: field.value) { _, value in
                                if value.count > 40 { field.value = String(value.prefix(40)) }
                            }
                        if repeatsName(field.value) {
                            Text("Use a description instead of repeating the name.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("\(field.value.count)/40").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                            if let provenance = field.provenance { AIInfoButton(provenance: provenance, role: "Name tag text") }
                            Spacer()
                            Button("Save") { save(field) }.lineLimit(1).fixedSize()
                                .disabled(field.value.count > 40 || repeatsName(field.value))
                            Button("Clear", role: .destructive) { clear(field) }.lineLimit(1).fixedSize()
                        }
                    }
                }
                Text("The second line of this person’s name tag. A blank field is filled by AI on the next run that shows a tag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: "\(store.profileGeneration)|\(person.key)") {
            fields = []
            guard let database = store.database else { return }
            do {
                let loaded = try await database.personTagFields(personKey: person.key)
                try Task.checkCancellation()
                fields = withStyleFields(loaded)
                error = nil
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Saved rows plus an empty row for every field a tag style names, so the
    /// text can be written here before any run asks AI for it.
    private func withStyleFields(_ saved: [PersonTagField]) -> [PersonTagField] {
        let profile = store.activeProfile
        let styles = [profile.tagStyle(id: nil)] + (profile.tagStyles ?? []).map(\.style)
        let missing = Set(styles.map { TagTextWriter.fieldKey($0.description.field) })
            .subtracting(saved.map(\.field)).sorted()
        return saved + missing.map { PersonTagField(personKey: person.key, field: $0, value: "", provenance: nil) }
    }

    private func repeatsName(_ value: String) -> Bool {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = person.displayName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !text.isEmpty && text.caseInsensitiveCompare(name) == .orderedSame
    }

    private func save(_ field: PersonTagField) {
        guard field.value.count <= 40, !repeatsName(field.value) else { return }
        guard let database = store.database else { return }
        Task {
            do {
                if let value = TagTextWriter.clean(field.value, name: person.displayName) {
                    try await database.savePersonTagField(personKey: person.key, field: field.field, value: value, provenance: nil)
                } else {
                    try await database.clearPersonTagField(personKey: person.key, field: field.field)
                }
                guard store.database === database else { return }
                fields = withStyleFields(try await database.personTagFields(personKey: person.key))
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
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
