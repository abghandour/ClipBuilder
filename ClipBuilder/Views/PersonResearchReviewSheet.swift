import SwiftUI

struct PersonResearchReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let generation: Int
    let outcomes: [PersonResearchOutcome]

    @State private var included: Set<String> = []
    @State private var categories: Set<String> = []
    @State private var current: [String: PersonTagField] = [:]
    @State private var initialized = false
    @State private var loaded = false
    @State private var isApplying = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Person Research").font(.headline).lineLimit(1).fixedSize()
                Text("Review the sources and uncheck any values you want to leave unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(outcomes, id: \.personKey) { outcome in
                        if let person = store.people.first(where: { $0.key == outcome.personKey }) {
                            personBlock(outcome, person: person)
                        }
                    }
                }
                .padding(.horizontal)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                Button("Skip All") { store.jobs.markReviewed(jobID); dismiss() }
                    .lineLimit(1).fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.lineLimit(1).fixedSize()
                Button("Apply") { apply() }
                    .lineLimit(1).fixedSize()
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!loaded || (included.isEmpty && categories.isEmpty))
            }
            .padding()
            .disabled(isApplying)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 340, idealHeight: 500)
        .modalCloseButton { if !isApplying { dismiss() } }
        .task(id: store.personTagFieldsVersion) { await load() }
    }

    private func personBlock(_ outcome: PersonResearchOutcome, person: PersonRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PersonFaceAvatar(person: person, size: 28)
                Text(person.displayName).font(.headline).lineLimit(1)
                if let provenance = outcome.provenance {
                    AIInfoButton(provenance: provenance, role: "Person research")
                }
            }
            ForEach(outcome.proposals) { proposal in
                proposalRow(proposal)
            }
            if person.category == nil, let category = outcome.category {
                Toggle("Category: \(category.label)", isOn: selection(person.key, category: true))
                    .toggleStyle(.checkbox).lineLimit(1).fixedSize()
            }
            if outcome.proposals.isEmpty && outcome.category == nil {
                Text("No supported values found.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .disabled(isApplying)
    }

    private func proposalRow(_ proposal: PersonResearchProposal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: selection(proposal.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.field).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            proposedValues(proposal)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            proposedValues(proposal)
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                if let handle = TagTextWriter.normalizeHandle(proposal.value, field: proposal.field),
                   let url = URL(string: "https://\(proposal.field == "Instagram" ? "instagram.com" : "x.com")/\(handle)") {
                    Link(destination: url) {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .lineLimit(1).fixedSize()
                }
                if let url = PersonResearch.sourceURL(proposal.source) {
                    Link("Source", destination: url).lineLimit(1).fixedSize()
                        .help(url.absoluteString)
                }
                if let asOf = proposal.asOf {
                    Text("as of \(asOf)").lineLimit(1).fixedSize()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private func proposedValues(_ proposal: PersonResearchProposal) -> some View {
        if let old = current[proposal.id]?.value, !old.isEmpty, old != proposal.value {
            Text(TagTextWriter.normalizeHandle(old, field: proposal.field).map { "@\($0)" } ?? old)
                .strikethrough().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Image(systemName: "arrow.right").accessibilityLabel("changes to")
        }
        Text(TagTextWriter.normalizeHandle(proposal.value, field: proposal.field).map { "@\($0)" } ?? proposal.value)
            .lineLimit(1).fixedSize()
    }

    private func selection(_ key: String, category: Bool = false) -> Binding<Bool> {
        Binding(get: { category ? categories.contains(key) : included.contains(key) }, set: { value in
            if category {
                if value { categories.insert(key) } else { categories.remove(key) }
            } else {
                if value { included.insert(key) } else { included.remove(key) }
            }
        })
    }

    private func load() async {
        guard generation == store.profileGeneration, let database = store.database else { return }
        do {
            let fields = try await database.personTagFields()
            try Task.checkCancellation()
            guard generation == store.profileGeneration, store.database === database else { return }
            current = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
            if !initialized {
                included = Set(outcomes.flatMap(\.proposals).map(\.id))
                categories = Set(outcomes.filter { $0.category != nil }.map(\.personKey))
                initialized = true
            }
            loaded = true
            failure = nil
        } catch is CancellationError {
        } catch { failure = error.userMessage }
    }

    private func apply() {
        isApplying = true
        failure = nil
        Task {
            do {
                try await store.applyPersonResearch(outcomes, proposalIDs: included,
                                                    categoryKeys: categories, generation: generation)
                store.jobs.markReviewed(jobID)
                dismiss()
            } catch {
                failure = error.userMessage
                isApplying = false
            }
        }
    }
}
