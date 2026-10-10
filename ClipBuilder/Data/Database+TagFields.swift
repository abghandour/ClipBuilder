import Foundation

nonisolated struct PersonTagField: Sendable, Identifiable, Hashable {
    var personKey: String
    var field: String
    var value: String
    var provenance: AIProvenance?
    var source: String? = nil
    var id: String { personKey + ":" + field }
}

extension Database {
    func personTagFields(personKey: String? = nil) throws -> [PersonTagField] {
        let sql = "SELECT person_key, field, value, provenance, source FROM person_tag_fields"
            + (personKey == nil ? "" : " WHERE person_key = ?") + " ORDER BY field"
        return try connection.query(sql, personKey.map { [.text($0)] } ?? []).map { row in
            PersonTagField(personKey: row["person_key"]?.stringValue ?? "",
                field: row["field"]?.stringValue ?? "Role", value: row["value"]?.stringValue ?? "",
                provenance: row["provenance"]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(AIProvenance.self, from: $0) },
                source: row["source"]?.stringValue)
        }
    }

    func personTagFieldsByPerson() throws -> [String: [PersonTagField]] {
        Dictionary(grouping: try personTagFields(), by: \.personKey)
    }

    func savePersonTagField(personKey: String, field: String, value: String, provenance: AIProvenance?,
                            source: String? = nil) throws {
        let json = try provenance.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try connection.execute("""
            INSERT INTO person_tag_fields (person_key, field, value, provenance, source) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(person_key, field) DO UPDATE SET value = excluded.value, provenance = excluded.provenance, source = excluded.source
            """, [.text(personKey), .text(TagTextWriter.fieldKey(field)), .text(value), json.map(SQLValue.text) ?? .null,
                  source.map(SQLValue.text) ?? .null])
    }

    func clearPersonTagField(personKey: String, field: String) throws {
        try connection.execute("DELETE FROM person_tag_fields WHERE person_key = ? AND field = ?",
                               [.text(personKey), .text(TagTextWriter.fieldKey(field))])
    }

    /// Commit the checked review rows together. Deleted people and categories filed
    /// while research was running are left alone.
    func applyPersonResearch(_ outcomes: [PersonResearchOutcome], proposalIDs: Set<String>,
                             categoryKeys: Set<String>) throws {
        try connection.transaction {
            let people = try fetchPeople()
            for outcome in outcomes {
                guard let person = people.first(where: { $0.key == outcome.personKey }) else { continue }
                for proposal in outcome.proposals where proposalIDs.contains(proposal.id)
                    && proposal.personKey == person.key {
                    let value: String
                    if TagTextWriter.isHandleField(proposal.field) {
                        guard let handle = TagTextWriter.normalizeHandle(proposal.value, field: proposal.field) else {
                            try clearPersonTagField(personKey: person.key, field: proposal.field)
                            continue
                        }
                        value = handle
                    } else {
                        value = proposal.value
                    }
                    try savePersonTagField(personKey: person.key, field: proposal.field, value: value,
                                           provenance: outcome.provenance, source: proposal.source)
                }
                if person.category == nil, categoryKeys.contains(person.key), let category = outcome.category {
                    try setPersonCategory(id: person.id, category: category)
                }
            }
        }
    }

    /// Tag copy is separate from the analyzer's visual description.
    func tagText(field: String) throws -> [String: String] {
        let fields = try personTagFields().filter { $0.field == TagTextWriter.fieldKey(field) }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.personKey, $0.value) })
    }
}
