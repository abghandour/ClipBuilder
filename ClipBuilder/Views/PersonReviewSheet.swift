import SwiftUI

/// End-of-analysis review: everyone the run detected who wasn't already in
/// the registry. Each person shows the frame they were first seen in; the
/// user names them (pre-filled from the video's filename when the analyzer
/// spotted a match) or folds them into a previously detected person.
struct PersonReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PeopleReviewRequest

    /// key → typed name (pre-filled with the analyzer's suggestion).
    @State private var names: [String: String] = [:]
    /// key → existing person id this detection should merge into.
    @State private var mergeTargets: [String: Int64] = [:]
    /// The pre-filled state — Skip All only warns when the user changed it.
    @State private var prefilledNames: [String: String] = [:]
    @State private var prefilledMerges: [String: Int64] = [:]
    @State private var confirmSkip = false

    /// Merge candidates: everyone except the person's own row. Other new
    /// people stay listed — the AI occasionally splits one real person into
    /// two keys, and folding one into the other right here fixes that.
    private func mergeCandidates(excluding person: DetectedNewPerson) -> [PersonRecord] {
        store.people.filter { $0.key != person.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                // "To name", not "new": known-but-unnamed people join the
                // review when analysis lifts their name from on-screen
                // graphics or the filename.
                Text(request.people.count == 1
                     ? "1 person to name"
                     : "\(request.people.count) people to name")
                    .font(.headline)
                Text("Name each person, or mark them as someone already detected — their scenes merge under that identity. Skip anyone you don't recognize; they stay editable in People.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(request.people) { person in
                        personRow(person)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Skip All") {
                    if names != prefilledNames || mergeTargets != prefilledMerges {
                        confirmSkip = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .help("Leave everyone unnamed — the People section lists them for later")
                Spacer()
                Button("Done") {
                    store.applyPeopleReview(names: names, merges: mergeTargets)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 360, idealHeight: 520)
        .confirmationDialog("Discard the names you entered?", isPresented: $confirmSkip) {
            Button("Discard and Skip", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Skipping leaves everyone unnamed — the names and merges you set here are not applied.")
        }
        .onAppear {
            for person in request.people {
                guard let suggested = person.suggestedName else { continue }
                // A suggestion matching an existing name is probably the same
                // person seen again under a new key — preselect the merge.
                if let existing = store.people.first(where: {
                    $0.key != person.key && !$0.name.isEmpty
                        && $0.name.caseInsensitiveCompare(suggested) == .orderedSame
                }) {
                    mergeTargets[person.key] = existing.id
                }
                names[person.key] = suggested
            }
            prefilledNames = names
            prefilledMerges = mergeTargets
        }
    }

    @ViewBuilder
    private func personRow(_ person: DetectedNewPerson) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VideoThumbnail(url: person.videoURL, time: person.sampleTime)
                .frame(width: 68, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                if !person.descriptor.isEmpty {
                    Text(person.descriptor)
                        .font(.callout)
                        .lineLimit(3)
                }
                Text("First seen in \(person.videoFilename)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField(person.suggestedName.map { "Name (filename suggests \($0))" }
                                  ?? "Name this person",
                              text: Binding(
                                  get: { names[person.key] ?? "" },
                                  set: { names[person.key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(mergeTargets[person.key] != nil)

                    let candidates = mergeCandidates(excluding: person)
                    if !candidates.isEmpty {
                        Menu(mergeLabel(for: person)) {
                            Button("New person") { mergeTargets[person.key] = nil }
                            Divider()
                            ForEach(candidates) { candidate in
                                Button(candidate.displayName) {
                                    mergeTargets[person.key] = candidate.id
                                }
                            }
                        }
                        .fixedSize()
                        .help("This is someone already detected — merge their scenes under that identity")
                    }
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func mergeLabel(for person: DetectedNewPerson) -> String {
        guard let targetID = mergeTargets[person.key],
              let target = store.people.first(where: { $0.id == targetID }) else {
            return "New person"
        }
        return "Same as \(target.displayName)"
    }
}
