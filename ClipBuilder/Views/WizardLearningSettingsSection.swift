import SwiftUI

/// Profile-wide rules learned from reel reviews. This lives with AI settings
/// rather than in the run form because every Wizard run receives the same
/// rules automatically.
struct WizardLearningSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var newLessonText = ""

    var body: some View {
        Section("Learned Rules") {
            Text("These rules are applied to every AI Wizard plan. Review reels in the Library to teach the wizard, then manage the resulting rules here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.lessons.isEmpty {
                Text("No learned rules yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.lessons) { lesson in
                    WizardLessonRow(lesson: lesson)
                }
            }

            HStack {
                TextField("Add a permanent rule", text: $newLessonText, axis: .vertical)
                    .onSubmit(addLesson)
                Button("Add", action: addLesson)
                    .disabled(newLessonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Button("Distill Rules from Reviews", systemImage: "sparkles") {
                    store.distillLessons()
                }
                .disabled(store.isDistillingLessons)
                if store.isDistillingLessons {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func addLesson() {
        store.addLesson(text: newLessonText)
        newLessonText = ""
    }
}

private struct WizardLessonRow: View {
    @Environment(AppStore.self) private var store
    let lesson: WizardLesson

    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spaceS) {
            Button {
                store.updateLesson(lesson, pinned: !lesson.pinned)
            } label: {
                Label(lesson.pinned ? "Unpin Rule" : "Pin Rule",
                      systemImage: lesson.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(lesson.pinned ? .orange : .secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(lesson.pinned ? "Pinned rules are never replaced by distillation"
                                : "Pin this rule so distillation never replaces it")

            VStack(alignment: .leading, spacing: Theme.spaceXS) {
                TextField("Rule", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        store.updateLesson(lesson, text: text)
                    }
                if !lesson.evidence.isEmpty || lesson.provenance != nil {
                    HStack(spacing: Theme.spaceXS) {
                        if let provenance = lesson.provenance {
                            ProvenanceBadge(provenance: provenance, role: "Distilled by", size: 11)
                        }
                        if !lesson.evidence.isEmpty {
                            Text(lesson.evidence)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            Button("Delete Rule", systemImage: "trash", role: .destructive) {
                store.deleteLesson(lesson)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Delete this learned rule")
        }
        .onAppear { text = lesson.text }
        .onChange(of: lesson.text) { _, value in text = value }
    }
}
