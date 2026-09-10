import AppKit
import SwiftUI

@MainActor
struct LearnedPreferencesView: View {
    @Environment(AppStore.self) private var store
    @State private var document: LearnedPreferences?
    @State private var localFrames: [String: Data] = [:]
    @State private var contributors: [LearnedPreferences] = []
    /// Empty means this Mac; otherwise a contributor name from the Drive home.
    @State private var selectedContributor = ""
    @State private var expanded: Set<LearnedPreferences.Kind> = [.style, .lessons]
    @State private var nickname = ""
    @State private var preview: String?
    @State private var showingPreview = false
    @State private var rewriteItem: LearnedPreferences.Item?
    @State private var rewriteText = ""
    @State private var rewriteError = ""
    @State private var busy = false
    @State private var status = ""
    @State private var modelsToken = UUID()

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
                ReelModelsLearnedSection(reloadToken: modelsToken)
                if let document {
                    if isEmpty(document) {
                        emptyState
                    } else {
                        ForEach(document.sections) { section in
                            learnedSection(section, document: document)
                        }
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
        .sheet(isPresented: $showingPreview) { previewSheet }
        .sheet(item: $rewriteItem) { item in rewriteSheet(item) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI Lessons").font(.title.bold())
                Text("The style, taste and lessons that guide your videos. Synced with your Google Drive home.")
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    contributorControl
                    sharingActions
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    contributorControl
                    HStack(spacing: 12) { sharingActions }
                }
            }
            syncState
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
            if hasHome && !contributors.isEmpty {
                DisclosureGroup("Contributors") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(contributors, id: \.contributor) { contributor in
                            Toggle("Mute \(contributor.contributor)", isOn: muteBinding(contributor.contributor))
                                .help("Exclude this contributor from shared learning used on this Mac.")
                        }
                    }.padding(.top, 8)
                }
                .font(.callout)
            }
        }
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
        Button("Preview what will be shared", action: showPreview)
            .buttonStyle(.bordered)
            .help("Review the redacted document before sharing.")
        if hasHome {
            Button("Publish now", action: publish)
                .buttonStyle(.borderedProminent)
                .disabled(busy || !hasNickname)
                .help("Publish the selected sections to this profile's Google Drive home.")
        }
    }

    /// Where this page syncs to and what happened last, in one glance.
    @ViewBuilder private var syncState: some View {
        if let home {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(home.selection.breadcrumb).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(hasNickname ? home.rowStatus : "Shared lessons download on each Refresh. Save a device nickname to publish yours.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Choose a Google Drive home in Settings › Google Drive to share learning between Macs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing learned yet", systemImage: "graduationcap")
        } description: {
            Text("Rate reels in the AI Wizard, set a house style and taste in Settings, or import Instagram reports. Lessons collect here and sync with your Google Drive home.")
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func isEmpty(_ document: LearnedPreferences) -> Bool {
        let shown = remote ?? document
        return shown.sections.allSatisfy { $0.items.isEmpty }
    }

    // MARK: Sections

    private func displayName(_ kind: LearnedPreferences.Kind) -> String {
        switch kind {
        case .style: "Style"
        case .taste: "Taste"
        case .lessons: "Lessons"
        case .vocabulary: "Vocabulary"
        case .benchmarks: "Benchmarks"
        case .people: "People"
        case .research: "Research"
        }
    }

    private func learnedSection(_ section: LearnedPreferences.Section, document: LearnedPreferences) -> some View {
        let local = remote == nil
        let shown = local ? section : remote?.sections.first { $0.kind == section.kind }
        let contributor = remote?.contributor ?? document.contributor
        let count = shown?.items.count ?? 0
        let isExpanded = expanded.contains(section.kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    if isExpanded { expanded.remove(section.kind) } else { expanded.insert(section.kind) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(displayName(section.kind)).font(.headline)
                        Text("\(count)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(displayName(section.kind)), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
                Spacer()
                if hasHome {
                    Toggle("Share", isOn: shareBinding(section.kind))
                        .toggleStyle(.switch).controlSize(.small).fixedSize()
                        .help("Include this Mac's \(displayName(section.kind).lowercased()) when publishing.")
                }
            }
            if isExpanded {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        if let shown {
                            sectionRows(shown, contributor: contributor, local: local)
                        } else {
                            Text("Nothing learned yet.").foregroundStyle(.secondary)
                        }
                        if section.kind == .benchmarks && local {
                            Divider()
                            Button("Refresh benchmark summary") {
                                Task {
                                    await store.reloadIGBenchmarks()
                                    await reload()
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                            .help("Refresh the benchmark summary for this profile.")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
        }
        .animation(.default, value: isExpanded)
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
                                .accessibilityLabel("Pinned")
                        }
                        Text(LearnedMerge.fieldLabels[item.field] ?? item.field)
                            .font(.caption).foregroundStyle(.secondary)
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
                if local && (section == .lessons || item.field == "category") {
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
            }
        }
    }

    private func rowMenu(_ item: LearnedPreferences.Item, section: LearnedPreferences.Kind) -> some View {
        Menu {
            if section == .lessons {
                Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") {
                    Task { await edit(item, .pin(!item.pinned)) }
                }
                Button("Rewrite…", systemImage: "pencil") {
                    rewriteText = item.text
                    rewriteError = ""
                    rewriteItem = item
                }
                Divider()
                Button("Dismiss", systemImage: "xmark.circle", role: .destructive) {
                    Task { await edit(item, .dismiss) }
                }
            }
            if item.field == "category" {
                Button("Drop category", systemImage: "tag.slash", role: .destructive) {
                    store.activeProfile = LearnedEditing.dropCategory(item.id, profile: store.activeProfile)
                    store.saveActiveProfile()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(busy)
        .accessibilityLabel("Actions")
    }

    // MARK: Sheets

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Preview what will be shared").font(.headline)
                Spacer()
                Button("Done") { showingPreview = false }.keyboardShortcut(.defaultAction)
            }
            Divider()
            ScrollView {
                Text(preview ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(minWidth: 600, minHeight: 500)
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
                        if await edit(item, .rewrite(rewriteText)) { rewriteItem = nil } else { rewriteError = status }
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
        do {
            let build = try await LearnedDocumentBuilder.build(
                profile: profile, database: database, benchmarks: store.igBenchmarks)
            guard store.activeProfile == profile else { return }
            document = build.document
            localFrames = build.frames
            contributors = LearnedLibrary(profile: profile.profileName).documents().filter {
                $0.contributor != build.document.contributor
            }
            if !selectedContributor.isEmpty, !visibleContributors.contains(where: { $0.contributor == selectedContributor }) {
                selectedContributor = ""
            }
            modelsToken = UUID()
        } catch { status = error.localizedDescription }
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
    private func edit(_ item: LearnedPreferences.Item, _ action: LearnedEditing.LessonAction) async -> Bool {
        guard let database = store.database else { return false }
        busy = true
        defer { busy = false }
        let profile = store.activeProfile
        do {
            let edited = try await LearnedEditing.editLesson(item.id, action: action, profile: profile, database: database)
            guard store.activeProfile.profileName == profile.profileName else { return false }
            store.activeProfile.learnedSharing.dismissedLessons.formUnion(edited.learnedSharing.dismissedLessons)
            store.activeProfile.learnedSharing.updatedAt["lessons"] = edited.learnedSharing.updatedAt["lessons"]
            store.saveActiveProfile()
            await reload()
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }
}
