import SwiftUI

/// People Roles wizard, review step: one row per person with the proposed
/// role, the model's reason, and a picker to change it. Unchecked rows are
/// left alone; Apply files the rest in one write.
struct PersonRolesReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let proposals: [PersonRoleInference.Proposal]
    let provenance: AIProvenance?

    /// personID → role the user will apply (starts as the proposal).
    @State private var choices: [Int64: PersonCategory] = [:]
    /// personID → whether the row is applied.
    @State private var included: Set<Int64> = []
    @State private var isApplying = false
    @State private var failure: String?

    /// Proposals whose person still exists and still has no category — a
    /// person filed by hand while the job ran is not overwritten.
    private var rows: [(proposal: PersonRoleInference.Proposal, person: PersonRecord)] {
        proposals.compactMap { proposal in
            guard let person = store.people.first(where: { $0.id == proposal.personID }),
                  person.category == nil else { return nil }
            return (proposal, person)
        }
    }

    private var applyCount: Int { rows.count(where: { included.contains($0.person.id) }) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(rows.count == 1 ? "1 proposed role" : "\(rows.count) proposed roles")
                        .font(.headline)
                    if let provenance {
                        AIInfoButton(provenance: provenance, style: .full, role: "Proposed by")
                    }
                }
                Text("Change any role, uncheck people you want to leave as they are, then Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            if rows.isEmpty {
                ContentUnavailableView("Nothing left to file", systemImage: "person.crop.circle.badge.checkmark",
                                       description: Text("Everyone in this run already has a category."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows, id: \.person.id) { row in
                            proposalRow(row.proposal, person: row.person)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            HStack {
                Button("Skip All") { store.jobs.markReviewed(jobID); dismiss() }
                    .help("Close without filing anyone — the proposals are discarded")
                Spacer()
                Button("Cancel") { dismiss() }
                    .help("Close for now — the proposals stay in the status bar")
                Button(applyCount == 1 ? "Apply 1 Role" : "Apply \(applyCount) Roles") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(applyCount == 0 || isApplying)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 320, idealHeight: 480)
        .modalCloseButton { dismiss() }
        .onAppear {
            guard choices.isEmpty else { return }
            for row in rows {
                choices[row.person.id] = row.proposal.category
                included.insert(row.person.id)
            }
        }
    }

    private func proposalRow(_ proposal: PersonRoleInference.Proposal, person: PersonRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Apply", isOn: Binding(
                get: { included.contains(person.id) },
                set: { if $0 { included.insert(person.id) } else { included.remove(person.id) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 12)
            PersonFaceAvatar(person: person, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(person.displayName)
                        .font(.callout.weight(.medium))
                    if person.needsConfirmation {
                        Text("name unconfirmed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker("Role", selection: Binding(
                        get: { choices[person.id] ?? proposal.category },
                        set: { choices[person.id] = $0 })
                    ) {
                        ForEach(PersonCategory.allCases, id: \.self) { category in
                            Label(category.label, systemImage: category.systemImage).tag(category)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    ConfidenceBadge(confidence: proposal.confidence)
                }
                if !proposal.reason.isEmpty {
                    Text(proposal.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !person.descriptor.isEmpty {
                    Text(person.descriptor)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .opacity(included.contains(person.id) ? 1 : 0.55)
    }

    private func apply() {
        let assignments = rows.filter { included.contains($0.person.id) }.map { row in
            (id: row.person.id, category: Optional(choices[row.person.id] ?? row.proposal.category))
        }
        isApplying = true
        failure = nil
        Task {
            do {
                try await store.setPersonCategories(assignments)
                store.jobs.markReviewed(jobID)
                dismiss()
            } catch {
                failure = error.userMessage
                isApplying = false
            }
        }
    }
}

/// "82%" tinted by how sure the model was.
private struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int((confidence * 100).rounded()))%")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .help("How sure the model was, from the evidence it saw")
    }

    private var tint: Color {
        confidence >= 0.75 ? .green : confidence >= 0.5 ? .orange : .secondary
    }
}
