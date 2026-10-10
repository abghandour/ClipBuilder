import SwiftUI

/// A searchable people list; the presenter owns all changes and dismissal.
struct PersonPickerPopover: View {
    let people: [PersonRecord]
    let title: String
    let onPick: (PersonRecord) -> Void
    var onNewPerson: ((String) -> Void)?
    var onNobody: (() -> Void)?
    var nobodyTitle: String = "Nobody (remove from this video)"

    @State private var filter = ""
    @State private var hoveredPersonID: Int64?
    @FocusState private var filterFocused: Bool

    var body: some View {
        let matches = Self.filtered(people, query: filter)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit {
                    if let first = matches.first {
                        onPick(first)
                    } else {
                        onNewPerson?(filter)
                    }
                }
            if matches.isEmpty {
                Text("No one named “\(filter)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { person in
                            personRow(person)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            if let onNewPerson {
                Button {
                    onNewPerson(filter)
                } label: {
                    Label("New Person…", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let onNobody {
                Button(action: onNobody) {
                    Text(nobodyTitle)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { filterFocused = true }
    }

    private func personRow(_ person: PersonRecord) -> some View {
        Button {
            onPick(person)
        } label: {
            HStack(spacing: 8) {
                PersonFaceAvatar(person: person, size: 28)
                Text(person.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if person.isUnnamed {
                    Text("unnamed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoveredPersonID == person.id ? Color.primary.opacity(0.06) : .clear)
        .clipShape(.rect(cornerRadius: 6))
        .onHover { hovered in
            if hovered {
                hoveredPersonID = person.id
            } else if hoveredPersonID == person.id {
                hoveredPersonID = nil
            }
        }
    }

    /// Prefix matches lead; both groups retain the caller's ordering.
    nonisolated static func filtered(_ people: [PersonRecord], query: String) -> [PersonRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return people }
        let query = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var prefixes: [PersonRecord] = []
        var substrings: [PersonRecord] = []
        for person in people {
            let names = [person.displayName, person.name, person.keyName ?? ""].map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            if names.contains(where: { $0.hasPrefix(query) }) {
                prefixes.append(person)
            } else if names.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                substrings.append(person)
            }
        }
        return prefixes + substrings
    }
}
