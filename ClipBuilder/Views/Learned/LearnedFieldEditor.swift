import SwiftUI

/// A field on the AI Lessons page that is edited in place. Drafts always
/// start from the raw profile value, never from the displayed (redacted) text.
nonisolated enum LearnedFieldEdit: Identifiable, Hashable, Sendable {
    case houseStyle, hookStyle, layout, rubric
    case category(key: String)
    case hashtags

    var id: String {
        switch self {
        case .category(let key): "category:" + key
        default: title
        }
    }
    var title: String {
        switch self {
        case .houseStyle: "House style"
        case .hookStyle: "Hook style"
        case .layout: "Layout preference"
        case .rubric: "Taste rubric"
        case .category: "Taste category"
        case .hashtags: "Pinned hashtags"
        }
    }
    var help: String {
        switch self {
        case .houseStyle: "What all your reels have in common. The Wizard and the critic read it on every run."
        case .hookStyle, .layout: "Used by the Wizard only while Learned editing defaults is on. Opening Instagram › Editing performance may rewrite it from your results."
        case .rubric: "What a keeper moment looks like. Read by the Wizard, the critic and the highlight tag."
        case .category: "Rename the category or rewrite its rubric. Its key, example frames and study count stay."
        case .hashtags: "Comma separated. Seed the caption's hashtags when captions use local hashtags."
        }
    }
    /// Which learned field ids on the page open this editor.
    static func forItem(field: String, id: String) -> LearnedFieldEdit? {
        switch field {
        case "houseStyle": .houseStyle
        case "hookStyle": .hookStyle
        case "layout": .layout
        case "rubric": .rubric
        case "category": .category(key: id)
        case "hashtag": .hashtags
        default: nil
        }
    }

    /// Reads the draft from the profile.
    func draft(from profile: BrandProfile) -> Draft {
        switch self {
        case .houseStyle: Draft(text: profile.houseStyle)
        case .hookStyle: Draft(text: profile.learnedHookStyle)
        case .layout: Draft(text: profile.learnedLayoutPreference)
        case .rubric: Draft(text: profile.tasteRubric)
        case .category(let key):
            profile.tasteCategories.first { $0.key == key }.map { Draft(label: $0.label, text: $0.rubric) } ?? Draft()
        case .hashtags: Draft(list: profile.hashtags)
        }
    }
    /// Writes the draft back. Only the edited field changes.
    func apply(_ draft: Draft, to profile: BrandProfile) -> BrandProfile {
        var profile = profile
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .houseStyle: profile.houseStyle = text
        case .hookStyle: profile.learnedHookStyle = text
        case .layout: profile.learnedLayoutPreference = text
        case .rubric: profile.tasteRubric = text
        case .category(let key):
            return LearnedEditing.editCategory(key, label: draft.label, rubric: draft.text, profile: profile)
        case .hashtags: profile.hashtags = draft.list
        }
        return profile
    }

    /// The save step, kept pure so the profile-switch guard is testable: nil
    /// means the active profile changed since the editor opened.
    func commit(_ draft: Draft, to profile: BrandProfile, openedOn profileName: String) -> BrandProfile? {
        guard profile.profileName == profileName else { return nil }
        return apply(draft, to: profile)
    }

    struct Draft: Equatable, Sendable {
        var label = ""
        var text = ""
        var list: [String] = []
    }
}

/// Transactional editor: Save writes, Cancel discards, a profile switch while
/// open discards too.
@MainActor
struct LearnedFieldEditorSheet: View {
    @Environment(AppStore.self) private var store
    let edit: LearnedFieldEdit
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LearnedFieldEdit.Draft()
    @State private var profileName = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(edit.title).font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded)
            }
            Text(edit.help).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            switch edit {
            case .category:
                TextField("Name", text: $draft.label).textFieldStyle(.roundedBorder)
                TextEditor(text: $draft.text).font(.body).frame(minHeight: 160)
                    .accessibilityLabel("Rubric")
            case .hashtags:
                CommaListField("Hashtags", items: $draft.list, lowercased: true,
                               prompt: Text("mma, ufc, knockout"))
                    .textFieldStyle(.roundedBorder)
            default:
                TextEditor(text: $draft.text).font(.body).frame(minHeight: 160)
                    .accessibilityLabel(edit.title)
            }
        }
        .padding(24).frame(width: 560)
        .onAppear {
            profileName = store.activeProfile.profileName
            draft = edit.draft(from: store.activeProfile)
            loaded = true
        }
        .onChange(of: store.activeProfile.profileName) { dismiss() }
    }

    private func save() {
        guard let edited = edit.commit(draft, to: store.activeProfile, openedOn: profileName) else { dismiss(); return }
        store.activeProfile = edited
        store.saveActiveProfile()
        onSaved()
        dismiss()
    }
}

/// The number the Settings link shows: rows the Wizard actually reads.
nonisolated enum LearnedLessonsSummary {
    static func activeCount(lessons: [WizardLesson], profile: BrandProfile) -> Int {
        lessons.filter { lesson in
            let id = lesson.learnedID.isEmpty ? LearnedPreferences.stableID(lesson.text) : lesson.learnedID
            return !profile.learnedSharing.dismissedLessons.contains(id)
        }.count
    }
}
