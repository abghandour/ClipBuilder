import AppKit
import SwiftUI

struct LearnedPreferencesView: View {
    @Environment(AppStore.self) private var store
    @State private var document: LearnedPreferences?
    @State private var localFrames: [String: Data] = [:]
    @State private var contributors: [LearnedPreferences] = []
    @State private var nickname = ""
    @State private var preview: String?
    @State private var showingPreview = false
    @State private var rewriteItem: LearnedPreferences.Item?
    @State private var rewriteText = ""
    @State private var busy = false
    @State private var status = ""

    private var hasHome: Bool { store.googleDrive.assetHomes[store.activeProfile.profileName] != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What Clip Builder has learned").font(.largeTitle)
                Text("Review the style, taste and lessons that guide your videos.").foregroundStyle(.secondary)
                if store.activeProfile.learnedSharing.deviceNickname.isEmpty {
                    HStack {
                        TextField("Device nickname (for example, Studio Mac)", text: $nickname)
                        Button("Save nickname") { saveNickname() }
                            .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Text("Contributor: \(LearnedPreferences.contributor(profile: store.activeProfile))").font(.caption)
                }
                HStack {
                    Button("Preview what will be shared") { showPreview() }
                    Button("Publish now") { publish() }
                        .disabled(!hasHome || busy || store.activeProfile.learnedSharing.deviceNickname.isEmpty)
                }
                if hasHome {
                    ForEach(contributors, id: \.contributor) { contributor in
                        Toggle("Mute \(contributor.contributor)", isOn: muteBinding(contributor.contributor))
                    }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                if let document {
                    ForEach(document.sections) { section in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(section.kind.rawValue.capitalized).font(.title2)
                                    Spacer()
                                    if hasHome { Toggle("Share", isOn: shareBinding(section.kind)).fixedSize() }
                                }
                                ScrollView(.horizontal) {
                                    HStack(alignment: .top, spacing: 24) {
                                        sectionColumn(section, contributor: document.contributor, local: true)
                                        if hasHome {
                                            ForEach(contributors, id: \.contributor) { contributor in
                                                if let remote = contributor.sections.first(where: { $0.kind == section.kind }) {
                                                    sectionColumn(remote, contributor: contributor.contributor, local: false)
                                                }
                                            }
                                        }
                                    }
                                }
                                if section.kind == .benchmarks {
                                    Button("Refresh benchmark summary") {
                                        Task { await store.reloadIGBenchmarks(); await reload() }
                                    }.disabled(busy)
                                }
                            }.padding(8)
                        }
                    }
                } else { ProgressView("Reading learning…") }
            }.padding(24)
        }
        .task(id: store.activeProfile.profileName) { await reload() }
        .onChange(of: store.activeProfile) { Task { await reload() } }
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading) {
                Text("Preview what will be shared").font(.headline)
                ScrollView { Text(preview ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                Button("Done") { showingPreview = false }
            }.padding().frame(minWidth: 600, minHeight: 500)
        }
        .sheet(item: $rewriteItem) { item in
            VStack(alignment: .leading) {
                Text("Rewrite lesson").font(.headline)
                TextEditor(text: $rewriteText).frame(minHeight: 160)
                HStack {
                    Button("Cancel") { rewriteItem = nil }
                    Button("Save") { edit(item, .rewrite(rewriteText)); rewriteItem = nil }
                        .disabled(rewriteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding().frame(width: 480)
        }
    }

    private func sectionColumn(_ section: LearnedPreferences.Section, contributor: String, local: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(local ? "Local · \(contributor)" : contributor).font(.headline)
            Text(section.updatedAt == .distantPast ? "Date not recorded" : section.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            Text("Evidence: \(section.evidence)").font(.caption).foregroundStyle(.secondary)
            if section.items.isEmpty { Text("Nothing learned yet.").foregroundStyle(.secondary) }
            ForEach(section.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(LearnedMerge.Line(section: section.kind, item: item, origin: contributor, local: local).text)
                        .textSelection(.enabled)
                    ForEach(item.frames, id: \.self) { frame in
                        if let image = exemplar(frame, contributor: contributor, local: local) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                                .accessibilityLabel("Taste exemplar")
                        }
                    }
                    if local && section.kind == .lessons {
                        HStack {
                            Button(item.pinned ? "Unpin" : "Pin") { edit(item, .pin(!item.pinned)) }
                            Button("Dismiss") { edit(item, .dismiss) }
                            Button("Rewrite") { rewriteText = item.text; rewriteItem = item }
                        }.disabled(busy)
                    }
                    if local && item.field == "category" {
                        Button("Drop category") {
                            store.activeProfile = LearnedEditing.dropCategory(item.id, profile: store.activeProfile)
                            store.saveActiveProfile()
                        }.disabled(busy)
                    }
                }
                Divider()
            }
        }.frame(width: 340, alignment: .leading)
    }

    private func exemplar(_ frame: String, contributor: String, local: Bool) -> NSImage? {
        if local, let data = localFrames[frame] { return NSImage(data: data) }
        guard let url = try? LearnedLibrary().frameURL(frame, contributor: contributor) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func shareBinding(_ kind: LearnedPreferences.Kind) -> Binding<Bool> {
        Binding(get: { store.activeProfile.learnedSharing.enabled[kind.rawValue] ?? kind.defaultEnabled }, set: {
            store.activeProfile.learnedSharing.enabled[kind.rawValue] = $0
            store.saveActiveProfile()
        })
    }
    private func muteBinding(_ contributor: String) -> Binding<Bool> {
        Binding(get: { store.activeProfile.learnedSharing.mutedContributors.contains(contributor) }, set: {
            if $0 { store.activeProfile.learnedSharing.mutedContributors.insert(contributor) }
            else { store.activeProfile.learnedSharing.mutedContributors.remove(contributor) }
            store.saveActiveProfile()
        })
    }
    private func saveNickname() {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LearnedRedaction.text(value) == value, !value.isEmpty else {
            status = "Use a nickname without an email, handle, URL or path."; return
        }
        store.activeProfile.learnedSharing.deviceNickname = value
        store.saveActiveProfile()
    }
    private func reload() async {
        guard let database = store.database else { return }
        let profile = store.activeProfile
        do {
            let build = try await LearnedDocumentBuilder.build(profile: profile, database: database, benchmarks: store.igBenchmarks)
            guard store.activeProfile == profile else { return }
            document = build.document
            localFrames = build.frames
            contributors = LearnedLibrary(profile: profile.profileName).documents().filter { $0.contributor != build.document.contributor }
        } catch { status = error.localizedDescription }
    }
    private func showPreview() {
        guard let document else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            preview = String(decoding: try encoder.encode(LearnedRedaction.apply(document, publishing: true)), as: UTF8.self)
            showingPreview = true
        } catch { status = error.localizedDescription }
    }
    private func publish() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.googleDrive.publishLearned(profile: store.activeProfile, benchmarks: store.igBenchmarks)
                status = "Published learned preferences"
                await reload()
            } catch { status = error.localizedDescription }
        }
    }
    private func edit(_ item: LearnedPreferences.Item, _ action: LearnedEditing.LessonAction) {
        guard let database = store.database else { return }
        busy = true
        let profile = store.activeProfile
        Task {
            defer { busy = false }
            do {
                let edited = try await LearnedEditing.editLesson(item.id, action: action, profile: profile, database: database)
                guard store.activeProfile.profileName == profile.profileName else { return }
                store.activeProfile.learnedSharing.dismissedLessons.formUnion(edited.learnedSharing.dismissedLessons)
                store.activeProfile.learnedSharing.updatedAt["lessons"] = edited.learnedSharing.updatedAt["lessons"]
                store.saveActiveProfile()
                await reload()
            } catch { status = error.localizedDescription }
        }
    }
}
