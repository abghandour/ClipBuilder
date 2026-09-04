import SwiftUI

/// Source choice is intentionally a separate sheet: it is occasionally
/// important, but should not bury the everyday "make a reel" decisions.
struct WizardSourcePickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Binding var curatedOnly: Bool
    @Binding var limitToSelection: Bool
    @Binding var selectedRunIDsRaw: String
    @Binding var sourcePeopleRaw: String

    private var selectedRunIDs: Set<Int64> {
        Set(selectedRunIDsRaw.split(separator: ",").compactMap { Int64($0) })
    }

    private var selectedPeople: Set<String> {
        Set(sourcePeopleRaw.split(separator: ",").map(String.init))
    }

    private var scope: WizardSourceScope {
        if limitToSelection { return .batches }
        return curatedOnly ? .curated : .all
    }

    private var scopeBinding: Binding<WizardSourceScope> {
        Binding(
            get: { scope },
            set: { newScope in
                switch newScope {
                case .all:
                    curatedOnly = false
                    limitToSelection = false
                case .curated:
                    curatedOnly = true
                    limitToSelection = false
                case .batches:
                    curatedOnly = false
                    limitToSelection = true
                }
            }
        )
    }

    private var eligiblePeople: [PersonRecord] {
        guard scope == .batches, !selectedRunIDs.isEmpty else { return store.people }
        var tags = Set<String>()
        for runID in selectedRunIDs {
            tags.formUnion(store.sceneIndex.personTagsByRun[runID] ?? [])
        }
        return store.people.filter { tags.contains($0.tag) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Use scenes from") {
                    Picker("Source", selection: scopeBinding) {
                        ForEach(WizardSourceScope.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    Text(sourceExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if scope == .batches {
                    Section("Analyze Batches") {
                        if store.analysisRuns.isEmpty {
                            Text("No analyze batches are available yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.analysisRuns) { run in
                                batchRow(run)
                            }
                        }
                    }
                }

                if !eligiblePeople.isEmpty {
                    Section("Feature people") {
                        HStack {
                            Text(selectedPeople.isEmpty ? "Anyone in the selected scenes" : "\(selectedPeople.count) selected")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") { sourcePeopleRaw = "" }
                                .disabled(selectedPeople.isEmpty)
                        }

                        ForEach(eligiblePeople) { person in
                            Toggle(isOn: personBinding(person.key)) {
                                Text(person.displayName)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private var sourceExplanation: String {
        switch scope {
        case .all:
            "The wizard can choose any analyzed scene in this profile."
        case .curated:
            "Only scenes you or the Curator have promoted are eligible."
        case .batches:
            "Choose one or more Analyze batches below."
        }
    }

    private var summary: String {
        switch scope {
        case .all:
            "All analyzed scenes are eligible"
        case .curated:
            "Only curated scenes are eligible"
        case .batches:
            selectedRunIDs.isEmpty
                ? "Choose at least one Analyze batch"
                : "\(selectedRunIDs.count) Analyze batch\(selectedRunIDs.count == 1 ? "" : "es") selected"
        }
    }

    private func batchRow(_ run: AnalysisRun) -> some View {
        let selected = selectedRunIDs.contains(run.id)
        return Button {
            var ids = selectedRunIDs
            if selected {
                ids.remove(run.id)
            } else {
                ids.insert(run.id)
            }
            selectedRunIDsRaw = ids.sorted().map(String.init).joined(separator: ",")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name.isEmpty ? run.videoFilename : run.name)
                        .foregroundStyle(.primary)
                    Text("\(run.videoFilename) · \(run.sceneCount) scenes" + (run.hasTranscript ? " · transcript" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func personBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { selectedPeople.contains(key) },
            set: { selected in
                var people = selectedPeople
                if selected {
                    people.insert(key)
                } else {
                    people.remove(key)
                }
                sourcePeopleRaw = people.sorted().joined(separator: ",")
            }
        )
    }
}
