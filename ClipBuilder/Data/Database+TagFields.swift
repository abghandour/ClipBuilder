import Foundation

nonisolated struct PersonTagField: Sendable, Identifiable, Hashable {
    var personKey: String
    var field: String
    var value: String
    var provenance: AIProvenance?
    var id: String { personKey + ":" + field }
}

extension Database {
    func personTagFields(personKey: String? = nil) throws -> [PersonTagField] {
        let sql = "SELECT person_key, field, value, provenance FROM person_tag_fields"
            + (personKey == nil ? "" : " WHERE person_key = ?") + " ORDER BY field"
        return try connection.query(sql, personKey.map { [.text($0)] } ?? []).map { row in
            PersonTagField(personKey: row["person_key"]?.stringValue ?? "",
                field: row["field"]?.stringValue ?? "Role", value: row["value"]?.stringValue ?? "",
                provenance: row["provenance"]?.stringValue.flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(AIProvenance.self, from: $0) })
        }
    }

    func savePersonTagField(personKey: String, field: String, value: String, provenance: AIProvenance?) throws {
        let json = try provenance.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try connection.execute("""
            INSERT INTO person_tag_fields (person_key, field, value, provenance) VALUES (?, ?, ?, ?)
            ON CONFLICT(person_key, field) DO UPDATE SET value = excluded.value, provenance = excluded.provenance
            """, [.text(personKey), .text(TagTextWriter.fieldKey(field)), .text(value), json.map(SQLValue.text) ?? .null])
    }

    func clearPersonTagField(personKey: String, field: String) throws {
        try connection.execute("DELETE FROM person_tag_fields WHERE person_key = ? AND field = ?",
                               [.text(personKey), .text(TagTextWriter.fieldKey(field))])
    }

    /// Tag copy is separate from the analyzer's visual description.
    func tagText(field: String) throws -> [String: String] {
        let fields = try personTagFields().filter { $0.field == TagTextWriter.fieldKey(field) }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.personKey, $0.value) })
    }
}
