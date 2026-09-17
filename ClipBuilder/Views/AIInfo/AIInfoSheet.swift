import AppKit
import SwiftUI

struct AIInfoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entries: [AIInfoEntry]
    @State private var selected = 0
    @State private var copying = false
    @State private var scopes = Set(AISettingsScope.allCases)
    @State private var copied = false
    @State private var replaceBuilder = false
    @State private var showingQuality = false
    /// Run Again: which role's popover is open, its model tag, and what
    /// the machine can run.
    @State private var rerunRole: String?
    @State private var rerunTag = ""
    @State private var availableProviders = Set(AICatalog.providers.map(\.key))
    @State private var soundbitesVideo: VideoRecord?
    @State private var namingVideo: VideoRecord?
    private var entry: AIInfoEntry { entries[min(selected, entries.count - 1)] }

    /// What "Run Again" does for a role: a stage of the analysis, or one of
    /// the sheets that already carry their own model picker.
    private enum RerunAction {
        case stage(AppStore.AnalysisStage)
        case soundbites
        case naming
    }

    private func rerunAction(for role: String) -> RerunAction? {
        guard let video = entry.video else { return nil }
        switch role {
        case "Soundbite finding": return .soundbites
        case "Naming", "File naming": return .naming
        default: return AppStore.AnalysisStage.forRole(role, podcast: video.type == .podcast).map { .stage($0) }
        }
    }

    @ViewBuilder
    private func rerunControl(for item: AIRole) -> some View {
        if let action = rerunAction(for: item.role), let video = entry.video {
            switch action {
            case .soundbites:
                Button("Find Again…") { soundbitesVideo = video }
                    .help("Open Find Soundbites for this file and pick the model there")
            case .naming:
                Button("Suggest Again…") { namingVideo = video }
                    .help("Open the File Name Wizard for this file and pick the model there")
            case .stage(let stage):
                let busy = store.isAnalyzing || (stage == .people && store.isDetectingPeople)
                Button(stage == .transcript ? "Transcribe Again" : "Run Again…") {
                    if let task = stage.task {
                        rerunTag = ModelPicker.bestAvailableTag(for: task, available: availableProviders)
                        rerunRole = item.role
                    } else {
                        store.rerun(stage, video: video)
                        dismiss()
                    }
                }
                .disabled(busy)
                .help(stage == .transcript
                      ? "Transcribe this file again on this Mac; the other parts of the analysis stay"
                      : "Run only \(stage.title) again for this file, with a model you pick; the other parts of the analysis stay")
                .popover(isPresented: Binding(get: { rerunRole == item.role }, set: { if !$0 { rerunRole = nil } })) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(stage.title) again for \(video.filename)")
                            .font(.headline)
                        Text(stage == .people
                             ? "Watches the video again and rebuilds who appears where. Scenes and the transcript stay."
                             : stage == .exchanges
                             ? "Groups the transcript into exchanges again, in a new analyze batch. Earlier batches stay until you delete them."
                             : "Tags the footage again, in a new analyze batch. People and the transcript stay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let task = stage.task {
                            ModelPicker(title: "Model", task: task, selection: $rerunTag,
                                        availableProviders: availableProviders)
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { rerunRole = nil }
                            Button("Run") {
                                let choice = ModelPicker.parse(rerunTag)
                                store.rerun(stage, video: video, provider: choice.provider, model: choice.model)
                                rerunRole = nil
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                    .frame(width: 360)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI details").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if entries.count > 1 {
                Picker("Run", selection: $selected) {
                    ForEach(entries.indices, id: \.self) { Text(entries[$0].name).tag($0) }
                }
            } else {
                Text(entry.name)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Models").font(.headline)
                    ForEach(Array(entry.roles.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            ProviderLogo(brand: item.provenance.brand, size: 18)
                            VStack(alignment: .leading) {
                                HStack(spacing: 8) {
                                    Text(item.role).bold()
                                    rerunControl(for: item)
                                        .controlSize(.small)
                                }
                                Text(item.provenance.shortLabel)
                                Text(
                                    item.provenance.at?.formatted(
                                        date: .abbreviated, time: .shortened)
                                        ?? "Date not recorded"
                                )
                                .foregroundStyle(.secondary)
                                if let took = item.provenance.durationLabel {
                                    Text("Took \(took)").foregroundStyle(.secondary)
                                        .help("Wall-clock time of the AI call, including any failover attempts.")
                                }
                                if let technique = item.provenance.technique {
                                    Text("Technique: \(technique)").foregroundStyle(.secondary)
                                }
                                if item.provenance.fellBack {
                                    Text("Fallback model").foregroundStyle(.secondary)
                                }
                            }
                        }.font(.caption)
                    }
                    Text("Settings").font(.headline)
                    if let settings = entry.settings {
                        if case .object(let prompts) = settings["modelPrompts"], !prompts.isEmpty {
                            DisclosureGroup("Prompt previews (informational)") {
                                ForEach(prompts.keys.sorted(), id: \.self) { key in
                                    if let prompt = AISettingsJSON.decode(
                                        AIPromptPreview.self, AISettingsJSON.encode(prompts[key]))
                                    {
                                        VStack(alignment: .leading) {
                                            Text(
                                                "\(key) · \(prompt.characterCount) characters\(prompt.truncated ? " (truncated)" : "")"
                                            )
                                            .font(.caption.bold())
                                            ScrollView {
                                                Text(prompt.preview).textSelection(.enabled)
                                            }.frame(maxHeight: 140)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach([AISettingsScope.prompts, .options, .sources], id: \.self) {
                            scope in
                            DisclosureGroup(scope.label) {
                                let keys = AISettingsEnvelope.keys(scope, kind: entry.kind).union(
                                    scope == .options ? ["builderDocumentJSON"] : [])
                                ForEach(settings.keys.filter(keys.contains).sorted(), id: \.self) {
                                    key in
                                    VStack(alignment: .leading) {
                                        Text(readable(key)).font(.caption.bold())
                                        let value = settings[key]!
                                        let text =
                                            value.string ?? AISettingsJSON.encode(value) ?? "—"
                                        ScrollView {
                                            Text(text).textSelection(.enabled).frame(
                                                maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 140)
                                        if scope == .prompts {
                                            Button("Copy") {
                                                AISettingsPasteboard.writeText(text)
                                            }
                                        }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    } else {
                        Text(AIInfoEntry.notRecorded).foregroundStyle(.secondary)
                    }
                    if entry.output?.qualityReport != nil {
                        Button("View quality report") { showingQuality = true }
                    }
                    if !entry.notes.isEmpty {
                        DisclosureGroup("Result notes") {
                            Text(entry.notes).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(copied ? "Copied" : "Copy Settings…") { copying.toggle() }.disabled(
                    entry.settings == nil
                )
                .popover(isPresented: $copying) {
                    VStack(alignment: .leading) {
                        Toggle(
                            "Everything",
                            isOn: Binding(
                                get: { scopes.count == AISettingsScope.allCases.count },
                                set: { scopes = $0 ? Set(AISettingsScope.allCases) : [] }))
                        ForEach(AISettingsScope.allCases, id: \.self) { scope in
                            Toggle(
                                scope.label,
                                isOn: Binding(
                                    get: { scopes.contains(scope) },
                                    set: {
                                        if $0 { scopes.insert(scope) } else { scopes.remove(scope) }
                                    }))
                        }
                        Button("Copy") {
                            guard let settings = entry.settings else { return }
                            AISettingsPasteboard.write(
                                AISettingsEnvelope(
                                    kind: entry.kind, sourceName: entry.name, scopes: scopes,
                                    settings: settings))
                            copying = false
                            copied = true
                        }.disabled(scopes.isEmpty)
                    }.padding().toggleStyle(.checkbox)
                }
                Spacer()
                if let output = entry.output {
                    Button("Open in Builder") {
                        if store.builder.document.videoTrack.isEmpty {
                            store.openInBuilder(output)
                            dismiss()
                        } else {
                            replaceBuilder = true
                        }
                    }
                }
            }
        }.padding(20).frame(width: 560, height: 620)
            .confirmationDialog(
                "Replace the current Builder timeline?", isPresented: $replaceBuilder
            ) {
                Button("Open in Builder", role: .destructive) {
                    if let output = entry.output {
                        store.openInBuilder(output)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingQuality) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.output?.qualityReport?.summary ?? "Quality report").font(.headline)
                    ScrollView { Text(entry.output?.qualityJSON ?? "").textSelection(.enabled) }
                    Button("Done") { showingQuality = false }
                }.padding().frame(width: 500, height: 450)
            }
            .task(id: copied) {
                guard copied else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    copied = false
                } catch {}
            }
            .task { availableProviders = await ModelPicker.probeAvailability(ai: store.ai) }
            .sheet(item: $soundbitesVideo) { video in SoundbiteSheet(video: video) }
            .sheet(item: $namingVideo) { video in FileNameWizardSheet(videos: [video]) }
    }
    private func readable(_ key: String) -> String {
        key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
}
