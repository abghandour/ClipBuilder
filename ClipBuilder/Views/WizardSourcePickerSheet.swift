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

    @State private var batchFilter = ""

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

    /// Batches matching the filter, newest first.
    private var filteredRuns: [AnalysisRun] {
        let needle = batchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let runs = store.analysisRuns
        guard !needle.isEmpty else { return runs }
        return runs.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.videoFilename.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.spaceXS) {
                    Text("Sources")
                        .font(.headline)
                    Text("Which scenes the wizard may plan from, and who should be in them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.spaceL)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceL) {
                    // Scope
                    VStack(alignment: .leading, spacing: Theme.spaceS) {
                        Picker("Use scenes from", selection: scopeBinding) {
                            ForEach(WizardSourceScope.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(sourceExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Batches — multi-select with a filter.
                    if scope == .batches {
                        VStack(alignment: .leading, spacing: Theme.spaceS) {
                            HStack(spacing: Theme.spaceS) {
                                TextField("Filter batches", text: $batchFilter)
                                    .textFieldStyle(.roundedBorder)
                                Button("Select All") { select(filteredRuns.map(\.id), on: true) }
                                    .controlSize(.small)
                                    .disabled(filteredRuns.isEmpty)
                                Button("Clear") { selectedRunIDsRaw = "" }
                                    .controlSize(.small)
                                    .disabled(selectedRunIDs.isEmpty)
                            }
                            if store.analysisRuns.isEmpty {
                                Text("No analyze batches are available yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if filteredRuns.isEmpty {
                                Text("No batches match \"\(batchFilter)\".")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(filteredRuns) { run in
                                        batchRow(run)
                                        if run.id != filteredRuns.last?.id { Divider() }
                                    }
                                }
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: Theme.mediaRadius))
                            }
                        }
                    }

                    // People — the pinned-contact row: tap a face to toggle.
                    if !eligiblePeople.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spaceS) {
                            HStack {
                                Text("Feature people")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(selectedPeople.isEmpty ? "Anyone" : "\(selectedPeople.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    personChoice(label: "Anyone", isSelected: selectedPeople.isEmpty,
                                                 help: "Use scenes regardless of who is in them") {
                                        sourcePeopleRaw = ""
                                    } avatar: {
                                        Circle()
                                            .fill(.quaternary)
                                            .overlay {
                                                Image(systemName: "person.2.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(width: 44, height: 44)
                                    }
                                    ForEach(eligiblePeople) { person in
                                        personChoice(label: person.displayName,
                                                     isSelected: selectedPeople.contains(person.key),
                                                     help: "Only use scenes featuring \(person.displayName) — Center Stage tracks them too") {
                                            togglePerson(person.key)
                                        } avatar: {
                                            PersonFaceAvatar(person: person, size: 44)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            Text(selectedPeople.isEmpty
                                 ? "Nobody picked: any scene qualifies."
                                 : "Only scenes featuring the picked people are used, combined with the batch filter. Center Stage tracks them in wide footage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Theme.spaceL)
            }

            Divider()
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.spaceL)
            .padding(.vertical, Theme.spaceM)
        }
        .frame(width: 600, height: 640)
        .modalCloseButton { dismiss() }
    }

    private var sourceExplanation: String {
        switch scope {
        case .all:
            "The wizard can choose any analyzed scene in this profile."
        case .curated:
            "Only scenes you or the Curator have promoted are eligible."
        case .batches:
            "Pick one or more Analyze batches. People shown below are the ones tagged in them."
        }
    }

    private var summary: String {
        var text: String
        switch scope {
        case .all:
            text = "All analyzed scenes are eligible"
        case .curated:
            text = "Only curated scenes are eligible"
        case .batches:
            text = selectedRunIDs.isEmpty
                ? "Choose at least one Analyze batch"
                : "\(selectedRunIDs.count) Analyze batch\(selectedRunIDs.count == 1 ? "" : "es") selected"
        }
        if !selectedPeople.isEmpty {
            text += " · \(selectedPeople.count) \(selectedPeople.count == 1 ? "person" : "people") featured"
        }
        return text
    }

    private func select(_ ids: [Int64], on: Bool) {
        var current = selectedRunIDs
        if on { current.formUnion(ids) } else { current.subtract(ids) }
        selectedRunIDsRaw = current.sorted().map(String.init).joined(separator: ",")
    }

    private func togglePerson(_ key: String) {
        var people = selectedPeople
        if people.contains(key) { people.remove(key) } else { people.insert(key) }
        sourcePeopleRaw = people.sorted().joined(separator: ",")
    }

    private func batchRow(_ run: AnalysisRun) -> some View {
        let selected = selectedRunIDs.contains(run.id)
        return Button {
            select([run.id], on: !selected)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VideoThumbnail(url: run.videoURL, time: 1, cornerRadius: 3)
                    .frame(width: 40, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name.isEmpty ? run.videoFilename : run.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(run.videoFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 8) {
                    Text("\(run.sceneCount)")
                        .monospacedDigit()
                        .help("\(run.sceneCount) scenes")
                    Image(systemName: "text.quote")
                        .opacity(run.hasTranscript ? 1 : 0)
                        .help(run.hasTranscript ? "Transcript ready" : "")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.spaceS)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear)
    }

    /// One item in the people row: avatar with a selection ring and
    /// checkmark badge, name underneath.
    private func personChoice(label: String, isSelected: Bool, help: String,
                              action: @escaping () -> Void,
                              @ViewBuilder avatar: () -> some View) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                avatar()
                    .overlay {
                        Circle()
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(.background))
                        }
                    }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
