import SwiftUI

/// Opens under a line for one doubtful word: hear it, type what was said,
/// or say the transcriber was right. Nothing is saved until Apply.
struct TranscriptWordFixStrip: View {
    var doubt: TranscriptWordRules.Doubt
    /// How many times the same word is in the spoken text, this one included.
    var occurrences: Int
    var position: String
    var canPlay: Bool
    var onPlay: () -> Void
    var onFix: (String) -> Void
    var onFixAll: (String, _ always: Bool) -> Void
    var onMarkRight: () -> Void
    var onStep: (_ forward: Bool) -> Void
    var onClose: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var heard: String { TranscriptWordRules.parts(doubt.text).core }
    private var typed: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private var changed: Bool { typed != heard }
    /// Fix All and Always Fix need a one-word source and something to put there.
    private var rule: TranscriptCorrectionRules.Rule? {
        changed ? TranscriptCorrectionRules.rule(from: heard, to: typed) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Hear It", systemImage: "play.fill") { onPlay() }
                    .controlSize(.small).fixedSize().disabled(!canPlay)
                    .help("Play a second before and after this word in the panel on the right")
                Text("Heard").foregroundStyle(.secondary).fixedSize()
                TextField("What was said", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, idealWidth: 170, maxWidth: 200)
                    .focused($focused)
                    .onSubmit { if changed { onFix(typed) } }
                    .accessibilityLabel("Correct word")
                if let suggestion = doubt.suggestion {
                    Text("Proofread suggests").foregroundStyle(.secondary).fixedSize()
                    Button(suggestion.to) { text = suggestion.to }
                        .controlSize(.small).fixedSize()
                        .help("Use \"\(suggestion.to)\". \(suggestion.reason)")
                    Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        .truncationMode(.tail).help(suggestion.reason).layoutPriority(-1)
                } else if let confidence = doubt.confidence {
                    Text("The transcriber was \(Int((confidence * 100).rounded()))% sure of this word.")
                        .font(.caption).foregroundStyle(.secondary).truncationMode(.tail).layoutPriority(-1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Fix") { onFix(typed) }
                    .buttonStyle(.borderedProminent).fixedSize().disabled(!changed)
                    .help("Put what you typed in place of this word (Return). An empty field removes the word.")
                Button("Fix All \(occurrences)") { if let rule { onFixAll(rule.to, false) } }
                    .fixedSize().disabled(rule == nil || occurrences < 2)
                    .help("Fix every \"\(heard)\" in this transcript the same way")
                Button("Always Fix This") { if let rule { onFixAll(rule.to, true) } }
                    .fixedSize().disabled(rule == nil)
                    .help("Fix every one here, and fix \"\(heard)\" by itself in every transcript this profile makes from now on")
                Button("Mark Right") { onMarkRight() }
                    .keyboardShortcut(.return, modifiers: .command).fixedSize()
                    .help("The word is right as heard: stop underlining it (Command-Return)")
                Spacer(minLength: 8)
                Text(position).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                ControlGroup {
                    Button("Previous doubtful word", systemImage: "chevron.left") { onStep(false) }
                    Button("Next doubtful word", systemImage: "chevron.right") { onStep(true) }
                }
                .labelStyle(.iconOnly).controlSize(.small).fixedSize()
                Button("Close", systemImage: "xmark") { onClose() }
                    .labelStyle(.iconOnly).controlSize(.small).fixedSize()
                    .keyboardShortcut(.cancelAction)
                    .help("Close without changing this word")
            }
        }
        .lineLimit(1)
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)) }
        .onAppear {
            text = heard
            focused = true
        }
        .onChange(of: doubt.id) {
            text = heard
            focused = true
        }
    }
}

/// The profile's "always fix" pairs, from the Tools menu.
struct TranscriptCorrectionsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""

    private var rules: [TranscriptCorrectionRules.Rule] { store.activeProfile.transcriptCorrections ?? [] }
    private var newRule: TranscriptCorrectionRules.Rule? { TranscriptCorrectionRules.rule(from: from, to: to) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Corrections — \(store.activeProfile.profileName)").font(.headline).lineLimit(1)
            Text("Words fixed by themselves in every transcript this profile makes from now on. Whole words only; capitals and accents in the heard word do not matter. Kept on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                if rules.isEmpty {
                    Text("No corrections yet. Always Fix This, in the Transcript editor, adds one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules, id: \.self) { rule in
                    HStack {
                        Text(rule.from).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(rule.to)
                        Spacer()
                        Button("Delete", systemImage: "minus.circle") { store.deleteTranscriptCorrection(rule) }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .help("Stop fixing \"\(rule.from)\"")
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(rule.from) becomes \(rule.to)")
                }
            }
            .frame(minHeight: 180)
            HStack(spacing: 8) {
                TextField("Heard", text: $from).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Should be", text: $to).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add") { add() }
                    .fixedSize().disabled(newRule == nil)
                    .help("The heard word must be one word; what it should be can be several")
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).fixedSize()
            }
        }
        .padding(Theme.spaceL)
        .frame(width: 460, height: 420)
    }

    private func add() {
        guard let newRule else { return }
        store.alwaysFixTranscriptWord(newRule)
        from = ""
        to = ""
    }
}
