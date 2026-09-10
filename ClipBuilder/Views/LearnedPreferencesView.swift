import AppKit
import SwiftUI

@MainActor
struct LearnedPreferencesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"
    @State private var document: LearnedPreferences?
    @State private var sharingExpanded = false
    @State private var localFrames: [String: Data] = [:]
    @State private var onboarding = LearnedOnboarding(done: [], reviewCount: 0)
    @AppStorage("learned.onboardingCollapsed") private var onboardingCollapsed = false
    @State private var contributors: [LearnedPreferences] = []
    /// Empty means this Mac; otherwise a contributor name from the Drive home.
    @State private var selectedContributor = ""
    @State private var expanded: Set<LearnedPreferences.Kind> = [.style, .lessons]
    @State private var nickname = ""
    @State private var preview: String?
    @State private var showingPreview = false
    @State private var rewriteItem: LearnedPreferences.Item?
    @State private var fieldEdit: LearnedFieldEdit?
    @State private var newRule = ""
    @State private var dismissedExpanded = false
    @State private var rewriteText = ""
    @State private var rewriteError = ""
    @State private var busy = false
    @State private var status = ""
    @State private var modelsToken = UUID()
    /// Only the newest reload may publish; older results are dropped.
    @State private var reloadGeneration = 0
    /// The profile a lesson sheet was opened on; a switch closes it.
    @State private var sheetProfile = ""

    private var profileName: String { store.activeProfile.profileName }
    private var home: AssetSyncHome? { store.googleDrive.assetHomes[profileName] }
    private var hasHome: Bool { home != nil }
    private var hasNickname: Bool { !store.activeProfile.learnedSharing.deviceNickname.isEmpty }
    /// Muted contributors stay in the Contributors list but leave the reviewer.
    private var visibleContributors: [LearnedPreferences] {
        contributors.filter { !store.activeProfile.learnedSharing.mutedContributors.contains($0.contributor) }
    }
    private var remote: LearnedPreferences? {
        guard hasHome, !selectedContributor.isEmpty else { return nil }
        return visibleContributors.first { $0.contributor == selectedContributor }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if document != nil && remote == nil && !onboarding.isComplete {
                    onboardingCard
                }
                ReelModelsLearnedSection(reloadToken: modelsToken)
                if let document {
                    ForEach(document.sections) { section in
                        learnedSection(section, document: document)
                    }
                } else {
                    ProgressView("Reading learning…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: 900)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .task(id: profileName) { await reload() }
        .onChange(of: store.activeProfile) { Task { await reload() } }
        .onChange(of: profileName) {
            rewriteItem = nil
            fieldEdit = nil
            showingPreview = false
            preview = nil
            document = nil
            contributors = []
            selectedContributor = ""
        }
        .sheet(isPresented: $showingPreview) { previewSheet }
        .sheet(item: $rewriteItem) { item in rewriteSheet(item) }
        .sheet(item: $fieldEdit) { edit in
            LearnedFieldEditorSheet(edit: edit) { Task { await reload() } }
        }
        // Lesson writes on the store are fire-and-forget; the page follows them.
        .onChange(of: store.lessons) { Task { await reload() } }
        .onChange(of: store.isDistillingLessons) { _, distilling in
            if !distilling { Task { await reload() } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Lessons").font(.title.bold())
                Text("Everything the AI has learned about your reels, and which feature reads each part. Edit it here or where it says.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("What the AI reads…", action: showPreview)
                    .buttonStyle(.bordered)
                    .help("The learning available to the Wizard, the last plan prompt it sent, and the document that leaves this Mac.")
                syncState
            }
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasHome && !visibleContributors.isEmpty {
                Picker("Reviewing", selection: $selectedContributor) {
                    Text("This Mac").tag("")
                    ForEach(visibleContributors, id: \.contributor) { contributor in
                        Text(contributor.contributor).tag(contributor.contributor)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose whose learning to review below.")
            }
            sharingPanel
        }
        .onAppear { if hasHome && !hasNickname { sharingExpanded = true } }
    }

    /// Everything about other Macs lives here, collapsed until it matters.
    private var sharingPanel: some View {
        DisclosureGroup(isExpanded: $sharingExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                if hasHome {
                    contributorControl
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What leaves this Mac when you publish").font(.subheadline.weight(.medium))
                        Text(LearnedSectionInfo.shareHelp).font(.caption).foregroundStyle(.secondary)
                        ForEach(LearnedPreferences.Kind.allCases, id: \.rawValue) { kind in
                            Toggle(LearnedSectionInfo.entry(kind).title, isOn: shareBinding(kind))
                                .toggleStyle(.checkbox)
                                .help("Include this Mac's \(LearnedSectionInfo.entry(kind).title.lowercased()) when publishing.")
                        }
                    }
                    HStack(spacing: 12) { sharingActions }
                    if !contributors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Contributors").font(.subheadline.weight(.medium))
                            Text(LearnedSectionInfo.mergeHelp).font(.caption).foregroundStyle(.secondary)
                            ForEach(contributors, id: \.contributor) { contributor in
                                Toggle("Mute \(contributor.contributor)", isOn: muteBinding(contributor.contributor))
                                    .toggleStyle(.checkbox)
                                    .help("Exclude this contributor from shared learning used on this Mac.")
                            }
                        }
                    }
                } else {
                    Text(LearnedSectionInfo.noHomeHelp).font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Open Google Drive settings") { openSettingsTab("googleDrive") }
                            .buttonStyle(.bordered)
                        sharingActions
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(.secondary)
                Text("Sharing with other Macs").font(.headline)
                if hasHome, let home {
                    Text(home.selection.breadcrumb).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var contributorControl: some View {
        if hasNickname {
            Text("Contributor: \(store.activeProfile.learnedSharing.deviceNickname)")
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: 320, alignment: .leading)
                .help(LearnedPreferences.contributor(profile: store.activeProfile))
        } else {
            HStack(spacing: 8) {
                TextField("Device nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .help("The name used to identify this Mac's contributions.")
                Button("Save nickname", action: saveNickname)
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
            }.frame(maxWidth: 320)
        }
    }

    @ViewBuilder private var sharingActions: some View {
        if hasHome {
            Button("Publish now", action: publish)
                .buttonStyle(.borderedProminent)
                .disabled(busy || !hasNickname)
                .help("Publish the selected sections to this profile's Google Drive home.")
        }
    }

    /// What happened last with the Drive home, in one line.
    @ViewBuilder private var syncState: some View {
        if let home {
            Text(hasNickname ? home.rowStatus : "Shared lessons download on each Refresh. Save a device nickname to publish yours.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openSettingsTab(_ tab: String) {
        settingsTab = tab
        openSettings()
    }

    /// Takes the user to where a section is edited today.
    private func open(_ location: LearnedSectionInfo.EditLocation) {
        switch location {
        case .page: break
        case .settings(let tab, _): openSettingsTab(tab)
        case .project: if store.activeProjectID != nil { store.selectedSection = .people }
        }
    }

    /// Full checklist when nothing feeds the Wizard yet; a collapsible strip once something does.
    private var onboardingCard: some View {
        let compact = !onboarding.isEmpty && onboardingCollapsed
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: onboarding.isEmpty ? "graduationcap" : "checklist")
                    .foregroundStyle(.secondary)
                Text(onboarding.isEmpty ? "Nothing feeds the Wizard yet" : "\(onboarding.completed) of \(onboarding.total) sources feeding the Wizard")
                    .font(.headline)
                Spacer()
                if !onboarding.isEmpty {
                    Button(compact ? "Show" : "Hide") { onboardingCollapsed.toggle() }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !compact {
                ForEach(LearnedOnboarding.Step.allCases) { step in
                    let done = onboarding.done.contains(step)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                            .accessibilityLabel(done ? "Done" : "Not yet")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step == .reviews && onboarding.reviewCount > 0
                                 ? "\(step.title) (\(onboarding.reviewCount) reviewed)" : step.title)
                                .font(.callout.weight(done ? .regular : .medium))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if !done {
                            Button(stepAction(step).0, action: stepAction(step).1)
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stepAction(_ step: LearnedOnboarding.Step) -> (String, () -> Void) {
        switch step {
        case .houseStyle: ("Write", { fieldEdit = .houseStyle })
        case .tasteRubric: ("Write", { fieldEdit = .rubric })
        case .reviews: ("Open Library", { if store.activeProjectID != nil { store.selectedSection = .library } })
        case .rules: ("Show Lessons", { expanded.insert(.lessons) })
        case .insights: ("Open Instagram settings", { openSettingsTab("instagram") })
        case .people: ("Open People", { if store.activeProjectID != nil { store.selectedSection = .people } })
        }
    }

    // MARK: Sections

    private func learnedSection(_ section: LearnedPreferences.Section, document: LearnedPreferences) -> some View {
        let local = remote == nil
        let shown = local ? section : remote?.sections.first { $0.kind == section.kind }
        let contributor = remote?.contributor ?? document.contributor
        let count = shown?.items.count ?? 0
        let isExpanded = expanded.contains(section.kind)
        let info = LearnedSectionInfo.entry(section.kind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if isExpanded { expanded.remove(section.kind) } else { expanded.insert(section.kind) }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            Text(info.title).font(.headline)
                            Text("\(count)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(info.purpose).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        usedByChips(info)
                        if count == 0 && !info.emptyNote.isEmpty {
                            Text(info.emptyNote).font(.caption).foregroundStyle(.tertiary)
                        }
                        if section.kind == .style && local {
                            Text(store.activeProfile.useLearnedEditingDefaults
                                 ? "Hook and layout are learned defaults: opening Instagram › Editing performance may update them from your results."
                                 : "Hook and layout are stored but not used until Learned editing defaults is on in Settings › Profile.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(info.title), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
                Spacer(minLength: 0)
                sectionAction(section.kind, info: info, local: local)
            }
            if isExpanded {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        if let shown {
                            sectionRows(shown, contributor: contributor, local: local)
                        } else {
                            Text("Nothing learned yet.").foregroundStyle(.secondary)
                        }
                        if section.kind == .lessons && local {
                            Divider()
                            lessonTools
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
        }
        .animation(.default, value: isExpanded)
    }

    private func usedByChips(_ info: LearnedSectionInfo.Entry) -> some View {
        HStack(spacing: 6) {
            Text("Used by").font(.caption).foregroundStyle(.tertiary)
            ForEach(info.usedBy) { use in
                Label(use.consumer.label, systemImage: use.consumer.symbol)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help(use.qualifier)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Trailing control: where to edit, or why it is read-only.
    @ViewBuilder private func sectionAction(_ kind: LearnedPreferences.Kind, info: LearnedSectionInfo.Entry, local: Bool) -> some View {
        if !local {
            Text("Read-only: \(remote?.contributor ?? "")").font(.caption).foregroundStyle(.secondary)
        } else if kind == .benchmarks {
            VStack(alignment: .trailing, spacing: 4) {
                Button("Refresh") {
                    Task {
                        await store.reloadIGBenchmarks()
                        await reload()
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                .help(info.readOnlyReason)
                Text(info.readOnlyReason).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 220)
            }
        } else if info.editLocation == .page {
            Text("Edit with the row menu").font(.caption).foregroundStyle(.tertiary)
        } else if !info.editLocations.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(info.editLocations.enumerated()), id: \.offset) { _, location in
                    Button(location.label, systemImage: "arrow.up.right.square") { open(location) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Opens where these values are edited today.")
                }
            }
        } else {
            Text(info.readOnlyReason).font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing).frame(maxWidth: 220)
        }
    }

    private func sectionRows(_ section: LearnedPreferences.Section, contributor: String, local: Bool) -> some View {
        let metadata = [
            section.updatedAt == .distantPast ? "" : section.updatedAt.formatted(date: .abbreviated, time: .shortened),
            section.evidence.isEmpty ? "" : "Evidence: \(section.evidence)",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        // Pinned lessons first, purely for reading; the document order is untouched.
        let items = section.kind == .lessons
            ? section.items.sorted { $0.pinned && !$1.pinned } : section.items
        return VStack(alignment: .leading, spacing: 16) {
            if !metadata.isEmpty {
                Text(metadata).font(.caption).foregroundStyle(.secondary)
                    .help(LearnedSectionInfo.evidenceHelp + " " + LearnedSectionInfo.mergeHelp)
            }
            if items.isEmpty {
                Text("Nothing learned yet.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                if item.id != items.first?.id { Divider() }
                learnedRow(item, section: section.kind, contributor: contributor, local: local)
            }
        }
    }

    private func learnedRow(
        _ item: LearnedPreferences.Item, section: LearnedPreferences.Kind, contributor: String, local: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if item.pinned {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                                .accessibilityLabel("Pinned").help(LearnedSectionInfo.pinnedHelp)
                        }
                        Text(LearnedMerge.fieldLabels[item.field] ?? item.field)
                            .font(.caption).foregroundStyle(.secondary)
                        if local && section == .lessons,
                           let provenance = store.lessons.first(where: { lessonID($0) == item.id })?.provenance {
                            AIInfoButton(provenance: provenance, role: "Distilled by", size: 11)
                        }
                    }
                    if !item.text.isEmpty {
                        LearnedRichTextView(text: item.text)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !item.numbers.isEmpty {
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(item.numbers.keys.sorted(), id: \.self) { key in
                            GridRow {
                                Text(LearnedMerge.numberLabels[key] ?? key).foregroundStyle(.secondary)
                                Text((item.numbers[key] ?? 0).formatted(.number.precision(.fractionLength(0...3))))
                                    .monospacedDigit()
                            }
                        }
                    }.font(.callout)
                }
                if local && (section == .lessons || LearnedFieldEdit.forItem(field: item.field, id: item.id) != nil) {
                    rowMenu(item, section: section)
                }
            }
            if !item.frames.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(item.frames, id: \.self) { frame in
                            if let image = exemplar(frame, contributor: contributor, local: local) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(width: 140, height: 100)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("Taste exemplar")
                            }
                        }
                    }
                }
            }
            if !item.evidence.isEmpty {
                Text("Evidence: \(item.evidence)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .help(LearnedSectionInfo.evidenceHelp)
            }
        }
    }

    private func rowMenu(_ item: LearnedPreferences.Item, section: LearnedPreferences.Kind) -> some View {
        Menu {
            if section == .lessons {
                Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") {
                    Task { await edit(item, .pin(!item.pinned)) }
                }
                .help(LearnedSectionInfo.pinnedHelp)
                Button("Rewrite…", systemImage: "pencil") {
                    rewriteText = item.text
                    rewriteError = ""
                    sheetProfile = profileName
                    rewriteItem = item
                }
                Divider()
                Button("Dismiss", systemImage: "eye.slash") {
                    Task { await edit(item, .dismiss) }
                }
                .help("Hide this rule from the Wizard and from publishing. It can be restored below. A future distill may produce a similar rule with different wording.")
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if let lesson = store.lessons.first(where: { lessonID($0) == item.id }) {
                        store.deleteLesson(lesson)
                    }
                }
                .help("Remove the rule. A future distill may recreate it from the same reviews.")
            }
            if let field = LearnedFieldEdit.forItem(field: item.field, id: item.id) {
                Button("Edit…", systemImage: "pencil") { fieldEdit = field }
                    .help(field.help)
            }
            if item.field == "category" {
                Button("Drop category", systemImage: "tag.slash", role: .destructive) {
                    store.activeProfile = LearnedEditing.dropCategory(item.id, profile: store.activeProfile)
                    store.saveActiveProfile()
                    Task { await reload() }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(busy)
        .accessibilityLabel("Actions")
    }

    // MARK: Lessons tools

    private func lessonID(_ lesson: WizardLesson) -> String {
        lesson.learnedID.isEmpty ? LearnedPreferences.stableID(lesson.text) : lesson.learnedID
    }
    private var dismissedLessons: [WizardLesson] {
        store.lessons.filter { store.activeProfile.learnedSharing.dismissedLessons.contains(lessonID($0)) }
    }

    private var lessonTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Add a rule, saved as pinned", text: $newRule, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRule)
                    .help("Short commands work best: \"Never open with slow motion.\"")
                Button("Add", action: addRule)
                    .disabled(newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 8) {
                Button("Distill rules from reviews", systemImage: "sparkles") { store.distillLessons() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(store.isDistillingLessons || busy)
                    .help("Reads your reel reviews and rewrites the unpinned rules, including performance-derived ones. Pinned rules are kept.")
                if store.isDistillingLessons {
                    ProgressView().controlSize(.small)
                    Text("Distilling…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !dismissedLessons.isEmpty {
                DisclosureGroup(isExpanded: $dismissedExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dismissedLessons) { lesson in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(lesson.text).font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Restore") {
                                    store.activeProfile = LearnedEditing.restoreLesson(lessonID(lesson), profile: store.activeProfile)
                                    store.saveActiveProfile()
                                    Task { await reload() }
                                }
                                .controlSize(.small)
                            }
                        }
                    }.padding(.top, 8)
                } label: {
                    Text("Dismissed (\(dismissedLessons.count))").font(.callout)
                }
            }
        }
    }
    private func addRule() {
        let text = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addLesson(text: text)
        newRule = ""
    }

    // MARK: Sheets

    @ViewBuilder private var previewSheet: some View {
        if let document {
            LearnedPreviewSheet(profileName: profileName, local: document, contributors: contributors,
                                muted: store.activeProfile.learnedSharing.mutedContributors,
                                sharedJSON: preview ?? "") { showingPreview = false }
        }
    }

    /// Stays open until the edit lands, so a failure is seen where it happened.
    private func rewriteSheet(_ item: LearnedPreferences.Item) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rewrite lesson").font(.headline)
                Spacer()
                Button("Cancel") { rewriteItem = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await edit(item, .rewrite(rewriteText), openedOn: sheetProfile) { rewriteItem = nil } else { rewriteError = status }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || rewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            TextEditor(text: $rewriteText)
                .font(.body)
                .frame(minHeight: 160)
                .accessibilityLabel("Lesson text")
            if !rewriteError.isEmpty {
                Text(rewriteError).font(.callout).foregroundStyle(.red)
            }
        }.padding(24).frame(width: 520)
    }

    // MARK: Data

    private func exemplar(_ frame: String, contributor: String, local: Bool) -> NSImage? {
        if local, let data = localFrames[frame] { return NSImage(data: data) }
        guard let url = try? LearnedLibrary().frameURL(frame, contributor: contributor) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func shareBinding(_ kind: LearnedPreferences.Kind) -> Binding<Bool> {
        Binding(
            get: { store.activeProfile.learnedSharing.enabled[kind.rawValue] ?? kind.defaultEnabled },
            set: {
                store.activeProfile.learnedSharing.enabled[kind.rawValue] = $0
                store.saveActiveProfile()
            })
    }
    private func muteBinding(_ contributor: String) -> Binding<Bool> {
        Binding(
            get: { store.activeProfile.learnedSharing.mutedContributors.contains(contributor) },
            set: {
                if $0 {
                    store.activeProfile.learnedSharing.mutedContributors.insert(contributor)
                    if selectedContributor == contributor { selectedContributor = "" }
                } else {
                    store.activeProfile.learnedSharing.mutedContributors.remove(contributor)
                }
                store.saveActiveProfile()
            })
    }
    private func saveNickname() {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LearnedRedaction.text(value) == value, !value.isEmpty else {
            status = "Use a nickname without an email, handle, URL or path."
            return
        }
        store.activeProfile.learnedSharing.deviceNickname = value
        store.saveActiveProfile()
    }
    private func reload() async {
        guard let database = store.database else { return }
        let profile = store.activeProfile
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let build = try await LearnedDocumentBuilder.build(
                profile: profile, database: database, benchmarks: store.igBenchmarks)
            guard generation == reloadGeneration, store.activeProfile.profileName == profile.profileName else { return }
            document = build.document
            localFrames = build.frames
            onboarding = build.onboarding
            contributors = LearnedLibrary(profile: profile.profileName).documents().filter {
                $0.contributor != build.document.contributor
            }
            if !selectedContributor.isEmpty, !visibleContributors.contains(where: { $0.contributor == selectedContributor }) {
                selectedContributor = ""
            }
            modelsToken = UUID()
        } catch {
            guard generation == reloadGeneration else { return }
            status = error.localizedDescription
        }
    }
    private func showPreview() {
        guard let document else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            preview = String(
                decoding: try encoder.encode(LearnedRedaction.apply(document, publishing: true)), as: UTF8.self)
            showingPreview = true
        } catch { status = error.localizedDescription }
    }
    private func publish() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.googleDrive.publishLearned(profile: store.activeProfile, benchmarks: store.igBenchmarks)
                status = "Published \(Date().formatted(date: .abbreviated, time: .shortened))"
                await reload()
            } catch { status = error.localizedDescription }
        }
    }
    @discardableResult
    /// `openedOn` is the profile the action was chosen on; the edit is
    /// refused once the user has switched away. Only this action's own
    /// change is applied to the live profile, never a whole snapshot.
    private func edit(_ item: LearnedPreferences.Item, _ action: LearnedEditing.LessonAction,
                      openedOn: String? = nil) async -> Bool {
        let profile = store.activeProfile
        guard let database = store.database, (openedOn ?? profile.profileName) == profile.profileName else { return false }
        busy = true
        defer { busy = false }
        do {
            let edited = try await LearnedEditing.editLesson(item.id, action: action, profile: profile, database: database)
            guard store.activeProfile.profileName == profile.profileName, database === store.database else { return false }
            store.activeProfile = LearnedEditing.applyDelta(action, id: item.id, from: edited, to: store.activeProfile)
            store.saveActiveProfile()
            await store.refreshLessons(from: database)
            await reload()
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }
}
