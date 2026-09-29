import SwiftUI

/// People Roles wizard, setup step: which people lack a category and which
/// model reasons about them. Run starts a background job; the proposals come
/// back through the job review sheet, where each one is confirmed or changed
/// before it is saved.
struct PersonRolesWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var modelTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))

    private var targets: [PersonRecord] {
        store.uncategorizedPeople.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Infer People Roles")
                .font(.title3.bold())
            Text("Reads the videos each person appears in, the tags and narratives of their scenes, and what they say in interviews and podcasts, then proposes a role — fighter, trainer, press, official, fan, staff or other. You review every proposal and can change it before anything is saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(targets.count == 1 ? "1 person without a category" : "\(targets.count) people without a category")
                .font(.callout.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(targets) { person in
                        VStack(spacing: 4) {
                            PersonFaceAvatar(person: person, size: 40)
                            Text(person.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 64)
                        .help(person.descriptor)
                    }
                }
                .padding(2)
            }

            HStack {
                ModelPicker(title: "Model", task: "roles", selection: $modelTag,
                            availableProviders: availableProviders)
                    .fixedSize()
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Infer Roles") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 300)
        .appJobSetupPresentation()
        .modalCloseButton { dismiss() }
        .task {
            availableProviders = await ModelPicker.probeAvailability(ai: store.ai)
            if modelTag.isEmpty {
                modelTag = ModelPicker.bestAvailableTag(for: "roles", available: availableProviders)
            }
        }
    }

    private func run() {
        let store = store
        let people = targets
        let (provider, model) = ModelPicker.parse(modelTag)
        store.jobs.start(.personRoles, title: "People Roles — \(people.count) people",
                         project: store.activeProject, profileGeneration: store.profileGeneration) { log in
            let result = try await store.inferPersonRoles(people: people, provider: provider, model: model, log: log)
            return .personRoles(proposals: result.value, provenance: result.provenance)
        }
        dismiss()
    }
}
