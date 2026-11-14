import SwiftUI

/// The Transcript editor's second row: find in the text, show one speaker's
/// lines, and step through the doubtful words.
struct TranscriptFindRow: View {
    @Binding var searchText: String
    var matchCount: Int
    var currentMatch: Int?
    var focused: FocusState<Bool>.Binding
    @Binding var showsReplace: Bool
    var canReplace: Bool
    /// False where the text cannot be changed (the Express transcript): no Replace.
    var allowsReplace = true
    var speakers: [TranscriptLineFilter.Speaker]
    @Binding var speakerFilter: String?
    var doubtCount: Int
    var onStep: (_ forward: Bool) -> Void
    var onDoubtStep: (_ forward: Bool) -> Void

    private var hasQuery: Bool { !TranscriptSearchRules.query(searchText).isEmpty }

    /// A narrow column (the Express transcript) puts the speakers on a
    /// second row when one row does not hold everything.
    var stacksWhenNarrow = false

    var body: some View {
        if stacksWhenNarrow {
            ViewThatFits(in: .horizontal) {
                row
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { findControls }
                    if speakers.count > 1 {
                        ViewThatFits(in: .horizontal) {
                            speakerPills
                            speakerMenu
                        }
                    }
                }
                .lineLimit(1)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private var findControls: some View {
        searchField
        if hasQuery {
            stepper(disabled: matchCount == 0, previous: "Previous match (Shift-Command-G)", next: "Next match (Command-G)",
                    action: onStep)
            if allowsReplace {
                Toggle("Replace…", isOn: $showsReplace)
                    .toggleStyle(.button).lineLimit(1).fixedSize()
                    .disabled(!canReplace)
                    .help(canReplace ? "Replace this word in the spoken text"
                          : "Apply or discard text typed in Edit Text first, or wait for the save to finish")
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            findControls
            Spacer(minLength: 8)
            // Before the pills, which keep their place at the trailing edge
            // when a filter leaves no doubtful word on show.
            if doubtCount > 0 {
                Text("Doubtful").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(doubtCount.formatted()).fontWeight(.semibold).monospacedDigit().lineLimit(1).fixedSize()
                stepper(disabled: false, previous: "Previous doubtful word", next: "Next doubtful word", action: onDoubtStep)
            }
            if speakers.count > 1 {
                ViewThatFits(in: .horizontal) {
                    speakerPills
                    speakerMenu
                }
            }
        }
        .lineLimit(1)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find in transcript", text: $searchText)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit { onStep(true) }
                .accessibilityLabel("Find in transcript")
            if hasQuery {
                Text(matchCount == 0 ? "No matches" : "\((currentMatch ?? 0) + 1) of \(matchCount)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                Button("Clear", systemImage: "xmark.circle.fill") { searchText = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 130, idealWidth: 300, maxWidth: 320)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .help(allowsReplace ? "Find text in the lines on show and their translations, ignoring case and accents (Command-F)"
              : "Find text in the lines on show, ignoring case and accents. Return goes to the next match.")
    }

    private func stepper(disabled: Bool, previous: String, next: String, action: @escaping (Bool) -> Void) -> some View {
        ControlGroup {
            Button(previous, systemImage: "chevron.left") { action(false) }.help(previous)
            Button(next, systemImage: "chevron.right") { action(true) }.help(next)
        }
        .labelStyle(.iconOnly).controlSize(.small).fixedSize()
        .disabled(disabled)
    }

    private var speakerPills: some View {
        HStack(spacing: 6) {
            Text("Speaker").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            pill(nil, title: "All", count: nil)
            ForEach(speakers) { speaker in
                pill(speaker.name, title: speaker.name, count: speaker.count)
            }
        }
    }

    private func pill(_ name: String?, title: String, count: Int?) -> some View {
        let selected = speakerFilter == name
        let color = name.map { SpeakerColors.color(for: $0) } ?? Color.primary
        return Button {
            // A second click on the speaker on show goes back to everyone.
            speakerFilter = selected ? nil : name
        } label: {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold)
                if let count { Text(count.formatted()).monospacedDigit().opacity(0.75) }
            }
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(color.opacity(name == nil ? 0.10 : 0.18), in: Capsule())
            .overlay { if selected { Capsule().strokeBorder(color, lineWidth: 1.5) } }
            .opacity(speakerFilter == nil || selected || name == nil ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(name == nil ? "Show every speaker's lines"
              : selected ? "Showing only \(title)'s lines. Click to show everyone."
              : "Show only \(title)'s lines")
        .accessibilityLabel(name == nil ? "All speakers" : "\(title), \(count ?? 0) lines")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var speakerMenu: some View {
        Picker("Speaker", selection: $speakerFilter) {
            Text("All speakers").tag(String?.none)
            ForEach(speakers) { speaker in
                Text("\(speaker.name) (\(speaker.count))").tag(Optional(speaker.name))
            }
        }
        .lineLimit(1).fixedSize()
        .help("Show only one speaker's lines")
    }
}

/// Under the find row while Replace is on: the replacement and what to do with it.
struct TranscriptReplaceStrip: View {
    var query: String
    @Binding var replaceText: String
    /// The current match is a whole word of the spoken text.
    var canReplaceCurrent: Bool
    /// The typed text is one whole word, so it can be replaced everywhere and remembered.
    var allCount: Int?
    var note: String?
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onAlways: () -> Void

    private var hasReplacement: Bool { !replaceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Text("Replace with").foregroundStyle(.secondary).fixedSize()
            TextField("New word", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 220, maxWidth: 240)
                .onSubmit { if canReplaceCurrent, hasReplacement { onReplace() } }
                .accessibilityLabel("Replace with")
            Button("Replace") { onReplace() }
                .fixedSize().disabled(!canReplaceCurrent || !hasReplacement)
                .help(canReplaceCurrent ? "Replace this match and go to the next"
                      : "The current match is not a whole word of the spoken text. Use Edit Text for part of a word or a translation.")
            Button(allCount.map { "Replace All \($0)" } ?? "Replace All") { onReplaceAll() }
                .fixedSize().disabled((allCount ?? 0) == 0 || !hasReplacement)
                .help(allCount == nil ? "Replace All works on one whole word: type a single word in the search field"
                      : "Replace every \"\(query)\" in the spoken text, whole words only")
            Button("Always Fix This") { onAlways() }
                .fixedSize().disabled(allCount == nil || !hasReplacement)
                .help("Replace every one here, and fix \"\(query)\" by itself in every transcript this profile makes from now on. Tools has the list.")
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).truncationMode(.tail).help(note)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}
